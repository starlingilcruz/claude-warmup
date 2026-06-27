#!/usr/bin/env bash
#
# install-cron.sh — install/uninstall the Claude warmup cron schedule
#                   (macOS / Linux).
#
# On first run it prompts for an anchor hour (0-23), persists it, and reuses
# it on later runs. It registers crontab entries that run the warmup script:
#   - at boot (@reboot), and
#   - every N hours from the anchor (default N=2: H, H+2, H+4, ... mod 24).
#
# The entries live inside a tagged marker block, so re-running is idempotent
# (the block is replaced, never duplicated).
#
# Usage:
#   ./install-cron.sh                 # install (prompt for hour on first run)
#   ./install-cron.sh --interval N    # set the interval in hours (default 2)
#   ./install-cron.sh --reconfigure   # re-prompt for the anchor hour
#   ./install-cron.sh --uninstall     # remove the warmup cron block
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARMUP_SCRIPT="${SCRIPT_DIR}/../bin/claude-warmup.sh"
WARMUP_SCRIPT="$(cd "$(dirname "${WARMUP_SCRIPT}")" && pwd)/$(basename "${WARMUP_SCRIPT}")"

CONFIG_DIR="${HOME}/.config/claude-warmup"
CONFIG_FILE="${CONFIG_DIR}/config"
MARKER_BEGIN="# >>> claude-warmup >>>"
MARKER_END="# <<< claude-warmup <<<"
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

current_crontab() {
  # Print current crontab, or nothing if none is installed.
  crontab -l 2>/dev/null || true
}

strip_block() {
  # Remove our marker block from stdin.
  awk -v b="${MARKER_BEGIN}" -v e="${MARKER_END}" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip!=1 {print}
  '
}

build_block() {
  local anchor="$1"
  local interval="$2"
  local hours h i
  # Compute the interval-spaced trigger hours within one 24h day, anchored at H.
  hours=""
  i=0
  while [ "${i}" -lt 24 ]; do
    h=$(( (anchor + i) % 24 ))
    hours="${hours}${hours:+,}${h}"
    i=$(( i + interval ))
  done

  printf '%s\n' "${MARKER_BEGIN}"
  printf '%s\n' "# Managed by claude-warmup install-cron.sh — do not edit by hand."
  printf '%s\n' "# Anchor hour: ${anchor}; runs every ${interval}h plus at boot."
  printf '@reboot %s >/dev/null 2>&1\n' "${WARMUP_SCRIPT}"
  printf '0 %s * * * %s >/dev/null 2>&1\n' "${hours}" "${WARMUP_SCRIPT}"
  printf '%s\n' "${MARKER_END}"
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

  local new_crontab
  new_crontab="$(current_crontab | strip_block)"
  new_crontab="${new_crontab}
$(build_block "${anchor}" "${interval}")"

  printf '%s\n' "${new_crontab}" | crontab -
  log "Installed warmup cron schedule. Verify with: crontab -l"
}

uninstall_schedule() {
  local cleaned
  cleaned="$(current_crontab | strip_block)"
  if [ -z "${cleaned//[$'\n\t ']/}" ]; then
    crontab -r 2>/dev/null || true
  else
    printf '%s\n' "${cleaned}" | crontab -
  fi
  log "Removed warmup cron block."
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
