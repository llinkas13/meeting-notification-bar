#!/bin/bash
# uninstall.sh — remove everything this repo installed outside the checkout.
#
#   bash uninstall.sh              stop and remove the app + LaunchAgents
#   bash uninstall.sh --purge      also delete cached events, sync state, logs, and the OAuth token
#   bash uninstall.sh --dry-run    print what would be removed, change nothing
#   bash uninstall.sh --help       print usage and exit without touching anything
#
# Notes it synced from Drive are NOT touched, at any level. They are your files.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="io.llinkas.meeting-notification-bar"
DATA="$HOME/Library/Application Support/meeting-notification-bar"
LOGS="$HOME/Library/Logs/meeting-notification-bar"

usage() {
  cat <<'USAGE'
uninstall.sh — remove everything this repo installed outside the checkout.

  bash uninstall.sh              stop and remove the app + LaunchAgents
  bash uninstall.sh --purge      also delete cached events, sync state, logs, and the OAuth token
  bash uninstall.sh --dry-run    print what would be removed, change nothing

Notes synced from Drive are never touched, at any level. They are your files.
USAGE
}

# Parse arguments BEFORE doing anything destructive, and reject what we do not recognise.
#
# This block used to be `[ "${1:-}" = "--purge" ] && PURGE=1`, with no validation and no help text.
# Every other argument — including `--help` — fell through to the removal code below and performed a
# real uninstall. That is exactly backwards: the cautious instinct (ask it what it does before
# running it) was the one that destroyed things, and it cost a live install during testing.
PURGE=0
DRY=0
case "${1:-}" in
  --purge)   PURGE=1 ;;
  --dry-run) DRY=1 ;;
  -h|--help) usage; exit 0 ;;
  "")        ;;
  *)         echo "unknown flag: $1" >&2; echo >&2; usage >&2; exit 2 ;;
esac
[ $# -gt 1 ] && { echo "too many arguments" >&2; usage >&2; exit 2; }

run() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

# Say "would remove" during a dry run. Announcing "removed" about something still on disk is the
# same class of lie as a footer that says "Updated" about a fetch that failed.
did() { if [ "$DRY" = 1 ]; then echo "==> would remove $*"; else echo "==> removed $*"; fi; }

for label in "$BUNDLE_ID.menubar" "$BUNDLE_ID.drive-sync"; do
  PLIST="$HOME/Library/LaunchAgents/$label.plist"
  # Only claim to have removed things that were actually there — the old version announced
  # "removed LaunchAgent" for agents that had never been installed.
  if launchctl print "gui/$UID/$label" >/dev/null 2>&1 || [ -f "$PLIST" ]; then
    run launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    run rm -f "$PLIST"
    did "LaunchAgent $label"
  fi
done

if pgrep -f "NextMeeting.app/Contents/MacOS/NextMeeting" >/dev/null 2>&1; then
  run pkill -f "NextMeeting.app/Contents/MacOS/NextMeeting" || true
fi
if [ -d "$HOME/Applications/NextMeeting.app" ]; then
  run rm -rf "$HOME/Applications/NextMeeting.app"
  did "~/Applications/NextMeeting.app"
fi

if [ "$PURGE" = 1 ]; then
  run rm -rf "$DATA" "$LOGS" "$REPO/.secrets/token.json"
  echo "==> purged cached events, sync state, logs, and the OAuth token"
  echo "    the OAuth client ($REPO/.secrets/oauth-client.json) is kept; delete it by hand if you want it gone"
  echo "    revoke the Google grant at https://myaccount.google.com/permissions"
else
  echo "==> kept $DATA, $LOGS, and .secrets/ — re-run uninstall.sh --purge to remove them"
fi

echo "==> synced notes were not touched"
