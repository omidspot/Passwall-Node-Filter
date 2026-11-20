# luci-app-pwfilter — Passwall Node Filter

**English** | [فارسی](README.fa.md)

A LuCI app for OpenWrt that keeps your [Passwall](https://github.com/xiaorouji/openwrt-passwall) node list healthy. It pulls random batches of nodes from your subscription, tests them, and keeps only the good ones.

> ✅ **Tested** on a **Linksys EA8100** running **OpenWrt 23.05** with `luci-app-passwall` — it worked fine.

---

### Features

- Shuffles the whole subscription and imports nodes in **random batches** (you choose the batch size).
- Each batch is imported into a **temporary group** (`<name>_tmp`), so healthy nodes from earlier batches are never wiped by a new import.
- Three test stages — a node that fails an enabled stage is deleted:
  1. **TCP ping** (direct, Passwall stopped, parallel)
  2. **URL test** through the node (one or more URLs you choose, "any" or "all" must return HTTP 2xx)
  3. **Real Delay test** (like v2rayNG's *Test real delay*): a full HTTPS request through the node to a configurable URL (e.g. `generate_204`), best of N attempts, maximum delay in ms
- Keeps at most **N healthy nodes**; when there are more, the ones with the **lowest delay** are kept.
- Repeats batches automatically until the target is reached, the subscription runs out, or you press **Stop**.
- Optionally re-tests existing nodes of the group at the start of each run.
- Optional scheduled run (every 1–24 hours) via cron. It schedules pwfilter only, never Passwall on/off.
- Live log inside LuCI, Run / Stop buttons.

### Requirements

- OpenWrt 23.05 with LuCI
- `luci-app-passwall` and a core (`xray-core` or `sing-box`)
- `curl`
- `tcping` or `nc` (optional — falls back to `curl` if `nc` lacks `-z`)
- A subscription that is a **URI list** (plain or base64). Clash YAML and SSD are not supported.

### Installation

**From LuCI (easiest)**

1. Download `luci-app-pwfilter_2.3.2-1_all.ipk` from the [Releases](../../releases) page.
2. Open **System → Software**.
3. Click **Upload Package…**, choose the `.ipk`, then **Upload** and **Install**.
4. Reload the LuCI page. The app appears under **Services → Passwall Node Filter**.

**From SSH**

```sh
scp luci-app-pwfilter_2.3.2-1_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
opkg install /tmp/luci-app-pwfilter_2.3.2-1_all.ipk
```

**Uninstall**

```sh
opkg remove luci-app-pwfilter
```

### Usage

1. Go to **Services → Passwall Node Filter**.
2. Enter your **Subscription URL**.
3. Set **batch size** (e.g. `30`) and **healthy target** (e.g. `10`).
4. Adjust the Real Delay test (default: max `10000` ms) and other options if you want.
5. Click **Save & Apply**, then **Run now**.
6. Watch progress in the **Live log** tab. Use **Stop** to cancel.
7. **Reset to defaults** (next to Run / Stop) restores every setting, including the subscription URL, to the initial values. Nodes already in Passwall are not touched.

The kept nodes appear in Passwall under the group name you chose (default `pwfilter`).

### Settings

| Option | Meaning |
|---|---|
| Subscription URL | URI-list subscription (plain or base64) |
| Batch size | How many random configs are imported and tested per cycle |
| Healthy target | Stop when this many healthy nodes are in the group |
| Repeat until target | Keep taking new batches, or test only one batch |
| Also test existing nodes | Re-test nodes already in the group at the start of a run |
| Real Delay test | Enable the v2rayNG-style delay test |
| Real Delay URLs | One or more test URLs (default `https://www.youtube.com/`); used in turn |
| Max delay (ms) | Nodes slower than this are removed (`0` = accept any answer) |
| Real Delay timeout / attempts / parallel | Timeout, number of attempts (lowest result is used), parallel jobs |
| Node group name | Passwall group for kept nodes (letters, digits, `-`, `_`) |
| URL test URLs / requirement | URLs to test and whether any or all must succeed |
| URL test / TCP options | Timeouts, attempts, parallel jobs |
| Stop Passwall during the run | Tests use the direct internet (recommended) |
| Start Passwall again afterwards | Restart Passwall when finished |
| Automatic run | Run every N hours via cron |

### Command line

```sh
pwfilter bg     # run in background (log: /tmp/pwfilter.log)
pwfilter run    # run in foreground
pwfilter stop   # stop a running job
pwfilter reset  # reset all settings to defaults
```

Config: `/etc/config/pwfilter`

### Notes & troubleshooting

- By default Passwall is **disabled during the run** exactly like on the Passwall page (Enable unticked + Save & Apply, so Passwall's DNS is switched off too) so tests use the direct internet. When the run ends or is stopped, Enable is ticked and applied again. If a run is killed (e.g. power loss), the next run restores Passwall first.
- Nothing imported? Check `/tmp/pwfilter/sub.log` (output of Passwall's `subscribe.lua`) and `/tmp/pwfilter.log`.
- The page title shows the installed version (e.g. `v2.3.2`). If you still see an old page after updating, press Ctrl+F5.
- The log prints the exact reason when a node fails (port did not open, timeout, HTTP error, too slow).
- Delay results depend on your line at that moment — adjust the maximum delay to your needs.

### Tested on

| Device | OpenWrt | Result |
|---|---|---|
| Linksys EA8100 | 23.05 | ✅ Works |
