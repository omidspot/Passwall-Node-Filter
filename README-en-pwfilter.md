# Passwall Node Filter (pwfilter)

`pwfilter` is an OpenWrt/LuCI helper for filtering subscription nodes managed by Passwall. It downloads a subscription, randomizes the supported URI entries, imports candidates in configurable batches, checks TCP reachability, tests YouTube access, and (by default) measures download throughput with a 1 MiB sample through each node. Nodes that fail an enabled test are removed from the configured Passwall group.

> [!WARNING]
> **This tool deletes nodes from Passwall.** A temporary router connectivity problem, an unreachable YouTube test URL, DNS trouble, or an overloaded router can cause valid nodes to fail and be deleted. Back up your Passwall configuration before using this tool. Use a dedicated Passwall group that contains only nodes you want `pwfilter` to manage.

## Features

- Fetches a subscription and accepts either a plain URI list or a Base64-encoded URI list.
- Removes exact duplicate URI lines from the downloaded subscription and randomizes the remaining candidates.
- Imports a configurable number of random candidates per batch.
- Tests each managed node in stages: direct TCP reachability, YouTube access, and an optional 1 MiB download-throughput test.
- Removes nodes that fail either test.
- Checks existing subscription-imported nodes in the selected group as well as newly imported nodes.
- Lets you set a custom minimum speed in KB/s; the default is 200 KB/s. Speed tests run sequentially to reduce interference between measurements.
- Keeps up to a configurable target number of healthy nodes in the group.
- Can automatically process additional batches until the healthy-node target is reached, the subscription queue is exhausted, or the user presses **Stop**.
- Can run manually from LuCI or automatically on a configurable hourly cron schedule.
- Provides a live log in a tab on the same LuCI page.
- Preserves existing `/etc/config/pwfilter` settings during reinstall and adds missing options with defaults.

## Compatibility and requirements

This installer is written for the following environment:

- OpenWrt 23.05.
- `luci-app-passwall` with its scripts under `/usr/share/passwall/`.
- Passwall's `/usr/share/passwall/subscribe.lua` and `/usr/share/passwall/app.sh`.
- `curl`.
- A TCP checking utility: `tcping` is preferred when installed; otherwise the script tries `nc`.
- A Passwall-supported proxy core (for example, Xray or sing-box) configured so Passwall can start a temporary local SOCKS instance for each node.
- LuCI and `rpcd` for the web interface.

The installer prints a short requirements reminder at the end. It does not guarantee compatibility with every router model, Passwall fork, Passwall version, or proxy-core build. Test on your own device before relying on scheduled runs.

## Installation

### 1. Download the installer

