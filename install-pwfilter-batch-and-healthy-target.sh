#!/bin/sh
# Installer: Passwall Node Filter (pwfilter) + LuCI page
# Target: OpenWrt 23.05 + luci-app-passwall (Linksys EA8100)
# Usage:  sh install-pwfilter.sh

set -e
echo "Installing pwfilter ..."

mkdir -p /www/luci-static/resources/view/pwfilter \
         /usr/share/luci/menu.d \
         /usr/share/rpcd/acl.d

# ------------------------------------------------------------------ main script
cat > /usr/bin/pwfilter <<'PWF_MAIN'
#!/bin/sh
# pwfilter - randomize the full subscription queue, import in capped batches, and keep healthy nodes:
#   1) import BATCH_SIZE random candidates per cycle
#   2) direct TCP ping (Passwall stopped, no proxy)
#   3) YouTube test through each node (temporary socks via Passwall's own app.sh)
#   4) optional 1 MB download-throughput test through each node
#   5) keep at most MAX_NODES healthy nodes in the target group

PW=passwall
CFG=pwfilter
TMP=/tmp/pwfilter
LOG=/tmp/pwfilter.log
LOCKDIR=/var/run/pwfilter.lock
APP=/usr/share/passwall/app.sh
BASE_PORT=61180
WAS_ENABLED=0
PW_STOPPED=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }
c() { v=$(uci -q get "$CFG.main.$1"); [ -n "$v" ] && echo "$v" || echo "$2"; }

node_ids() {
	# Passwall subscription nodes are tagged by group + add_mode=2;
	# there is no reliable add_from option on current Passwall builds.
	for id in $(uci -q show "$PW" | sed -n "s/^$PW\.\([^.]*\)\.group='$REMARK'$/\1/p"); do
		[ "$(uci -q get "$PW.$id.add_mode")" = "2" ] && echo "$id"
	done
}

