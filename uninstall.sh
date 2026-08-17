#!/bin/bash
# uninstall.sh — remove everything this repo installed outside the checkout.
#
#   bash uninstall.sh              stop and remove the app + LaunchAgents
#   bash uninstall.sh --purge      also delete cached events, sync state, logs, and the OAuth token
#   bash uninstall.sh --dry-run    print what would be removed, change nothing
#   bash uninstall.sh --purge --dry-run   rehearse a purge; --dry-run wins in any order
#   bash uninstall.sh --help       print usage and exit without touching anything
#
# Notes it synced from Drive are NOT touched, at any level. They are your files.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="io.llinkas.meeting-notification-bar"
DATA="$HOME/Library/Application Support/meeting-notification-bar"
LOGS="$HOME/Library/Logs/meeting-notification-bar"

# Prints the header comment above, rather than a second copy of it. The copy this replaced had
# already drifted inside a single sitting — the header listed --help and the copy did not. Reading
# the file's own header by shape (everything after the shebang up to the first non-comment line)
# means the usage text cannot disagree with the documentation directly above it, and cannot
# truncate when someone adds a line.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^#[ ]?/, ""); print; next } NR > 1 { exit }' "$0"
}

# Parse arguments BEFORE doing anything destructive, and reject what we do not recognise.
#
# This block used to be `[ "${1:-}" = "--purge" ] && PURGE=1`, with no validation and no help text.
# Every other argument — including `--help` — fell through to the removal code below and performed a
# real uninstall. That is exactly backwards: the cautious instinct (ask it what it does before
# running it) was the one that destroyed things, and it cost a live install during testing.
#
# Every argument is inspected, not just $1. The earlier version read `$1` alone and rejected a
# second argument outright, which was safe but unhelpful: `--purge --dry-run` is the natural way to
# ask "show me what purging would do" — you name the action, then qualify it — and being told "too
# many arguments" invites dropping the qualifier rather than reordering it. Now the combination
# works, and --dry-run wins wherever it appears, so the safety flag can never be the one silently
# discarded.
PURGE=0
DRY=0
for a in "$@"; do
  case "$a" in
    --purge)   PURGE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "unknown flag: $a" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

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
  if [ "$DRY" = 1 ]; then
    echo "==> would purge cached events, sync state, logs, and the OAuth token"
  else
    echo "==> purged cached events, sync state, logs, and the OAuth token"
  fi
  echo "    the OAuth client ($REPO/.secrets/oauth-client.json) is kept; delete it by hand if you want it gone"
  echo "    revoke the Google grant at https://myaccount.google.com/permissions"
else
  echo "==> kept $DATA, $LOGS, and .secrets/ — re-run uninstall.sh --purge to remove them"
fi

echo "==> synced notes were not touched"
