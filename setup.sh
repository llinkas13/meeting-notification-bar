#!/bin/bash
# setup.sh — take a fresh clone to a working menu bar countdown, in one command.
#
#   bash setup.sh                 the menu bar only
#   bash setup.sh --with-sync     also install the Drive → local markdown sync on a 30-min schedule
#   bash setup.sh --check         verify an existing install; change nothing
#
# It is safe to re-run. Every step is idempotent: config.json is never overwritten, consent is
# skipped if a token already exists, and the app is rebuilt in place.
#
# The one thing this cannot do for you is create the Google Cloud OAuth client — that needs clicks in
# a browser. If .secrets/oauth-client.json is missing, setup stops and points at
# docs/google-cloud-setup.md, which is six steps long.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

WITH_SYNC=0
CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --with-sync) WITH_SYNC=1 ;;
    --check)     CHECK_ONLY=1 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '  \033[31mstop\033[0m  %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
step "1. Checking what this machine has"
# ---------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "this is macOS-only: it builds an NSStatusItem app and installs a LaunchAgent"
ok "macOS $(sw_vers -productVersion)"

command -v node >/dev/null || die "node not found. Install Node 18 or newer (brew install node, or mise/nvm)"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "node $(node -v) is too old; 18+ needed for the fetch/URL APIs used here"
ok "node $(node -v) — no npm install needed, this repo has no dependencies"

command -v swiftc >/dev/null || die "swiftc not found. Run: xcode-select --install  (Command Line Tools, not full Xcode)"
ok "swiftc present"

# ---------------------------------------------------------------------------
step "2. Config"
# ---------------------------------------------------------------------------

if [ -f config.json ]; then
  node -e 'JSON.parse(require("fs").readFileSync("config.json","utf8"))' \
    || die "config.json exists but is not valid JSON"
  ok "config.json (left alone)"
else
  if [ "$CHECK_ONLY" = 1 ]; then
    warn "no config.json — defaults would be used"
  else
    cp config.example.json config.json
    ok "config.json created from config.example.json"
  fi
fi
TZ_IN_USE="$(node -e 'process.stdout.write(require("./lib/config").load().timezone || "")')"
[ -n "$TZ_IN_USE" ] && ok "timezone: $TZ_IN_USE" || warn "no timezone resolved — the day window will be UTC and may show the wrong day"

# ---------------------------------------------------------------------------
step "3. Google credentials"
# ---------------------------------------------------------------------------

if [ ! -f .secrets/oauth-client.json ] && [ "$CHECK_ONLY" = 1 ]; then
  # --check reports, it never halts: the point is to see every step's state in one pass.
  warn "no .secrets/oauth-client.json — see docs/google-cloud-setup.md"
elif [ ! -f .secrets/oauth-client.json ]; then
  cat >&2 <<'MSG'
  stop  no .secrets/oauth-client.json

        This is the browser-clicks part, and it is the only part of setup that is not scripted.
        Follow docs/google-cloud-setup.md — create a project, enable the Calendar and Drive APIs,
        create an OAuth client of type "Desktop app", download the JSON, then:

            mkdir -p .secrets && mv ~/Downloads/client_secret_*.json .secrets/oauth-client.json
            bash setup.sh

MSG
  exit 1
else
  chmod 700 .secrets; chmod 600 .secrets/oauth-client.json
  ok ".secrets/oauth-client.json (0600)"
fi

if [ -f .secrets/token.json ]; then
  ok "already authorized (token cached)"
elif [ "$CHECK_ONLY" = 1 ]; then
  warn "not authorized yet — run: node bin/auth.js --login"
else
  echo "  opening the Google consent page — approve read-only Calendar + Drive"
  node bin/auth.js --login
fi

# A live probe, not just a file check: an expired grant or a revoked app both leave the token file
# sitting there looking fine.
if [ -f .secrets/token.json ]; then
  node bin/auth.js --check >/dev/null 2>&1 \
    && ok "Google API reachable with the cached token" \
    || warn "the cached token did not work — see: node bin/auth.js --check"
fi

# ---------------------------------------------------------------------------
step "4. First event fetch"
# ---------------------------------------------------------------------------

if [ "$CHECK_ONLY" = 1 ]; then
  EVENTS="$HOME/Library/Application Support/meeting-notification-bar/events.json"
  if [ -f "$EVENTS" ]; then
    ok "events.json exists ($(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length))' "$EVENTS" 2>/dev/null || echo '?') events)"
  else
    warn "no events.json yet"
  fi
else
  bash menubar/refresh-events.sh \
    && ok "events written to ~/Library/Application Support/meeting-notification-bar/events.json" \
    || warn "refresh failed — see ~/Library/Logs/meeting-notification-bar/menubar.log"
fi

# ---------------------------------------------------------------------------
step "5. Menu bar app"
# ---------------------------------------------------------------------------

if [ "$CHECK_ONLY" = 1 ]; then
  pgrep -f "NextMeeting.app/Contents/MacOS/NextMeeting" >/dev/null \
    && ok "NextMeeting is running (pid $(pgrep -f 'NextMeeting.app/Contents/MacOS/NextMeeting' | head -1))" \
    || warn "NextMeeting is not running — run: bash menubar/build.sh --install"
else
  bash menubar/build.sh --install
  ok "installed to ~/Applications and set to start at login"
fi

# ---------------------------------------------------------------------------
if [ "$WITH_SYNC" = 1 ]; then
  step "6. Drive → local markdown sync"
  node bin/sync-drive-docs.js --dry-run || warn "the dry run failed; the schedule is still being installed"
  bash launchd/install-drive-sync.sh 1800
  ok "syncing every 30 minutes into $(node -e 'process.stdout.write(require("./lib/config").load().driveSync.outputDir)')"
fi

step "Done"
cat <<'MSG'
  The countdown is at the right end of your menu bar. Click it for the rest of the day; click a
  meeting to open its video call.

  If it says "Calendar —", nothing has been fetched yet:
      node bin/auth.js --check
      tail -20 ~/Library/Logs/meeting-notification-bar/menubar.log

  To see what the menu bar thinks, from a terminal:
      ~/Applications/NextMeeting.app/Contents/MacOS/NextMeeting --print
MSG