prepare_random_subscription() {
	# Download and decode a URI-list subscription, deduplicate it, then shuffle
	# the FULL list. Nodes are imported in small batches only when the target
	# group has free slots. This keeps the group at or below MAX_NODES.
	local raw="$TMP/sub.raw" decoded="$TMP/sub.decoded" queue="$TMP/sub.queue" seed
	log "downloading subscription for random selection ..."
	if ! curl -fskL --retry 3 --connect-timeout 3 \
		-H 'Accept: */*' -H 'Accept-Encoding: identity' -A 'passwall' \
		"$SUB_URL" -o "$raw"; then
		log "subscription download failed; nothing was imported"
		return 1
	fi
	[ -s "$raw" ] || { log "subscription response is empty"; return 1; }

	: > "$decoded"
	if base64 -d "$raw" > "$decoded" 2>/dev/null && \
		grep -Eq '^[[:space:]]*[A-Za-z][A-Za-z0-9+.-]*://' "$decoded"; then
		log "subscription format: base64 URI list"
	elif grep -Eq '^[[:space:]]*[A-Za-z][A-Za-z0-9+.-]*://' "$raw"; then
		cp "$raw" "$decoded"
		log "subscription format: plain URI list"
	else
		log "unsupported subscription format (likely Clash YAML / SSD / non-URI list). Refusing import."
		return 1
	fi
	if grep -Eiq '^[[:space:]]*ssd://' "$decoded"; then
		log "SSD subscription format is not supported; nothing was imported."
		return 1
	fi

	seed=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
	[ -n "$seed" ] || seed="$(date +%s)$$"
	# Keep every unique supported URI, in a new random order on each run.
	awk -v seed="$seed" '
		BEGIN { srand(seed) }
		{
			line=$0; sub(/\r$/, "", line)
			if (line !~ /^[[:space:]]*[A-Za-z][A-Za-z0-9+.-]*:\/\//) next
			if (seen[line]++) next
			printf "%.12f\t%s\n", rand(), line
		}
	' "$decoded" | sort -n | cut -f2- > "$queue"
	available=$(wc -l < "$queue" | tr -d ' ')
	[ "$available" -gt 0 ] || { log "no supported unique proxy links found"; return 1; }
	log "found $available unique proxy links; random test batch size: $BATCH_SIZE; final healthy-node target: $MAX_NODES"
	return 0
}

import_batch() {
	local batch_file="$1" count
	[ -s "$batch_file" ] || return 1
	count=$(wc -l < "$batch_file" | tr -d ' ')
	base64 "$batch_file" | tr -d '\n' > "$TMP/sub.selected.b64"
	[ -s "$TMP/sub.selected.b64" ] || { log "failed to prepare selected batch"; return 1; }
	uci -q delete $PW.pwfilter_sub
	uci set $PW.pwfilter_sub=subscribe_list
	uci set $PW.pwfilter_sub.remark="$REMARK"
	uci set $PW.pwfilter_sub.url="$TMP/sub.selected.b64"
	uci commit $PW
	log "importing next batch: $count node(s)"
	lua /usr/share/passwall/subscribe.lua start pwfilter_sub manual > "$TMP/sub.log" 2>&1
	sleep 1
	[ "$PW_STOPPED" = 1 ] && /etc/init.d/passwall stop >/dev/null 2>&1
	uci -q delete $PW.pwfilter_sub
	uci commit $PW
	return 0
}

count_group_nodes() {
	node_ids | wc -l | tr -d ' '
}

trim_group_to_limit() {
	local total keep id removed=0
	total=$(count_group_nodes)
	[ "$total" -le "$MAX_NODES" ] && return 0
	log "group currently has $total nodes; trimming to configured maximum $MAX_NODES"
	node_ids | head -n "$MAX_NODES" > "$TMP/keep_ids.txt"
	for id in $(node_ids); do
		if ! grep -qx "$id" "$TMP/keep_ids.txt"; then
			uci -q delete "$PW.$id"
			removed=$((removed + 1))
		fi
	done
	uci commit $PW
	log "removed $removed excess node(s) to enforce the group limit"
}

check_stop_requested() {
	[ -f "$LOCKDIR/stop" ] && { log "manual stop requested"; return 0; }
	return 1
}

check_and_clean_group() {
	local id a p n r ok del good port ids_file="${1:-}"
	: > "$TMP/nodes.txt"
	if [ -n "$ids_file" ] && [ -f "$ids_file" ]; then
		while read id; do
			[ -n "$id" ] || continue
			[ "$(uci -q get "$PW.$id.group")" = "$REMARK" ] || continue
			[ "$(uci -q get "$PW.$id.add_mode")" = 2 ] || continue
			echo "$id $(uci -q get "$PW.$id.address") $(uci -q get "$PW.$id.port")" >> "$TMP/nodes.txt"
		done < "$ids_file"
	else
		for id in $(node_ids); do
			echo "$id $(uci -q get "$PW.$id.address") $(uci -q get "$PW.$id.port")" >> "$TMP/nodes.txt"
		done
	fi
	total=$(wc -l < "$TMP/nodes.txt" | tr -d ' ')
	log "checking selected group nodes: $total"

	# TCP stage: a node without a TCP connection is removed regardless of age.
	log "TCP ping (direct) ..."
	: > "$TMP/tcp_ok.txt"
	n=0
	while read id a p; do
		check_stop_requested && return 2
		(
			r=$(tcp_ping "$a" "$p") && echo "$id $r" >> "$TMP/tcp_ok.txt"
		) </dev/null &
		n=$((n + 1))
		[ $((n % TCP_PAR)) -eq 0 ] && wait
	done < "$TMP/nodes.txt"
	wait
	check_stop_requested && return 2
	ok=$(wc -l < "$TMP/tcp_ok.txt" | tr -d ' ')
	del=0
	while read id a p; do
		if ! grep -q "^$id " "$TMP/tcp_ok.txt"; then
			uci -q delete "$PW.$id"
			del=$((del + 1))
		fi
	done < "$TMP/nodes.txt"
	uci commit $PW
	log "TCP result: $ok alive, $del removed"

	# YouTube stage: a TCP-live node is retained only if it passes the chosen
	# YouTube URL policy. No all-failed safety bypass: failures are deleted.
	log "YouTube test through each TCP-live node (mode: $YT_MODE) ..."
	: > "$TMP/yt_ok.txt"
	n=0
	while read id ms; do
		check_stop_requested && return 2
		port=$((BASE_PORT + n % YT_PAR))
		yt_test "$id" "$port" </dev/null &
		n=$((n + 1))
		[ $((n % YT_PAR)) -eq 0 ] && wait
	done < "$TMP/tcp_ok.txt"
	wait
	check_stop_requested && return 2
	good=$(wc -l < "$TMP/yt_ok.txt" | tr -d ' ')
	del=0
	while read id ms; do
		if ! grep -qx "$id" "$TMP/yt_ok.txt"; then
			uci -q delete "$PW.$id"
			del=$((del + 1))
		fi
	done < "$TMP/tcp_ok.txt"
	uci commit $PW
	log "YouTube result: $good healthy nodes kept, $del removed"

	# Optional throughput stage. Run sequentially so simultaneous downloads do
	# not distort the per-node speed measurement. Cloudflare returns exactly
	# the requested 1 MiB test payload; curl reports average bytes/second.
	if [ "$SPEED_TEST" = 1 ]; then
		log "speed test through YouTube-live nodes (1 MB sample; minimum ${MIN_SPEED_KBPS} KB/s) ..."
		: > "$TMP/speed_ok.txt"
		while read id; do
			check_stop_requested && return 2
			port=$((BASE_PORT + 500))
			speed_test_node "$id" "$port"
		done < "$TMP/yt_ok.txt"
		good=$(wc -l < "$TMP/speed_ok.txt" | tr -d ' ')
		del=0
		while read id; do
			if ! grep -qx "$id" "$TMP/speed_ok.txt"; then
				uci -q delete "$PW.$id"
				del=$((del + 1))
			fi
		done < "$TMP/yt_ok.txt"
		uci commit $PW
		log "speed result: $good passed, $del removed"
	else
		log "speed test disabled; keeping nodes that passed TCP and YouTube"
	fi
	if [ "$CHECK_EXISTING_NODES" = 1 ]; then
		trim_group_to_limit
	else
		log "only-new mode: skipping group-wide trimming so existing nodes remain untouched"
	fi
	return 0
}

tcp_ping() { # addr port -> prints latency (ms) on success
	local a="$1" p="$2" i=0 r=""
	[ -n "$a" ] && [ -n "$p" ] || return 1
	while [ "$i" -lt "$TCP_TRIES" ]; do
		if command -v tcping >/dev/null 2>&1; then
			r=$(tcping -q -c 1 -i 1 -t "$TCP_TIMEOUT" -p "$p" "$a" 2>&1 | grep -o 'time=[0-9.]*' | cut -d= -f2)
		elif nc -z -w "$TCP_TIMEOUT" "$a" "$p" >/dev/null 2>&1; then
			r="ok"
		fi
		[ -n "$r" ] && { echo "$r"; return 0; }
		i=$((i + 1))
	done
	return 1
}

yt_test() { # id port
	local id="$1" port="$2" ok=0 bad=0 u code pass name cfgf
	name=$(uci -q get $PW.$id.remarks)
	cfgf="pwf_$id.json"
	"$APP" run_socks flag="pwf_$id" node="$id" bind=127.0.0.1 socks_port="$port" config_file="$cfgf" >/dev/null 2>&1
	sleep 2
	for u in $YT_URLS; do
		code=$(curl -s -o /dev/null -L --connect-timeout 4 -m "$YT_TIMEOUT" \
			-x "socks5h://127.0.0.1:$port" -w '%{http_code}' "$u" 2>/dev/null)
		case "$code" in
			2??) ok=$((ok + 1)) ;;
			*) bad=$((bad + 1)) ;;
		esac
	done
	ps w | grep "[p]wf_$id\.json" | awk '{print $1}' | xargs kill -9 2>/dev/null
	rm -f "/tmp/etc/passwall/$cfgf"
	if [ "$YT_MODE" = "all" ]; then
		[ "$bad" -eq 0 ] && pass=1 || pass=0
	else
		[ "$ok" -gt 0 ] && pass=1 || pass=0
	fi
	if [ "$pass" = 1 ]; then
		echo "$id" >> "$TMP/yt_ok.txt"
		log "  YT OK    $name ($ok/$((ok + bad)))"
	else
		log "  YT FAIL  $name ($ok/$((ok + bad)))"
	fi
}


