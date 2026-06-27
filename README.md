# claude-cli-warmup

Keep the Claude CLI floating quota window **warm** with an unattended,
reboot-surviving job. On a fixed cadence it makes a single ultra-lightweight
call — `claude -p` with a prompt that forces a one-character answer (the digit
`1`) — which touches the rolling quota window while keeping both input and
output tokens minimal.

Runs **locally** (launchd on macOS, cron on Linux, Task Scheduler on Windows)
**and/or in the cloud** via GitHub Actions — so the window stays warm even when
your own machine is off or asleep.

## Which installer do I use?

| Your OS     | Use this installer            | Scheduler       | Guide                          |
| ----------- | ----------------------------- | --------------- | ------------------------------ |
| **macOS**   | `install/install-launchd.sh`  | launchd         | [Version 1a](#version-1a--macos-bash--launchd--recommended) |
| **Linux**   | `install/install-cron.sh`     | cron            | [Version 1b](#version-1b--linux-bash--cron) |
| **Windows** | `install/install-task.ps1`    | Task Scheduler  | [Version 2](#version-2--windows-powershell--task-scheduler) |

> **macOS users: do not use `install-cron.sh`.** cron on macOS cannot reach the
> login Keychain, so the warmup fails with `Not logged in`. Use the launchd
> installer (Version 1a). cron is the correct choice on **Linux** only.

The GitHub Actions cloud job (Version 3) works on any OS and complements the
local installer above.

## What it does

- Runs the minimal warmup call **at boot** and on a **configurable interval
  (default every 2 hours)**, anchored to an hour you choose on first install.
- Also ships a **GitHub Actions** workflow that runs the same call on a schedule
  from the cloud as a fallback for when your machine is off.
- Appends a timestamped result to `~/claude_warmup.log` (exact timestamp,
  success/failure, exit code, and raw error output on failure).
- Fires a **native desktop notification** on failure
  (`osascript` on macOS, `notify-send` on Linux, Toast/Balloon on Windows).
- Explicitly bootstraps PATH/environment so the `claude` executable resolves
  when launched non-interactively by cron / Task Scheduler.

## Layout

```
bin/claude-warmup.sh           # macOS/Linux warmup script
bin/claude-warmup.ps1          # Windows warmup script
install/install-launchd.sh     # macOS scheduler installer (launchd — recommended)
install/install-cron.sh        # Linux scheduler installer (cron)
install/install-task.ps1       # Windows scheduler installer (Task Scheduler)
.github/workflows/warmup.yml   # GitHub Actions cloud warmup (scheduled)
```

The first-run anchor hour is persisted to:
- macOS/Linux: `~/.config/claude-warmup/config`
- Windows: `%APPDATA%\claude-warmup\config`

---

## Version 1a — macOS (Bash + launchd) — recommended

On macOS the Claude CLI reads its login token from the **login Keychain**, and
**cron cannot reach it**: cron jobs run in the system bootstrap context, outside
your GUI (Aqua) login session, so they fail with `Not logged in` no matter how
`USER`/`LOGNAME`/`PATH` are set. A **launchd LaunchAgent** is loaded into your
login session, so the Keychain lookup succeeds — and it also catches up runs
missed while the Mac was asleep (cron does not). Use launchd on macOS.

### Prerequisites
- The `claude` CLI installed and working interactively (`claude -p "."`).
- You are logged in to the macOS desktop (the LaunchAgent runs in your GUI
  session; it does not run while logged out).

### Install
```bash
# From the repo root:
chmod +x bin/claude-warmup.sh install/install-launchd.sh
./install/install-launchd.sh
```
On the **first run** it prompts for an anchor hour (0–23) and saves it (along
with the interval, default 2h). It writes a LaunchAgent to
`~/Library/LaunchAgents/com.rocketbyte.claude-warmup.plist` with `RunAtLoad`
(fires at login, after the Keychain is unlocked) plus a `StartCalendarInterval`
entry every N hours from the anchor, and loads it immediately.

To use a different interval (e.g. the old 5-hour cadence):
```bash
./install/install-launchd.sh --interval 5
```

### Verify
```bash
# 1. Run the warmup directly and check the log:
./bin/claude-warmup.sh && tail -n 1 ~/claude_warmup.log

# 2. Confirm the LaunchAgent is loaded and the last run succeeded:
launchctl print "gui/$(id -u)/com.rocketbyte.claude-warmup" | grep -E 'state|last exit'

# 3. Force a run now:
launchctl kickstart -k "gui/$(id -u)/com.rocketbyte.claude-warmup"; tail -n 1 ~/claude_warmup.log
```

### Reconfigure / Uninstall
```bash
./install/install-launchd.sh --reconfigure   # change the anchor hour
./install/install-launchd.sh --interval 3    # change the interval (hours)
./install/install-launchd.sh --uninstall     # remove the LaunchAgent
```

### macOS notes
- The warmup only keeps the quota window warm — it cannot log you in. If you ever
  see `Not logged in · Please run /login` in the log, run `claude` once
  interactively to re-authenticate.
- The LaunchAgent runs only while you are logged in to the desktop. For a job
  that runs with no one logged in you would need a system LaunchDaemon plus a
  file-based credential — out of scope here; use the GitHub Actions fallback
  (Version 3) for off/asleep coverage.

---

## Version 1b — Linux (Bash + cron)

On Linux the CLI does not depend on a GUI Keychain, so cron works.

### Prerequisites
- The `claude` CLI installed and working interactively (`claude -p "."`).
- `cron` available (preinstalled on most Linux distros).
- Notifications need `notify-send` (package `libnotify-bin` / `libnotify`).

### Install
```bash
# From the repo root:
chmod +x bin/claude-warmup.sh install/install-cron.sh
./install/install-cron.sh
```
On the **first run** it prompts for an anchor hour (0–23) and saves it (along
with the interval, default 2h). It then writes a tagged, idempotent block to
your crontab:

```cron
# >>> claude-warmup >>>
@reboot /abs/path/bin/claude-warmup.sh >/dev/null 2>&1
0 9,11,13,15,17,19,21,23,1,3,5,7 * * * /abs/path/bin/claude-warmup.sh >/dev/null 2>&1   # anchor 9, every 2h
# <<< claude-warmup <<<
```

To use a different interval (e.g. the old 5-hour cadence):
```bash
./install/install-cron.sh --interval 5
```

### Verify
```bash
# 1. Run the warmup directly and check the log:
./bin/claude-warmup.sh && tail -n 1 ~/claude_warmup.log

# 2. Confirm the cron entries are installed:
crontab -l

# 3. Confirm it works with a STRIPPED environment (simulates cron):
env -i HOME="$HOME" /bin/sh -c '/abs/path/bin/claude-warmup.sh'; tail -n 1 ~/claude_warmup.log
```

### Reconfigure / Uninstall
```bash
./install/install-cron.sh --reconfigure   # change the anchor hour
./install/install-cron.sh --interval 3    # change the interval (hours)
./install/install-cron.sh --uninstall     # remove the cron block
```

> **macOS users:** do not use `install-cron.sh` — see Version 1a (launchd).
> cron on macOS cannot access the login Keychain and the job will fail with
> `Not logged in`.

---

## Version 2 — Windows (PowerShell + Task Scheduler)

### Prerequisites
- The `claude` CLI installed and working interactively.
- PowerShell 5.1+ (built in) or PowerShell 7+.
- Run the installer from an **elevated (Administrator)** PowerShell so the task
  can be registered with highest privileges.

### Install
```powershell
# From the repo root, in an elevated PowerShell:
powershell -ExecutionPolicy Bypass -File .\install\install-task.ps1
```
On the **first run** it prompts for an anchor hour (0–23) and saves it, then
registers a scheduled task named `ClaudeWarmup` that runs:
- at system startup, and
- daily at the anchor hour, repeating every 2 hours (configurable via
  `-IntervalHours`),

with `-RunLevel Highest`, `StartWhenAvailable`, and `WakeToRun` so runs missed
while the machine was off/asleep fire on resume.

### Verify
```powershell
# 1. Run the warmup directly and check the log:
powershell -ExecutionPolicy Bypass -File .\bin\claude-warmup.ps1
Get-Content "$HOME\claude_warmup.log" -Tail 1

# 2. Confirm the task exists and inspect its triggers:
Get-ScheduledTask -TaskName ClaudeWarmup | Get-ScheduledTaskInfo

# 3. Force a run now:
Start-ScheduledTask -TaskName ClaudeWarmup
```

### Reconfigure / Uninstall
```powershell
powershell -ExecutionPolicy Bypass -File .\install\install-task.ps1 -Reconfigure
powershell -ExecutionPolicy Bypass -File .\install\install-task.ps1 -Uninstall
```

---

## Version 3 — GitHub Actions (cloud fallback)

Runs the warmup from GitHub's servers on a schedule, so the quota window stays
warm **even when your own machine is off or asleep** — the one gap that local
cron can't cover. Useful as a complement to (not a replacement for) the local
job. Workflow: [`.github/workflows/warmup.yml`](.github/workflows/warmup.yml).

### Setup
1. Generate a Claude Code OAuth token from your Pro/Max subscription, locally:
   ```bash
   claude setup-token
   ```
2. In the repo on GitHub: **Settings → Secrets and variables → Actions → New
   repository secret**, name it `CLAUDE_CODE_OAUTH_TOKEN`, paste the token.
3. The workflow then runs every 2 hours automatically, and you can trigger it
   manually from the **Actions** tab (**Run workflow**).

> **Use the OAuth token, not an API key.** `ANTHROPIC_API_KEY` is a separate
> pay-per-token billing path and would *not* warm your subscription quota window.

### Caveats
- GitHub cron is **UTC only** and scheduled runs can be **delayed or skipped**
  under load, so the cadence is approximate.
- Scheduled workflows are **auto-disabled after 60 days** of repo inactivity
  (re-enable from the Actions tab).
- Stores a long-lived credential as a repo secret — keep the repo private if
  that's a concern.

---

## Known limitations

- **Cadence at the day wrap:** the default 2h interval divides 24 evenly, so the
  cadence is perfectly even. Intervals that don't divide 24 (e.g. `--interval 5`)
  leave one shorter gap at the day wrap. Acceptable for a keep-warm job.
- **Missed runs:** on macOS, launchd runs a missed `StartCalendarInterval` job
  when the Mac wakes, and `RunAtLoad` covers login. On Linux, cron does **not**
  catch up runs missed while the machine was off; the `@reboot` trigger covers
  the next power-on. Windows Task Scheduler catches up via `StartWhenAvailable`.
- **Headless hosts:** if no notifier is available (e.g. SSH/headless), the
  failure is still logged — the missing notifier never crashes the run.
- **Log growth:** `~/claude_warmup.log` is append-only and unbounded; rotate or
  truncate it manually if desired.