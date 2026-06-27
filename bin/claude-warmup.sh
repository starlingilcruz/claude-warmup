#!/usr/bin/env bash
#
# claude-warmup.sh — keep the Claude CLI floating quota window warm.
#
# Makes a single ultra-lightweight, silent call to the Claude CLI with a
# prompt that forces a one-character answer (so both input and output tokens
# stay minimal), appends a timestamped result to ~/claude_warmup.log, and
# raises a native desktop notification (macOS osascript / Linux notify-send)
# if the call fails.
#
# Designed to be run NON-INTERACTIVELY by cron (including @reboot), so it
# explicitly bootstraps PATH/environment to locate the `claude` executable.
#
# Usage:
#   ./claude-warmup.sh
#
# Exit codes:
#   0  warmup succeeded
#   1  warmup failed (claude returned non-zero or was not found)
#
# Logs to: $HOME/claude_warmup.log
#
set -u

LOG_FILE="${HOME}/claude_warmup.log"

# Minimal-token warmup prompt: constrains the model to a single-digit reply so
# the output token count stays at ~1.
WARMUP_PROMPT="Reply with only the digit 1 and nothing else."

# --- Environment bootstrap -------------------------------------------------
# Schedulers launch us with a minimal, non-login environment, so `claude`
# is frequently NOT on PATH. Prepend the common install locations and source
# version-manager / profile shims when present.

# Ensure user identity is set: on macOS the Claude CLI reads its credentials
# from the login Keychain, and that lookup needs USER/LOGNAME (which a bare
# scheduler environment may omit). Without these, claude reports "Not logged in".
export USER="${USER:-$(id -un 2>/dev/null)}"
export LOGNAME="${LOGNAME:-${USER}}"

prepend_path() {
  case ":${PATH}:" in
    *":$1:"*) : ;;          # already present
    *) [ -d "$1" ] && PATH="$1:${PATH}" ;;
  esac
}

prepend_path "/opt/homebrew/bin"          # Apple Silicon Homebrew
prepend_path "/usr/local/bin"             # Intel Homebrew / common installs
prepend_path "${HOME}/.local/bin"         # pipx / local installs
prepend_path "${HOME}/.npm-global/bin"    # npm global prefix
prepend_path "${HOME}/.volta/bin"         # Volta

# nvm: source it so the default node (and npm-global claude) is on PATH.
export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
if [ -s "${NVM_DIR}/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "${NVM_DIR}/nvm.sh" >/dev/null 2>&1 || true
fi

# Login profiles, in case the user installed claude via a custom path.
# Source each in an isolated subshell and import only the resulting PATH, so
# a profile that calls `exit`, hangs, or prints output can't break this run.
for profile in "${HOME}/.profile" "${HOME}/.bash_profile" "${HOME}/.zprofile"; do
  if [ -r "${profile}" ]; then
    extracted_path="$(. "${profile}" >/dev/null 2>&1; printf '%s' "${PATH}")"
    [ -n "${extracted_path}" ] && PATH="${extracted_path}"
  fi
done

export PATH

# --- Helpers ---------------------------------------------------------------

timestamp() { date "+%Y-%m-%d %H:%M:%S %z"; }

log_line() {
  # Append a single line to the log, creating the file if needed.
  printf '%s\n' "$1" >> "${LOG_FILE}"
}

notify_failure() {
  # Best-effort native desktop notification. Never let a missing notifier
  # crash the script.
  local title="Claude warmup failed"
  local message="$1"
  local os
  os="$(uname -s)"

  case "${os}" in
    Darwin)
      if command -v osascript >/dev/null 2>&1; then
        # Escape double quotes for AppleScript.
        local safe_msg=${message//\"/\\\"}
        osascript -e "display notification \"${safe_msg}\" with title \"${title}\"" >/dev/null 2>&1 || true
      fi
      ;;
    Linux)
      if command -v notify-send >/dev/null 2>&1; then
        notify-send --urgency=critical "${title}" "${message}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# --- Warmup call -----------------------------------------------------------

# Resolve the claude executable.
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"

if [ -z "${CLAUDE_BIN}" ]; then
  msg="claude executable not found on PATH (PATH=${PATH})"
  log_line "[$(timestamp)] FAILURE exit=127 :: ${msg}"
  notify_failure "claude not found on PATH. See ${LOG_FILE}."
  exit 1
fi

# Run the minimal-token call, capturing combined stdout+stderr and exit code.
output="$("${CLAUDE_BIN}" -p "${WARMUP_PROMPT}" 2>&1)"
status=$?

if [ "${status}" -eq 0 ]; then
  log_line "[$(timestamp)] SUCCESS exit=0"
  exit 0
else
  # Collapse newlines so the raw output stays on the log entry's lines but is
  # still fully preserved.
  log_line "[$(timestamp)] FAILURE exit=${status} :: ${output}"
  # Keep the notification short; point the user at the full log.
  short="$(printf '%s' "${output}" | head -c 200)"
  notify_failure "exit=${status}: ${short} (see ${LOG_FILE})"
  exit 1
fi