speed_test_node() { # id port; sequential 1 MiB download measurement
	local id="$1" port="$2" name cfgf raw speed_kbps pass
	name=$(uci -q get "$PW.$id.remarks")
	cfgf="pwf_speed_$id.json"
	"$APP" run_socks flag="pwf_speed_$id" node="$id" bind=127.0.0.1 socks_port="$port" config_file="$cfgf" >/dev/null 2>&1
	sleep 2
	raw=$(curl -fsSL --connect-timeout 5 --max-time 25 \
		-x "socks5h://127.0.0.1:$port" \
		-o /dev/null -w '%{speed_download}' \
		"https://speed.cloudflare.com/__down?bytes=1048576" 2>/dev/null || true)
	ps w | grep "[p]wf_speed_$id\.json" | awk '{print $1}' | xargs kill -9 2>/dev/null
	rm -f "/tmp/etc/passwall/$cfgf"
	if [ -n "$raw" ]; then
		speed_kbps=$(awk -v b="$raw" 'BEGIN { if (b+0 > 0) printf "%d", (b+0)/1024; else print 0 }')
	else
		speed_kbps=0
	fi
	pass=$(awk -v s="$speed_kbps" -v m="$MIN_SPEED_KBPS" 'BEGIN { print (s >= m) ? 1 : 0 }')
	if [ "$pass" = 1 ]; then
		echo "$id" >> "$TMP/speed_ok.txt"
		log "  SPEED OK   $name: ${speed_kbps} KB/s (minimum ${MIN_SPEED_KBPS} KB/s)"
	else
		log "  SPEED FAIL $name: ${speed_kbps} KB/s (minimum ${MIN_SPEED_KBPS} KB/s)"
	fi
}

