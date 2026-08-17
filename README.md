# meeting-notification-bar

Two things, sharing one Google login, both running entirely on your Mac:

**A menu bar countdown to your next meeting.**

```
Standup · in 34m          upcoming (turns orange under 5 minutes)
▶ Standup · 12m left      in progress
No meetings               nothing left today
```

Click it for the rest of the day. Clicking a meeting opens its video call and closes the dropdown —
the whole row is the target, and rows with no call attached stay inert and show no hover highlight,
so the row tells you whether there is anything to open before you click.

**A one-way sync of Google Docs into local markdown files.** By default it mirrors Docs whose title
contains `Notes by Gemini` — Google's auto-generated meeting notes — into a folder you pick, one
`.md` file per Doc with frontmatter pointing back at the original. Point it at any folder: a plain
`~/Documents`, an Obsidian vault, a git repo. It writes files and knows nothing about what reads them.

## Nothing here runs on Claude, or on any model

Worth stating plainly, since that is the question this repo was extracted to answer.

The whole chain is `node` → Google's REST API → a JSON file → a Swift app reading that file. There is
no `claude` CLI call, no MCP server, no API key for any model provider, no inference of any kind, and
no hook or loop that could invoke one. The only outbound network requests are to `googleapis.com` and
`oauth2.googleapis.com`. All the arithmetic — countdowns, which meeting is current, day windows — is
local Swift and local JavaScript.

Nothing runs on a schedule you did not install, and the two things that can run on a schedule are
both `launchd` LaunchAgents you can list and remove:

```bash
launchctl list | grep meeting-notification-bar
```

Verify it rather than trust it:

```bash
grep -rin 'claude\|anthropic\|openai\|mcp' --include='*.js' --include='*.swift' --include='*.sh' .
```

The only hit is a comment in `bin/fetch-events.js` saying there is none.

Every host the code can reach is a literal in `lib/`: `oauth2.googleapis.com` and
`www.googleapis.com` (as `TOKEN_HOST` / `API_HOST`), plus `accounts.google.com` for the consent page
your browser opens and `127.0.0.1` for the loopback listener that catches the redirect. There is no
other `https.request` in the repo. (`build.sh` contains an `apple.com` URL — it is the DTD identifier
inside a plist, which is never fetched.)

"Gemini" does appear in the code, as the default Drive **title** to search for — `Notes by Gemini` is
what Google names the Docs it generates. This repo reads those Docs as files. It does not call Gemini,
and could not: the scope is `drive.readonly`.

## Requirements

- macOS 13 or newer.
- Node 18+. No `npm install` — **this repo has no dependencies**, no `package.json`, and no
  `node_modules`. Everything uses the Node standard library.
- Command Line Tools for `swiftc`: `xcode-select --install`. Full Xcode is not needed.
- A Google account, and ten minutes in the Cloud console once.

## Install

```bash
git clone https://github.com/llinkas13/meeting-notification-bar.git
cd meeting-notification-bar

# 1. the browser-clicks part — see docs/google-cloud-setup.md
mkdir -p .secrets
mv ~/Downloads/client_secret_*.json .secrets/oauth-client.json

# 2. everything else
bash setup.sh                 # menu bar only
bash setup.sh --with-sync     # menu bar + Drive sync every 30 minutes
```

`setup.sh` checks the toolchain, creates `config.json`, runs the OAuth consent, fetches events once,
builds the app, and installs the login agent. It is safe to re-run — it never overwrites
`config.json` and never re-asks for consent it already has. `bash setup.sh --check` verifies an
existing install and changes nothing.

If `.secrets/oauth-client.json` is missing, setup stops and points at
[docs/google-cloud-setup.md](docs/google-cloud-setup.md). That document is the six steps in the Cloud
console plus a table of what each failure message actually means.

## Configuration

`config.json`, copied from `config.example.json`. Every key is optional.

| Key | Default | Notes |
|---|---|---|
| `calendarId` | `primary` | Or a calendar's address, for a shared calendar. |
| `timezone` | *(auto)* | Empty means `$TZ`, then the system zone. See the warning below. |
| `driveSync.titleContains` | `Notes by Gemini` | Drive title substring to mirror. |
| `driveSync.outputDir` | `~/Documents/meeting-notes` | Where the markdown lands. |
| `driveSync.lookbackDays` | `30` | How far back the first run looks; a saved cursor takes over after. |
| `driveSync.exclude` | *(none)* | Case-insensitive regex on the title, e.g. `orientation|1:1|HR`. |

**The timezone is not optional even though every source for it is.** With no zone, the day window is
built in UTC, which in America/New_York runs from 8pm yesterday to 8pm today: evening meetings vanish
and yesterday's evening meetings appear, and nothing errors. `lib/config.js` resolves config → `$TZ`
→ `Intl`, and the third always works on macOS — which is why the key can be left blank, not why it
does not matter. `bin/auth.js --check` prints the zone actually in use.

## Daily use

Nothing. It starts at login and refreshes itself. When something looks wrong:

```bash
node bin/auth.js --check                    # is Google answering? prints no secrets
~/Applications/NextMeeting.app/Contents/MacOS/NextMeeting --print   # what the menu bar thinks
tail -20 ~/Library/Logs/meeting-notification-bar/menubar.log
```

`--print` is the one to reach for, because it separates "the data is wrong" from "the drawing is
wrong" — and unlike the menu bar it can be read from a terminal, which matters when a fullscreen
window is hiding the menu bar entirely:

```
menu bar:  ▶ ORGZ: Daily Standup · 19m left
source:    /Users/you/Library/Application Support/meeting-notification-bar/events.json
file age:  5s
events:    2 total, 2 timed
           10:00 AM–10:30 AM  ORGZ: Daily Standup  join:https://meet.google.com/…
           3:30 PM–4:30 PM   Monorepo Consolidation
```

Drive sync, by hand:

```bash
node bin/sync-drive-docs.js --dry-run       # list what would be pulled, write nothing
node bin/sync-drive-docs.js
node bin/sync-drive-docs.js --since 2026-07-01T00:00:00Z
node bin/sync-drive-docs.js --reset         # forget the cursor, re-examine everything
```

The sync **never overwrites an existing file** without `--force`. These are notes; you will edit
them, and a scheduled job that silently reverts your edits is worse than no sync at all. It is also
one-way by construction — the OAuth scope is `drive.readonly`, so it cannot write to Drive even by
mistake.

## How it fits together

| Piece | Job |
|---|---|
| `lib/google-auth.js` | OAuth loopback consent, token refresh, retry/backoff. No SDK. |
| `lib/calendar.js` | One `events.list` call; extracts a joinable URL. |
| `lib/drive.js` | `files.list` across all drives, paginated; Doc → markdown export. |
| `lib/config.js` | Defaults, and the timezone resolution above. |
| `bin/auth.js` | `--login` / `--check` / `--logout`. |
| `bin/fetch-events.js` | Today's events as JSON on stdout. The only thing on the menu bar path that touches the network. |
| `bin/sync-drive-docs.js` | Docs → `outputDir/*.md`, with a cursor and a seen list. |
| `menubar/NextMeeting.swift` | `NSStatusItem` + a hand-positioned SwiftUI panel. Reads JSON, never talks to Google. |
| `menubar/refresh-events.sh` | Runs the fetcher, writes the JSON atomically. |
| `menubar/build.sh` | `swiftc` → `.app` bundle. No Xcode project. |
| `launchd/` | The two LaunchAgents, and their PATH wrapper. |

Files, and why they live where they do:

```
<repo>/.secrets/                                        oauth-client.json, token.json (0600, gitignored)
<repo>/config.json                                      yours, gitignored
~/Library/Application Support/meeting-notification-bar/ events.json, drive-sync-state.json
~/Library/Logs/meeting-notification-bar/                menubar.log, drive-sync.log
```

Data and logs are kept apart on purpose, so `rm -rf` on the log directory cannot cost you the sync
cursor.

## Six things that will bite you if you edit this

1. **A GUI app cannot find `node`.** Launched from Finder or a LaunchAgent it inherits a minimal
   `PATH` with no mise/nvm/asdf shims. `menubar/refresh-events.sh` rebuilds a usable one. That is the
   entire reason the app shells out to a script instead of running `node` itself.
2. **The bundled script is a shim, not a copy.** It cannot find the checkout by walking up from
   `Contents/Resources` — two levels up is the bundle, not the repo. `build.sh` stamps the absolute
   path in as `MNB_HOME`. A side benefit: editing `refresh-events.sh` takes effect without rebuilding.
3. **Don't re-fetch in the 1-second timer.** The timer recomputes the *string*; events refresh at most
   every `REFRESH_INTERVAL` (300s), plus on wake from sleep. Fetching every second would be 3600 API
   calls an hour for data that changes twice a day.
4. **Keep the monospaced-digit font.** With the proportional system font the menu bar visibly reflows
   every time a digit changes width, which reads as a bug.
5. **The dropdown is a panel, not an `NSPopover`, and it will not dismiss itself.** A popover leaves a
   visible gap under the menu bar — it reserves room for its callout arrow, and no public API turns
   that off — so it is a borderless `NSPanel` positioned by hand. Two consequences: `canBecomeKey`
   must be overridden or the buttons inside go dead, and the global mouse monitor that closes it has
   to *skip* clicks on the status item, or it closes the panel and the button's own action immediately
   reopens it, and the menu bar item looks broken.
6. **`conferenceDataVersion=1` is not the fix for a missing join link.** It is a write-path parameter
   governing insert/update/patch; `events.list` ignores it. Verified against the live API — the
   response is byte-identical with and without it. An event with no `entryPoints` genuinely has no
   conferencing attached.

## Tests

```bash
node --test          # 11 checks, no network, no GUI
menubar/build/NextMeeting.app/Contents/MacOS/NextMeeting --selftest    # 20 checks, no network, no GUI
```

The Node suite covers the pure functions: join-URL precedence, timezone offsets, Drive query quoting,
filename generation and collision handling, and config defaults. The Swift `--selftest` covers
duration and title formatting, decoding a JSON file written before `joinUrl` existed, all-day events
excluded from the countdown, and `status()` picking the right event at five fixed clock times.

Neither suite talks to Google. The parts that do are three lines each and are exercised for real by
`node bin/auth.js --check`.

## Uninstall

```bash
bash uninstall.sh            # stop and remove the app and both LaunchAgents
bash uninstall.sh --purge    # also delete cached events, sync state, logs, and the token
```

Synced notes are never touched, at either level. They are your files. Revoke the Google grant at
<https://myaccount.google.com/permissions>.

## Known rough edges

- The countdown truncates rather than rounds: 19 minutes 59 seconds reads `19m left`.
- Only today. A meeting at 9am tomorrow shows as `No meetings` after today's last one ends.
- Multi-monitor: the panel opens on the screen holding the menu bar item and is clamped to that
  screen's visible frame.
- If you also run the `meeting-vault` version of this app, both install to
  `~/Applications/NextMeeting.app`. `build.sh --install` detects the other bundle identifier and
  refuses rather than clobbering it; remove one first.

## Licence

MIT. See [LICENSE](LICENSE).
