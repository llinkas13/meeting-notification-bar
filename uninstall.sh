#!/bin/bash
# uninstall.sh — remove everything this repo installed outside the checkout.
#
#   bash uninstall.sh              stop and remove the app + LaunchAgents
#   bash uninstall.sh --purge      also delete cached events, sync state, logs, and the OAuth token
#
# Notes it synced from Drive are NOT touched, at any level. They are your files.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="io.llinkas.meeting-notification-bar"
DATA="$HOME/Library/Application Support/meeting-notification-bar"
LOGS="$HOME/Library/Logs/meeting-notification-bar"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

for label in "$BUNDLE_ID.menubar" "$BUNDLE_ID.drive-sync"; do
  launchctl bootout "gui/$UID/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
  echo "==> removed LaunchAgent $label"
done

pkill -f "NextMeeting.app/Contents/MacOS/NextMeeting" 2>/dev/null || true
rm -rf "$HOME/Applications/NextMeeting.app"
echo "==> removed ~/Applications/NextMeeting.app"

if [ "$PURGE" = 1 ]; then
  rm -rf "$DATA" "$LOGS" "$REPO/.secrets/token.json"
  echo "==> purged cached events, sync state, logs, and the OAuth token"
  echo "    the OAuth client ($REPO/.secrets/oauth-client.json) is kept; delete it by hand if you want it gone"
  echo "    revoke the Google grant at https://myaccount.google.com/permissions"
else
  echo "==> kept $DATA, $LOGS, and .secrets/ — re-run uninstall.sh --purge to remove them"
fi

echo "==> synced notes were not touched"