cleanup() {
	trap - EXIT INT TERM
	ps w | grep '[p]wf_.*\.json' | awk '{print $1}' | xargs kill -9 2>/dev/null
	rm -f /tmp/etc/passwall/pwf_*.json
	uci -q delete $PW.pwfilter_sub
	uci -q commit $PW
	if [ "$PW_STOPPED" = 1 ] && [ "$RESTART_AFTER" = 1 ]; then
		log "starting Passwall again"
		/etc/init.d/passwall restart >/dev/null 2>&1
	fi
	rm -rf "$LOCKDIR"
}

do_run() {
	SUB_URL=$(c sub_url "")
	REMARK=$(c remark pwfilter)
	TCP_TIMEOUT=$(c tcp_timeout 2)
	TCP_TRIES=$(c tcp_tries 2)
	TCP_PAR=$(c tcp_parallel 20)
	YT_URLS=$(uci -q get $CFG.main.yt_url)
	[ -n "$YT_URLS" ] || YT_URLS="https://www.youtube.com/generate_204"
	YT_MODE=$(c yt_mode any)
	YT_TIMEOUT=$(c yt_timeout 8)
	YT_PAR=$(c yt_parallel 3)
	STOP_PW=$(c stop_passwall 1)
	RESTART_AFTER=$(c restart_after 1)
	MAX_NODES=$(c max_nodes 10)
	BATCH_SIZE=$(c batch_size 30)
	REPEAT_UNTIL_FULL=$(c repeat_until_full 1)
	CHECK_EXISTING_NODES=$(c check_existing_nodes 1)
	SPEED_TEST=$(c speed_test 1)
	MIN_SPEED_KBPS=$(c min_speed_kbps 200)
	case "$REPEAT_UNTIL_FULL" in 1|0) ;; *) REPEAT_UNTIL_FULL=1 ;; esac
	case "$CHECK_EXISTING_NODES" in 1|0) ;; *) CHECK_EXISTING_NODES=1 ;; esac
	case "$SPEED_TEST" in 1|0) ;; *) SPEED_TEST=1 ;; esac
	case "$MIN_SPEED_KBPS" in ''|*[!0-9]*) MIN_SPEED_KBPS=200 ;; esac
	[ "$MIN_SPEED_KBPS" -ge 1 ] 2>/dev/null || MIN_SPEED_KBPS=200
	case "$MAX_NODES" in ''|*[!0-9]*) MAX_NODES=10 ;; esac
	[ "$MAX_NODES" -ge 1 ] 2>/dev/null || MAX_NODES=10
	case "$BATCH_SIZE" in ''|*[!0-9]*) BATCH_SIZE=30 ;; esac
	[ "$BATCH_SIZE" -ge 1 ] 2>/dev/null || BATCH_SIZE=30
	[ "$TCP_PAR" -ge 1 ] 2>/dev/null || TCP_PAR=1
	[ "$YT_PAR" -ge 1 ] 2>/dev/null || YT_PAR=1

	[ -n "$SUB_URL" ] || { log "subscription URL is empty"; return 1; }
	[ -x "$APP" ] || { log "Passwall not found ($APP)"; return 1; }
	[ -f /usr/share/passwall/subscribe.lua ] || { log "subscribe.lua not found"; return 1; }
	command -v curl >/dev/null 2>&1 || { log "curl is missing"; return 1; }

	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null)
		if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
			log "already running (pid $oldpid)"
			return 1
		fi
		rm -rf "$LOCKDIR"
		mkdir "$LOCKDIR" || return 1
	fi
	echo $$ > "$LOCKDIR/pid"
	trap cleanup EXIT
	trap 'cleanup; exit 1' INT TERM

	rm -rf "$TMP"; mkdir -p "$TMP" /tmp/etc/passwall
	WAS_ENABLED=$(uci -q get $PW.@global[0].enabled)
	if [ "$STOP_PW" = 1 ] && [ "$WAS_ENABLED" = 1 ]; then
		log "stopping Passwall (so TCP checks use direct internet) ..."
		/etc/init.d/passwall stop >/dev/null 2>&1
		PW_STOPPED=1
		sleep 2
	fi

	log "preparing randomized subscription queue; take/test per batch: $BATCH_SIZE; stop target (healthy nodes in group): $MAX_NODES; repeat-until-target: $REPEAT_UNTIL_FULL"
	prepare_random_subscription || return 1

	# Optionally validate nodes already in the target group. When disabled,
	# leave them untouched and only test IDs introduced by each new import.
	if [ "$CHECK_EXISTING_NODES" = 1 ]; then
		log "initial check of existing group nodes (enabled)"
		check_and_clean_group || {
			[ $? -eq 2 ] && { log "stopped by user"; return 130; }
			return 1
		}
	else
		log "checking existing group nodes is disabled; old nodes will be skipped"
	fi

	# Existing nodes count toward the target. In only-new mode, imports are
	# capped to free slots and pre-existing nodes are never trimmed or tested.
	batch_no=0
	while :; do
		check_stop_requested && { log "stopped by user"; return 130; }
		healthy=$(count_group_nodes)
		if [ "$healthy" -ge "$MAX_NODES" ]; then
			log "target reached: $healthy healthy nodes (limit $MAX_NODES). stopping."
			break
		fi
		remaining=$(wc -l < "$TMP/sub.queue" | tr -d ' ')
		if [ "$remaining" -le 0 ]; then
			log "subscription candidates exhausted: $healthy/$MAX_NODES healthy nodes found. stopping."
			break
		fi
		# Import a configurable candidate batch (e.g. 30), test every node,
		# then retain at most MAX_NODES healthy nodes in the target group.
		batch=$BATCH_SIZE
		[ "$remaining" -lt "$batch" ] && batch=$remaining
		if [ "$CHECK_EXISTING_NODES" != 1 ]; then
			free_slots=$((MAX_NODES - healthy))
			[ "$free_slots" -gt 0 ] || break
			[ "$free_slots" -lt "$batch" ] && batch=$free_slots
		fi
		batch_no=$((batch_no + 1))
		sed -n "1,${batch}p" "$TMP/sub.queue" > "$TMP/sub.batch"
		tail -n +$((batch + 1)) "$TMP/sub.queue" > "$TMP/sub.rest"
		mv "$TMP/sub.rest" "$TMP/sub.queue"
		log "cycle $batch_no: currently $healthy/$MAX_NODES in group; importing $batch random candidate(s) to test (remaining subscription candidates: $((remaining - batch)))"
		: > "$TMP/group_before.txt"
		node_ids > "$TMP/group_before.txt"
		import_batch "$TMP/sub.batch" || {
			log "batch import failed; continuing with next candidates if available"
		}
		if [ "$CHECK_EXISTING_NODES" = 1 ]; then
			check_and_clean_group
		else
			node_ids | while read id; do
				grep -qx "$id" "$TMP/group_before.txt" || echo "$id"
			done > "$TMP/new_nodes.txt"
			new_count=$(wc -l < "$TMP/new_nodes.txt" | tr -d ' ')
			log "only-new mode: testing $new_count newly imported node(s); existing nodes are skipped"
			check_and_clean_group "$TMP/new_nodes.txt"
		fi
		case "$?" in
		2) log "stopped by user"; return 130 ;;
		0) : ;;
		*) return 1 ;;
		esac
		if [ "$REPEAT_UNTIL_FULL" != 1 ]; then
			log "repeat-until-full is disabled; one import/check cycle completed."
			break
		fi
	done
	log "finished. healthy nodes in group: $(count_group_nodes)/$MAX_NODES"
	return 0
}

