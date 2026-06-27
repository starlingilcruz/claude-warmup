# claude-cli-warmup

Keep the Claude CLI floating quota window **warm** with an unattended,
reboot-surviving job. On a fixed cadence it makes a single ultra-lightweight
call — `claude -p` with a prompt that forces a one-character answer (the digit
`1`) — which touches the rolling quota window while keeping both input and
output tokens minimal.

## What it does

- Runs the minimal warmup call **at boot** and on a **configurable interval
  (default every 2 hours)**, anchored to an hour you choose on first install.
- Appends a timestamped result to `~/claude_warmup.log` (exact timestamp,
  success/failure, exit code, and raw error output on failure).
- Fires a **native desktop notification** on failure
  (`osascript` on macOS, `notify-send` on Linux, Toast/Balloon on Windows).
- Explicitly bootstraps PATH/environment so the `claude` executable resolves
  when launched non-interactively by cron / Task Scheduler.

## Layout

```
bin/claude-warmup.sh        # macOS/Linux warmup script
bin/claude-warmup.ps1       # Windows warmup script
install/install-cron.sh     # macOS/Linux scheduler installer (cron)
install/install-task.ps1    # Windows scheduler installer (Task Scheduler)
```

The first-run anchor hour is persisted to:
- macOS/Linux: `~/.config/claude-warmup/config`
- Windows: `%APPDATA%\claude-warmup\config`

---

## Version 1 — macOS / Linux (Bash + cron)

### Prerequisites
- The `claude` CLI installed and working interactively (`claude -p "."`).
- `cron` available (preinstalled on macOS and most Linux distros).
- Linux notifications also need `notify-send` (package `libnotify-bin` /
  `libnotify`). macOS uses the built-in `osascript`.

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

### macOS notes
- The first cron run may prompt for Full Disk Access for `cron`/`/usr/sbin/cron`
  under **System Settings → Privacy & Security**. Grant it so the job can run
  unattended.
- The CLI reads its login token from the **login Keychain**, whose lookup needs
  `USER`/`LOGNAME` — the warmup script sets these automatically if a bare cron
  environment omits them. The Keychain must be **unlocked** (it is after you log
  in to the desktop), so the `@reboot` run may not authenticate until you log in;
  the regular interval runs after login work normally.
- The warmup only keeps the quota window warm — it cannot log you in. If you ever
  see `Not logged in · Please run /login` in the log, run `claude` once
  interactively to re-authenticate.

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

## Known limitations

- **Cadence at the day wrap:** the default 2h interval divides 24 evenly, so the
  cadence is perfectly even. Intervals that don't divide 24 (e.g. `--interval 5`)
  leave one shorter gap at the day wrap. Acceptable for a keep-warm job.
- **Missed runs (Unix):** cron does not "catch up" runs missed while the machine
  was off; the `@reboot` trigger covers the next power-on. Windows Task Scheduler
  catches up via `StartWhenAvailable`.
- **Headless hosts:** if no notifier is available (e.g. SSH/headless), the
  failure is still logged — the missing notifier never crashes the run.
- **Log growth:** `~/claude_warmup.log` is append-only and unbounded; rotate or
  truncate it manually if desired.

## Spec

This project was designed and built spec-first with
[OpenSpec](https://github.com/Fission-AI/OpenSpec). See
`openspec/changes/add-claude-warmup-automation/` for the proposal, design,
specs, and task breakdown.
