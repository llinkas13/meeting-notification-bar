#!/bin/bash
# run-drive-sync.sh — the wrapper launchd calls. Same PATH problem, same fix as
# menubar/refresh-events.sh: a launchd job gets a minimal PATH and cannot find `node` on its own.
#
# Log: ~/Library/Logs/meeting-notification-bar/drive-sync.log  (rotated past ~256 KB)
#
# Usage:  bash launchd/run-drive-sync.sh [--dry-run ...]   (extra flags pass through)

set -uo pipefail

HOME_DIR="${MNB_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="$HOME/Library/Logs/meeting-notification-bar"
LOG="$LOG_DIR/drive-sync.log"

PATH_BASE="$HOME/.local/bin:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PATH_EXTRA=""
for d in "${NVM_DIR:-$HOME/.nvm}/current/bin" "${ASDF_DATA_DIR:-$HOME/.asdf}/shims" "$HOME/.asdf/shims" "${VOLTA_HOME:-$HOME/.volta}/bin"; do
  [ -d "$d" ] && case ":$PATH_BASE$PATH_EXTRA:" in
    *":$d:"*) ;;
    *) PATH_EXTRA="$PATH_EXTRA:$d" ;;
  esac
done
export PATH="$PATH_BASE$PATH_EXTRA${PATH:+:$PATH}"
export MNB_HOME="$HOME_DIR"

mkdir -p "$LOG_DIR"
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" | tr -d ' ')" -gt 262144 ]; then
  mv -f "$LOG" "$LOG.1"
fi

run() {
  printf '\n===== %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  command -v node >/dev/null 2>&1 || { echo "FAIL node not found on PATH ($PATH)"; exit 1; }
  # Argument validation lives in sync-drive-docs.js, which rejects unknown flags and exits 2. This
  # wrapper deliberately does not second-guess it — one parser, not two that can disagree.
  node "$HOME_DIR/bin/sync-drive-docs.js" "$@"
}

# Everything used to go to the log unconditionally, so running this by hand printed nothing at all:
# --help wrote its usage into a file the reader had not been told about. When stderr is a terminal,
# show the output as well as recording it. launchd gets no terminal, so scheduled runs are unchanged.
# pipefail is already set, so tee cannot mask a nonzero exit from node.
if [ -t 2 ]; then
  run "$@" 2>&1 | tee -a "$LOG"
else
  run "$@" >>"$LOG" 2>&1
fi