do_cron() {
	touch /etc/crontabs/root
	# Remove only pwfilter-owned cron entries; never touch Passwall service schedules.
	sed -i '/# pwfilter$/d; /# pwfilter-passwall-start$/d; /# pwfilter-passwall-stop$/d' /etc/crontabs/root
	if [ "$(c enabled 0)" = 1 ]; then
		interval=$(c interval_hours 1)
		case "$interval" in ''|*[!0-9]*) interval=1 ;; esac
		if [ "$interval" -ge 1 ] && [ "$interval" -le 24 ]; then
			echo "0 */$interval * * * /usr/bin/pwfilter run >$LOG 2>&1 # pwfilter" >> /etc/crontabs/root
		else
			log "invalid interval_hours '$interval'; expected 1..24; schedule not installed"
		fi
	fi
	/etc/init.d/cron restart >/dev/null 2>&1
}

case "$1" in
	run) do_run; exit $? ;;
	bg)
		if command -v setsid >/dev/null 2>&1; then
			setsid "$0" run >"$LOG" 2>&1 </dev/null &
		else
			"$0" run >"$LOG" 2>&1 </dev/null &
		fi
		;;
	stop)
		pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
		if [ -n "$pid" ]; then
			touch "$LOCKDIR/stop"
			kill -TERM "$pid" 2>/dev/null
			echo "Stop requested for pwfilter (PID $pid)."
		else
			echo "pwfilter is not running."
		fi
		;;
	cron_sync) do_cron ;;
	*) echo "usage: pwfilter {run|bg|stop|cron_sync}" ;;
