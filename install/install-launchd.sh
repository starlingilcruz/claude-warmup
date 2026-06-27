#!/usr/bin/env bash
#
# install-launchd.sh — install/uninstall the Claude warmup schedule on macOS
#                      using a launchd LaunchAgent (recommended over cron).
#
# Why launchd instead of cron on macOS?
#   The Claude CLI reads its login token from the *login Keychain*. cron jobs
#   run in the system bootstrap context — outside your GUI (Aqua) login session —
#   so they cannot reach the login Keychain and fail with "Not logged in",
#   regardless of USER/LOGNAME/PATH. A LaunchAgent is loaded into your GUI
#   session, so the Keychain lookup succeeds. launchd also catches up runs
#   missed while the Mac was asleep, which cron does not.
#
# On first run it prompts for an anchor hour (0-23), persists it (shared with
# install-cron.sh in ~/.config/claude-warmup/config), and reuses it later.
# It writes ~/Library/LaunchAgents/<LABEL>.plist with:
#   - RunAtLoad (fires at login, after the Keychain is unlocked), and
#   - StartCalendarInterval entries every N hours from the anchor (default N=2).
#
# Usage:
#   ./install-launchd.sh                 # install (prompt for hour on first run)
#   ./install-launchd.sh --interval N    # set the interval in hours (default 2)
#   ./install-launchd.sh --reconfigure   # re-prompt for the anchor hour
#   ./install-launchd.sh --uninstall     # remove the LaunchAgent
#
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' "install-launchd.sh is macOS-only. On Linux use install-cron.sh." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARMUP_SCRIPT="${SCRIPT_DIR}/../bin/claude-warmup.sh"
WARMUP_SCRIPT="$(cd "$(dirname "${WARMUP_SCRIPT}")" && pwd)/$(basename "${WARMUP_SCRIPT}")"

CONFIG_DIR="${HOME}/.config/claude-warmup"
CONFIG_FILE="${CONFIG_DIR}/config"
LABEL="com.rocketbyte.claude-warmup"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DEFAULT_HOUR="$(date +%-H)"   # documented non-interactive default: current hour
DEFAULT_INTERVAL=2            # hours between warmup runs

log() { printf '%s\n' "$*" >&2; }

read_anchor() {
  [ -f "${CONFIG_FILE}" ] || return 1
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
  [ -n "${ANCHOR_HOUR:-}" ] || return 1
  printf '%s' "${ANCHOR_HOUR}"
}

prompt_anchor() {
  local hour
  if [ ! -t 0 ]; then
    log "Non-interactive run: using default anchor hour ${DEFAULT_HOUR}."
    printf '%s' "${DEFAULT_HOUR}"
    return 0
  fi
  while true; do
    printf 'Enter the anchor hour for the warmup (0-23) [%s]: ' "${DEFAULT_HOUR}" >&2
    read -r hour || hour=""
    hour="${hour:-${DEFAULT_HOUR}}"
    if [[ "${hour}" =~ ^[0-9]+$ ]] && [ "${hour}" -ge 0 ] && [ "${hour}" -le 23 ]; then
      printf '%s' "${hour}"
      return 0
    fi
    log "Invalid hour '${hour}'. Please enter an integer between 0 and 23."
  done
}

read_interval() {
  [ -f "${CONFIG_FILE}" ] || return 1
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
  [ -n "${INTERVAL_HOURS:-}" ] || return 1
  printf '%s' "${INTERVAL_HOURS}"
}

persist_config() {
  # persist_config <anchor> <interval>
  mkdir -p "${CONFIG_DIR}"
  {
    printf 'ANCHOR_HOUR=%s\n' "$1"
    printf 'INTERVAL_HOURS=%s\n' "$2"
  } > "${CONFIG_FILE}"
}

build_plist() {
  local anchor="$1"
  local interval="$2"
  local i h

  cat <<PLIST_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${WARMUP_SCRIPT}</string>
    </array>

    <!-- Fire at login, after the login Keychain is unlocked (replaces cron @reboot). -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Anchor hour ${anchor}, every ${interval}h. -->
    <key>StartCalendarInterval</key>
    <array>
PLIST_HEAD

  i=0
  while [ "${i}" -lt 24 ]; do
    h=$(( (anchor + i) % 24 ))
    printf '        <dict><key>Hour</key><integer>%s</integer><key>Minute</key><integer>0</integer></dict>\n' "${h}"
    i=$(( i + interval ))
  done

  cat <<PLIST_TAIL
    </array>

    <!-- The script logs to ~/claude_warmup.log itself; capture stray output too. -->
    <key>StandardOutPath</key>
    <string>${HOME}/claude_warmup.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/claude_warmup.launchd.log</string>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_TAIL
}

reload_agent() {
  local uid
  uid="$(id -u)"
  # Replace any previously loaded instance, then load the current plist.
  launchctl bootout "gui/${uid}/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/${uid}" "${PLIST}"
}

install_schedule() {
  local reconfigure="$1"
  local interval_override="$2"
  local anchor interval

  if [ "${reconfigure}" = "1" ] || ! anchor="$(read_anchor)"; then
    anchor="$(prompt_anchor)"
  else
    log "Using existing anchor hour ${anchor} (from ${CONFIG_FILE})."
  fi

  # Interval precedence: explicit --interval > persisted > default.
  if [ -n "${interval_override}" ]; then
    interval="${interval_override}"
  elif ! interval="$(read_interval)"; then
    interval="${DEFAULT_INTERVAL}"
  fi

  persist_config "${anchor}" "${interval}"
  log "Schedule: anchor hour ${anchor}, every ${interval}h (saved to ${CONFIG_FILE})."

  if [ ! -x "${WARMUP_SCRIPT}" ]; then
    chmod +x "${WARMUP_SCRIPT}" 2>/dev/null || true
  fi

  mkdir -p "${HOME}/Library/LaunchAgents"
  build_plist "${anchor}" "${interval}" > "${PLIST}"
  plutil -lint "${PLIST}" >/dev/null
  reload_agent
  log "Installed LaunchAgent ${LABEL}."
  log "Verify with: launchctl print gui/$(id -u)/${LABEL} | grep -E 'state|last exit'"
}

uninstall_schedule() {
  local uid
  uid="$(id -u)"
  launchctl bootout "gui/${uid}/${LABEL}" 2>/dev/null || true
  rm -f "${PLIST}"
  log "Removed LaunchAgent ${LABEL}."
}

main() {
  local action="install"
  local reconfigure="0"
  local interval_override=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --uninstall)   action="uninstall" ;;
      --reconfigure) reconfigure="1" ;;
      --interval)
        shift
        interval_override="${1:-}"
        if ! [[ "${interval_override}" =~ ^[0-9]+$ ]] || [ "${interval_override}" -lt 1 ] || [ "${interval_override}" -gt 24 ]; then
          log "Invalid --interval '${interval_override}'. Use an integer between 1 and 24."
          exit 2
        fi
        ;;
      --interval=*)
        interval_override="${1#*=}"
        if ! [[ "${interval_override}" =~ ^[0-9]+$ ]] || [ "${interval_override}" -lt 1 ] || [ "${interval_override}" -gt 24 ]; then
          log "Invalid --interval '${interval_override}'. Use an integer between 1 and 24."
          exit 2
        fi
        ;;
      -h|--help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) log "Unknown argument: $1"; exit 2 ;;
    esac
    shift
  done

  case "${action}" in
    install)   install_schedule "${reconfigure}" "${interval_override}" ;;
    uninstall) uninstall_schedule ;;
  esac
}

main "$@"
