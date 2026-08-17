#!/bin/bash
# install-drive-sync.sh — run the Drive sync on a schedule, via launchd.
#
# launchd, not Automator and not cron. Automator/Shortcuts would need a login item and a visible app;
# cron on macOS is deprecated and gets no wake-up handling. A LaunchAgent with StartInterval runs on
# login, survives sleep (it fires on wake if the interval elapsed), and needs no UI at all.
#
# Usage:
#   bash launchd/install-drive-sync.sh              every 30 minutes
#   bash launchd/install-drive-sync.sh 900          every 15 minutes
#   bash launchd/install-drive-sync.sh --uninstall

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LABEL="io.llinkas.meeting-notification-bar.drive-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  echo "==> removed $LABEL"
  exit 0
fi

INTERVAL="${1:-1800}"
case "$INTERVAL" in
  ''|*[!0-9]*) echo "interval must be whole seconds, got: $INTERVAL" >&2; exit 2 ;;
esac

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/meeting-notification-bar"
cat >"$PLIST_PATH" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO/launchd/run-drive-sync.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>MNB_HOME</key><string>$REPO</string></dict>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/meeting-notification-bar/drive-sync.launchd.log</string>
</dict>
</plist>
AGENT

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
echo "==> $LABEL installed, every ${INTERVAL}s ($PLIST_PATH)"
echo "==> log: ~/Library/Logs/meeting-notification-bar/drive-sync.log"