esac
PWF_MAIN
chmod +x /usr/bin/pwfilter

# ------------------------------------------------------------------ UCI config
if [ ! -f /etc/config/pwfilter ]; then
cat > /etc/config/pwfilter <<'PWF_CFG'
config pwfilter 'main'
	option enabled '0'
	option sub_url ''
	option remark 'pwfilter'
	option tcp_timeout '2'
	option tcp_tries '2'
	option tcp_parallel '20'
	option yt_mode 'any'
	option yt_timeout '8'
	option yt_parallel '3'
	list yt_url 'https://www.youtube.com/generate_204'
	list yt_url 'https://www.youtube.com/robots.txt'
	option stop_passwall '1'
	option restart_after '1'
	option max_nodes '10'
	option batch_size '30'
	option repeat_until_full '1'
	option check_existing_nodes '1'
	option speed_test '1'
	option min_speed_kbps '200'
	option interval_hours '1'
PWF_CFG
fi

# Add new options to an existing installation without overwriting any saved settings.
for item in "max_nodes:10" "batch_size:30" "repeat_until_full:1" "check_existing_nodes:1" "speed_test:1" "min_speed_kbps:200" "interval_hours:1"; do
	key=${item%%:*}
	value=${item#*:}
	if ! uci -q get "pwfilter.main.$key" >/dev/null 2>&1; then
		uci set "pwfilter.main.$key=$value"
	fi
done
uci commit pwfilter

# ------------------------------------------------------------------ init script
cat > /etc/init.d/pwfilter <<'PWF_INIT'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
	/usr/bin/pwfilter cron_sync
}

service_triggers() {
	procd_add_reload_trigger pwfilter
}
PWF_INIT
chmod +x /etc/init.d/pwfilter

# ------------------------------------------------------------------ LuCI
cat > /usr/share/luci/menu.d/luci-app-pwfilter.json <<'PWF_MENU'
{
	"admin/services/pwfilter": {
		"title": "Passwall Node Filter",
		"order": 60,
		"action": {
			"type": "view",
			"path": "pwfilter/main"
		},
		"depends": {
			"acl": [ "luci-app-pwfilter" ],
			"uci": { "pwfilter": true }
		}
	}
}
PWF_MENU

cat > /usr/share/rpcd/acl.d/luci-app-pwfilter.json <<'PWF_ACL'
{
	"luci-app-pwfilter": {
		"description": "Grant access to Passwall Node Filter",
		"read": {
			"file": {
				"/tmp/pwfilter.log": [ "read" ],
				"/var/run/pwfilter.lock/pid": [ "read" ],
				"/usr/bin/pwfilter": [ "exec" ]
			},
			"uci": [ "pwfilter" ]
		},
		"write": {
			"uci": [ "pwfilter" ]
		}
	}
}
PWF_ACL