Download `install-pwfilter-batch-and-healthy-target.sh` from this repository (or from the repository's Releases page, if you publish releases).

### 2. Copy it to the router

For example, copy the file to `/tmp` using SCP or WinSCP. From a computer with SCP available:

```sh
scp install-pwfilter-batch-and-healthy-target.sh root@ROUTER_IP:/tmp/
```

Replace `ROUTER_IP` with the router's LAN IP address.

### 3. Run the installer over SSH

```sh
ssh root@ROUTER_IP
sh /tmp/install-pwfilter-batch-and-healthy-target.sh
```

The installer creates or updates these files:

- `/usr/bin/pwfilter` — main filtering script.
- `/etc/config/pwfilter` — UCI configuration.
- `/etc/init.d/pwfilter` — service script used to synchronize the cron schedule.
- `/www/luci-static/resources/view/pwfilter/main.js` — LuCI page.
- `/usr/share/luci/menu.d/luci-app-pwfilter.json` — LuCI menu entry.
- `/usr/share/rpcd/acl.d/luci-app-pwfilter.json` — LuCI RPC access rules.

It enables and starts the `pwfilter` init service to synchronize the schedule. It does **not** start a filtering run automatically just because installation completed.

Open:

**LuCI → Services → Passwall Node Filter**

If the menu does not appear immediately, refresh LuCI or sign out and back in.

## Initial setup

Open the **Settings** tab. Configure the subscription URL and group name, review the test options, then click **Save & Apply** before pressing **Run now**.

### Subscription URL

Enter the subscription URL. `pwfilter` downloads the response and checks whether it can extract URI-style proxy links.

Accepted input forms in this version:

- A plain text list with one URI per line.
- The same URI list encoded as Base64.

The script explicitly rejects SSD (`ssd://`) and responses it identifies as non-URI data (for example, a Clash YAML subscription). Convert unsupported formats to a plain URI list before using them. The URI must also be understood by the installed Passwall subscription importer; recognizing a URI scheme does not guarantee that every protocol or URI variant is supported by your Passwall build.

### Random subscription candidates per batch

Controls how many randomized subscription entries are selected and imported in each batch.

- Default: `30`.
- LuCI range: `1` to `200`.

For example, `30` means that up to 30 candidates are selected from the remaining randomized subscription queue for that batch. The last batch can contain fewer entries if fewer candidates remain.

### Healthy-node target

**Stop when this many healthy configs are in the group** sets the target number of healthy subscription-imported nodes to retain in the configured group.

- Default: `10`.
- LuCI range: `1` to `200`.

Example: with a batch size of `30` and a healthy-node target of `10`, the tool can import and test up to 30 candidates in a batch, remove failed nodes, and retain no more than 10 managed nodes after the checks and trimming step. The target is the final retained count; during a batch import, the group can temporarily contain more than the target before testing and cleanup finish.

Existing managed nodes in the selected group are checked first and count toward the target. If enough healthy nodes are already present, no new subscription batch is imported.

### Automatically take more batches until the healthy target is reached

This setting controls repetition within a single run. It is separate from the hourly schedule.

- **Enabled (default):** If the group has fewer healthy nodes than the target after a batch, the tool takes another random batch and tests it. It stops when the target is reached, the subscription candidates are exhausted, or the user presses **Stop**.
- **Disabled:** The tool processes at most one newly imported batch during that run. It stops after that batch is checked, even if the healthy-node target has not been reached.

The initial check of existing nodes still takes place when this option is disabled.

### Node group name

Sets the Passwall group name used by the tool. Default: `pwfilter`.

Use only letters, digits, hyphens (`-`), and underscores (`_`).

**Important:** The script identifies managed nodes by matching the configured group name and Passwall's `add_mode=2` marker. Other subscription-imported nodes in the same group can therefore be tested and deleted too. Manually added nodes without `add_mode=2` are not selected by this mechanism. Keep this group dedicated to `pwfilter`.

### YouTube test URLs

The default test URLs are:

```text
https://www.youtube.com/generate_204
https://www.youtube.com/robots.txt
```

You can edit the URL list in LuCI. The test sends requests through a temporary local SOCKS proxy for each node and checks the HTTP response code.

### Download speed test

The speed test is enabled by default and runs after TCP and YouTube checks. Each eligible node downloads a fixed 1 MiB sample through its temporary SOCKS connection from Cloudflare speed test infrastructure. The measured average is shown in the live log in KB/s.

- **Enable 1 MB download speed test:** turn throughput filtering on or off.
- **Minimum acceptable speed (KB/s):** enter your own threshold. The default is `200`; a node below this value is removed.
- Tests run one node at a time so simultaneous test downloads do not compete with each other.

This is a short 1 MiB sample, not a sustained-speed guarantee. Results can vary with temporary congestion and the test endpoint. If the speed test endpoint cannot be reached, the node receives a measured speed of `0 KB/s` and fails the enabled speed check.

### YouTube requirement

Choose how many configured YouTube URLs must return an HTTP 2xx response:

- **At least one URL returns HTTP 2xx (`any`, default):** a node passes if at least one test URL returns a 2xx response.
- **All URLs return HTTP 2xx (`all`):** a node passes only if every configured URL returns a 2xx response.

A node that does not meet the selected condition is removed from the group.

### TCP check settings

- **TCP ping timeout (s):** timeout for an individual TCP connection attempt. Default: `2` seconds.
- **TCP ping attempts:** number of attempts per node. Default: `2`.
- **TCP ping parallel jobs:** number of TCP checks run concurrently. Default: `20`.

The TCP stage checks whether the node's server address and port can be reached. It runs before the YouTube stage.

### YouTube check settings

- **YouTube test timeout (s):** maximum request duration for a test URL. Default: `8` seconds.
- **YouTube test parallel jobs:** number of node YouTube tests run concurrently. Default: `3`.

Lower parallelism may reduce CPU and memory pressure on low-powered routers, but can increase the total run time.

### Stop Passwall during the run

Enabled by default. If Passwall is enabled when the run starts, the script stops Passwall before the direct TCP checks. This is intended to keep the TCP stage from being routed through the proxy being tested. Client traffic using Passwall may be interrupted during the run.

### Start Passwall again afterwards

Enabled by default. If `pwfilter` stopped Passwall for the run and this option is enabled, the cleanup routine starts Passwall again when the run exits.

These options control Passwall during a filtering run. They are not a schedule for turning Passwall on or off.

## Automatic hourly runs

To schedule `pwfilter`:

1. Enable **Enable automatic pwfilter run**.
2. Select **Run automatically every (hours)** from 1 to 24.
3. Click **Save & Apply**.

The schedule is implemented with cron at minute zero of matching hours. For example, an interval of `1` schedules an hourly run; `3` schedules runs every three hours on matching clock hours. It is not necessarily an exact interval measured from the moment the option was enabled or from the end of the previous run.

If a previous run is still active, the lock prevents a second run from starting. Disabling the option and saving removes the `pwfilter`-owned cron entry. The schedule synchronization removes only entries marked for `pwfilter`; it does not schedule Passwall start/stop actions or intentionally remove unrelated cron jobs.

## Manual run, stop, and live log

On the **Passwall Node Filter** page:

- **Run now** starts `pwfilter` in the background.
- **Stop** requests that the current run stop.
- **Live log** displays the current log and refreshes automatically.

Always save and apply settings before starting a run.

## What happens during a run

1. The subscription is downloaded.
2. The response is decoded as Base64 when possible, or accepted as a plain URI list.
3. Exact duplicate URI lines are removed, and the remaining candidates are randomized.
4. Existing managed nodes in the selected group are checked.
5. The script performs direct TCP checks. Nodes that fail TCP are deleted.
6. Each TCP-live node is tested against the configured YouTube URLs through a temporary SOCKS instance. Nodes that fail the selected `any` or `all` condition are deleted.
7. The group is trimmed to the configured healthy-node target if it contains more managed nodes than the target.
8. If the group is still below the target, the script imports another batch when repetition is enabled (or one batch when repetition is disabled), then checks the group again.
9. The run ends when the target is reached, the subscription queue is exhausted, repetition is disabled after one batch, or the user requests Stop.
10. If configured, Passwall is started again during cleanup.

## Important behavior and limitations

- **Deletion is real:** failed nodes are deleted from Passwall UCI configuration. There is no all-failed safety bypass in this version. If all nodes fail TCP or the YouTube condition, all managed nodes in the selected group can be deleted.
- **Use a dedicated group:** all subscription-imported nodes in the configured group that have `add_mode=2` are candidates for testing and deletion, not only nodes added during the current run.
- **Duplicate handling is limited:** the script removes exact duplicate URI text lines from the downloaded subscription. It does not perform semantic identity matching across different URI spellings or compare a candidate against existing nodes by UUID/password/server/transport. Two differently written links for the same underlying account may both be imported.
- **Temporary group size:** the group can exceed the healthy target while a batch is being imported and tested. The script trims it after checks.
- **Retention order:** if more than the configured target number of nodes pass, the script keeps the first nodes in Passwall's enumerated order. It does not rank the retained nodes by speed or latency.
- **Subscription importer behavior:** the script invokes Passwall's subscription importer and waits briefly. Check the log and Passwall configuration if a batch does not import as expected.
- **Router resources:** high TCP or YouTube parallelism can increase CPU and memory usage.
- **Connectivity interruption:** if Passwall is stopped during a run, devices relying on it may temporarily lose proxied connectivity.

## Logs and troubleshooting

View the current log from SSH:

```sh
cat /tmp/pwfilter.log
```

Follow the log live:

```sh
tail -f /tmp/pwfilter.log
```

Check the cron entries:

```sh
cat /etc/crontabs/root
```

Run in the foreground from SSH:

```sh
/usr/bin/pwfilter run
```

Start in the background:

```sh
/usr/bin/pwfilter bg
```

Request a stop:

```sh
/usr/bin/pwfilter stop
```

Inspect the UCI settings:

```sh
uci show pwfilter
```

If no nodes pass the TCP stage, verify that the router has direct internet access while Passwall is stopped and that `tcping` or `nc` is installed. If TCP passes but YouTube checks fail, verify the proxy core, Passwall node configuration, DNS, and the configured YouTube test URLs.

## Backup and uninstall

Before installation or use, back up Passwall's configuration:

```sh
cp /etc/config/passwall /etc/config/passwall.pwfilter-backup
```

To restore that backup (this replaces the current Passwall config file):

```sh
cp /etc/config/passwall.pwfilter-backup /etc/config/passwall
uci commit passwall
/etc/init.d/passwall restart
```

To disable automatic runs, turn off **Enable automatic pwfilter run** in LuCI and click **Save & Apply**.

This installer does not provide a dedicated uninstaller. To remove the LuCI page and helper manually, first disable its schedule, then remove the files created by the installer and remove the `pwfilter` UCI configuration. Review each path before deleting it:

```sh
/etc/init.d/pwfilter disable
rm -f /usr/bin/pwfilter
rm -f /etc/init.d/pwfilter
rm -f /www/luci-static/resources/view/pwfilter/main.js
rm -f /usr/share/luci/menu.d/luci-app-pwfilter.json
rm -f /usr/share/rpcd/acl.d/luci-app-pwfilter.json
rm -rf /www/luci-static/resources/view/pwfilter
uci -q delete pwfilter
uci commit
/etc/init.d/rpcd restart
```

The commands above remove the tool's files and configuration; they do not restore nodes previously deleted from Passwall. Use your Passwall backup if restoration is needed.

## License

No license is specified by this installer. Add a `LICENSE` file to the repository if you intend to publish the project under an open-source license.
