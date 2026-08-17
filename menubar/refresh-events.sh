#!/bin/bash
# refresh-events.sh — write today's calendar events where the menu bar app can read them.
#
# WHY THIS SCRIPT EXISTS AT ALL
# The app cannot run `node` itself. A GUI app launched from Finder or a LaunchAgent inherits a
# minimal PATH with no mise/nvm/asdf/volta shims, so `node` is simply not found — the app appears to
# work and every refresh silently fails. This wrapper rebuilds a usable PATH first.
#
# Output:  ~/Library/Application Support/meeting-notification-bar/events.json
#          or $MNB_EVENTS_FILE when set — must agree with whatever the app was launched with, or
#          this script writes one file while NextMeeting reads another.
# Log:     ~/Library/Logs/meeting-notification-bar/menubar.log   (rotated past ~256 KB)
#
# Written atomically (temp file + mv) so the app never reads a half-written JSON array. On failure
# the previous good file is left untouched — a stale countdown beats a blank menu bar.
#
# Usage:  bash menubar/refresh-events.sh
#         MNB_EVENTS_FILE=/tmp/fixture.json bash menubar/refresh-events.sh

set -uo pipefail

# MNB_HOME wins when set, because the copy of this script inside NextMeeting.app cannot find the
# checkout by walking up from its own location — two levels up from Contents/Resources is the bundle,
# not the repo. build.sh installs a shim that exports MNB_HOME and re-execs this file.
HOME_DIR="${MNB_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="$HOME/Library/Logs/meeting-notification-bar"
DATA_DIR="$HOME/Library/Application Support/meeting-notification-bar"
LOG="$LOG_DIR/menubar.log"
OUT="${MNB_EVENTS_FILE:-$DATA_DIR/events.json}"
TMP="$OUT.tmp.$$"

# PATH_BASE is the known-good order; PATH_EXTRA adds version managers that exist; the inherited PATH
# goes last so nothing already there is lost. Purely additive.
PATH_BASE="$HOME/.local/bin:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PATH_EXTRA=""
for d in "${NVM_DIR:-$HOME/.nvm}/current/bin" "${ASDF_DATA_DIR:-$HOME/.asdf}/shims" "$HOME/.asdf/shims" "${VOLTA_HOME:-$HOME/.volta}/bin"; do
  [ -d "$d" ] && case ":$PATH_BASE$PATH_EXTRA:" in
    *":$d:"*) ;;
    *) PATH_EXTRA="$PATH_EXTRA:$d" ;;
  esac
done
export PATH="$PATH_BASE$PATH_EXTRA${PATH:+:$PATH}"

mkdir -p "$LOG_DIR" "$DATA_DIR" "$(dirname "$OUT")"
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" | tr -d ' ')" -gt 262144 ]; then
  mv -f "$LOG" "$LOG.1"
fi
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >>"$LOG"; }

trap 'rm -f "$TMP"' EXIT

command -v node >/dev/null 2>&1 || { log "FAIL node not found on PATH ($PATH)"; exit 1; }

export MNB_HOME="$HOME_DIR"

if node "$HOME_DIR/bin/fetch-events.js" >"$TMP" 2>>"$LOG"; then
  # Guard against a successful exit that wrote nothing usable — an empty file would make the app
  # show "No meetings" when the truth is "the fetch broke".
  if [ -s "$TMP" ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$TMP" 2>>"$LOG"; then
    mv -f "$TMP" "$OUT"
    COUNT=$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length))' "$OUT" 2>/dev/null || echo '?')
    log "ok -> $OUT ($COUNT events)"
    exit 0
  fi
  log "FAIL fetcher exited 0 but output was empty or not JSON; keeping previous $OUT"
  exit 1
fi

log "FAIL bin/fetch-events.js nonzero (re-auth? node bin/auth.js --check); keeping previous $OUT"
exit 1