cat > /www/luci-static/resources/view/pwfilter/main.js <<'PWF_JS'
'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

var BIN = '/usr/bin/pwfilter';
var LOGF = '/tmp/pwfilter.log';
var PIDF = '/var/run/pwfilter.lock/pid';

return view.extend({
	render: function () {
		var m, s, o;

		m = new form.Map('pwfilter', _('Passwall Node Filter'),
			_('Choose whether existing nodes are re-tested or only newly imported nodes are checked. A node failing an enabled test is deleted. Automatic scheduling runs pwfilter only; it does not schedule Passwall on/off.'));

		s = m.section(form.NamedSection, 'main', 'pwfilter');
		s.addremove = false;

		o = s.option(form.Value, 'sub_url', _('Subscription URL'));
		o.rmempty = false;
		o.placeholder = 'https://example.com/sub';

		o = s.option(form.Value, 'batch_size', _('How many configs to take from subscription per batch'),
			_('Number of random subscription configs imported for testing in each batch. Example: 30 means take 30 configs from the subscription and test them all in this batch. This is the batch size, not the final number kept in the group.'));
		o.datatype = 'range(1,200)';
		o.default = '30';

		o = s.option(form.Value, 'max_nodes', _('Stop when this many healthy configs are in the group'),
			_('Target number of healthy configs to keep in the Passwall group. Example: set 10 while batch size is 30: pwfilter takes and tests 30 random subscription configs, keeps up to 10 that pass TCP and YouTube, and stops once the group has 10 healthy configs.'));
		o.datatype = 'range(1,200)';
		o.default = '10';

		o = s.option(form.Flag, 'repeat_until_full', _('Automatically take more batches until the healthy target is reached'),
			_('Enabled: if the first batch does not produce the target number of healthy configs, pwfilter takes another random batch and tests it. It stops when the configured healthy target is reached, the subscription runs out, or you press Stop. Disabled: it takes and tests only one batch, then stops even if the target has not been reached.'));
		o.default = '1';

		o = s.option(form.Flag, 'check_existing_nodes', _('Also test nodes already in the group'),
			_('Enabled: at the start of each run, all existing nodes in the selected group are tested again, along with newly imported nodes. Disabled: existing nodes are left untouched; only nodes imported during this run are tested. The group target still counts existing nodes when deciding how many new configs are needed.'));
		o.default = '1';

		o = s.option(form.Flag, 'speed_test', _('Enable 1 MB download speed test'),
			_('After TCP and YouTube tests, download a 1 MB sample through each node. Nodes below the minimum speed are removed. Tests run one at a time to avoid competing with each other.'));
		o.default = '1';

		o = s.option(form.Value, 'min_speed_kbps', _('Minimum acceptable speed (KB/s)'),
			_('Set your own minimum download speed. Example: 200 means a node must average at least 200 KB/s during the 1 MB test.'));
		o.datatype = 'uinteger';
		o.default = '200';
		o.depends('speed_test', '1');

		o = s.option(form.Value, 'remark', _('Node group name'),
			_('Letters, digits, - and _ only. Nodes are added to Passwall under this group.'));
		o.default = 'pwfilter';
		o.validate = function (section_id, value) {
			return /^[A-Za-z0-9_-]+$/.test(value) || _('Only letters, digits, - and _');
		};

		o = s.option(form.Flag, 'enabled', _('Enable automatic pwfilter run'));
		o.description = _('Run the filter repeatedly at the selected hourly interval. This schedules pwfilter only, not Passwall on/off.');
		o.default = '0';

		o = s.option(form.ListValue, 'interval_hours', _('Run automatically every (hours)'));
		for (var h = 1; h <= 24; h++) o.value(String(h), h + (h === 1 ? ' hour' : ' hours'));
		o.default = '1';
		o.depends('enabled', '1');

		o = s.option(form.DynamicList, 'yt_url', _('YouTube test URLs'));
		o.placeholder = 'https://www.youtube.com/generate_204';

		o = s.option(form.ListValue, 'yt_mode', _('YouTube requirement'));
		o.value('any', _('at least one URL returns HTTP 2xx'));
		o.value('all', _('all URLs return HTTP 2xx'));
		o.default = 'any';

		o = s.option(form.Value, 'tcp_timeout', _('TCP ping timeout (s)'));
		o.datatype = 'uinteger';
		o.default = '2';

		o = s.option(form.Value, 'tcp_tries', _('TCP ping attempts'));
		o.datatype = 'uinteger';
		o.default = '2';

		o = s.option(form.Value, 'tcp_parallel', _('TCP ping parallel jobs'));
		o.datatype = 'uinteger';
		o.default = '20';

		o = s.option(form.Value, 'yt_timeout', _('YouTube test timeout (s)'));
		o.datatype = 'uinteger';
		o.default = '8';

		o = s.option(form.Value, 'yt_parallel', _('YouTube test parallel jobs'));
		o.datatype = 'uinteger';
		o.default = '3';

		o = s.option(form.Flag, 'stop_passwall', _('Stop Passwall during the run'));
		o.default = '1';

		o = s.option(form.Flag, 'restart_after', _('Start Passwall again afterwards'));
		o.default = '1';

		return m.render().then(L.bind(function (mapEl) {
			var tabs = E('div', { 'class': 'cbi-tabmenu' });
			var configTab = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Settings'));
			var logTab = E('button', { 'class': 'cbi-button' }, _('Live log'));
			var configPane = E('div', {}, [ mapEl ]);
			var statusEl = E('strong', {}, _('Checking...'));
			var logEl = E('pre', {
				'style': 'height:60vh;max-height:700px;overflow:auto;white-space:pre-wrap;word-break:break-word;background:#111;color:#ddd;padding:12px;border-radius:4px;font-family:monospace;font-size:12px'
			}, _('No log yet.'));
			var logPane = E('div', { 'style': 'display:none' }, [
				E('div', { 'class': 'cbi-section' }, [
					E('h3', _('Live log')),
					E('p', [ _('Status: '), statusEl ]),
					E('p', _('Log refreshes automatically every second.')),
					logEl
				])
			]);

			function showTab(which) {
				var isLog = which === 'log';
				configPane.style.display = isLog ? 'none' : '';
				logPane.style.display = isLog ? '' : 'none';
				configTab.className = isLog ? 'cbi-button' : 'cbi-button cbi-button-action';
				logTab.className = isLog ? 'cbi-button cbi-button-action' : 'cbi-button';
			}

			configTab.addEventListener('click', function () { showTab('config'); });
			logTab.addEventListener('click', function () { showTab('log'); });
			tabs.append(configTab, logTab);

			var runBtn = E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, function () {
					return fs.exec(BIN, ['bg']).then(function () {
						ui.addNotification(null, E('p', _('Started. Open the Live log tab to follow progress.')), 'info');
					}).catch(function (e) {
						ui.addNotification(null, E('p', e.message));
					});
				})
			}, _('Run now'));

			var stopBtn = E('button', {
				'class': 'cbi-button cbi-button-negative',
				'style': 'margin-left:.5em',
				'click': ui.createHandlerFn(this, function () {
					return fs.exec(BIN, ['stop']);
				})
			}, _('Stop'));

			var runControls = E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Run')),
				E('p', _('Save & Apply the settings first, then press Run now.')),
				E('div', {}, [ runBtn, stopBtn ])
			]);
			configPane.appendChild(runControls);

			poll.add(function () {
				return Promise.all([
					fs.read_direct(LOGF).catch(function () { return ''; }),
					fs.read_direct(PIDF).catch(function () { return ''; })
				]).then(function (values) {
					logEl.textContent = values[0] || _('No log yet. Run pwfilter from the Settings tab.');
					logEl.scrollTop = logEl.scrollHeight;
					var pid = (values[1] || '').trim();
					statusEl.textContent = pid ? _('Running (PID ') + pid + ')' : _('Not running');
				});
			}, 1);

			return E('div', {}, [ tabs, configPane, logPane ]);
		}, this));
	}
});
PWF_JS

# ------------------------------------------------------------------ finish
/etc/init.d/pwfilter enable
/etc/init.d/pwfilter start
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
/etc/init.d/rpcd restart

echo
echo "Done. Open LuCI -> Services -> Passwall Node Filter."
echo "Requirements: luci-app-passwall, xray-core (or sing-box), curl, tcping or nc."
