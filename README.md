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

# 1. Make your OWN Google Cloud OAuth client first — docs/google-cloud-setup.md, ~10 min of
#    clicking. You create it under your own Google account; nobody can hand you one. Only after
#    you have downloaded its JSON will the two lines below have anything to move.
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
| `calendarId` | `primary` | Or a calendar's address, for a shared calendar. No second consent needed — your existing token covers any calendar your Google account can already read. |
| `driveSync.titleContains` | `Notes by Gemini` | Drive title substring to mirror. |
| `driveSync.outputDir` | `~/Documents/meeting-notes` | Where the markdown lands. |
| `driveSync.lookbackDays` | `30` | How far back the first run looks; a saved cursor takes over after. |
| `driveSync.maxPerRun` | `60` | Ceiling on Docs exported per run, so a first sync of a large Drive cannot run away. |
| `driveSync.exclude` | *(none)* | Case-insensitive regex on the title, e.g. `orientation|1:1|HR`. |

**The timezone always follows the Mac — there is no config key for it.** `lib/config.js` resolves
`$TZ`, falling back to whatever `Intl` reports as the system zone, and the fallback always works on
macOS. This is deliberate, not a missing feature: a timezone pinned in config.json can silently drift
from the laptop's actual zone, which is exactly the wrong-day bug this used to warn about. Both the
day's date and the UTC offset for the day window are computed from this same resolved zone, so they
can never disagree. `bin/auth.js --check` prints the zone actually in use.

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
freshness: Updated 9:41 AM
events:    2 total, 2 timed
           10:00 AM–10:30 AM  ORGZ: Daily Standup  join:https://meet.google.com/…
           3:30 PM–4:30 PM   Monorepo Consolidation
```

### Telling "working" from "frozen"

When a fetch fails, the app keeps the last good data rather than blanking — a stale countdown is
more useful than an empty one. The cost is that a broken install and a working one draw *exactly the
same thing*. This is the failure mode to understand, because it is the one you will actually hit:
the 7-day token expiry on a `@gmail.com` account arrives with no bang.

Three places say so plainly:

- **The menu bar itself.** A `⚠` is appended to the countdown when the data behind it is more than
  ten minutes old or the last fetch failed. `Standup · in 34m` is live; `Standup · in 34m ⚠` is a
  photograph.

- **The dropdown footer.** `Updated 9:41 AM` in grey means that data was fetched at 9:41. If it
  turns orange and reads `Stale · 9:41 AM` or `Fetch failed · 9:41 AM`, the countdown above it is a
  museum piece. The timestamp comes from the events file's modification time, so it cannot advance
  unless a fetch genuinely succeeded — clicking Refresh on a broken install will not move it.
- **`--print`'s `freshness:` line**, which says the same thing from a terminal and appends
  `<-- STALE: the fetch is failing; see menubar.log` when it applies.

If it is stale, `tail -20 ~/Library/Logs/meeting-notification-bar/menubar.log` names the reason.
`not authorized yet` means re-run `node bin/auth.js --login`. Check the `*.launchd.log` files in the
same directory too — they catch failures that happen before the script's own logging starts, which
is what an empty `menubar.log` actually means.

**Read the log's rate, not just its contents.** A broken fetch retries on a backoff ladder — 15s,
then 60s, then every 5 minutes — so a sustained outage should write roughly one `FAIL` line every
five minutes, and a handful in the first minute. Much faster than that means the *backoff* is
broken, not the fetch:

```bash
grep -c FAIL ~/Library/Logs/meeting-notification-bar/menubar.log
awk '{print $2}' ~/Library/Logs/meeting-notification-bar/menubar.log | cut -c1-5 | uniq -c | tail
```

The second command counts lines per minute. Anything in the tens is the bug this ladder was added
to kill: the app once re-ran the fetch script every second for as long as fetching stayed broken,
because a failed fetch never updates the file it was checking the age of. 714 failures in one
afternoon, and nothing about any individual line looked wrong — only the rate did.

**If you moved or renamed the folder you cloned into**, expect `not authorized yet` even though your
token is right there. The bundle stamps the checkout's absolute path in at build time, so it is now
looking somewhere that no longer exists. Confirm with
`cat ~/Applications/NextMeeting.app/Contents/Resources/refresh-events.sh` and rebuild from the new
location. `setup.sh --check` compares that stamped path against the checkout you are standing in and
warns when they disagree.

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
| `launchd/` | The **drive-sync** LaunchAgent installer and its PATH wrapper. The menu bar's LaunchAgent is written by `menubar/build.sh --install`, not from here. |

Files, and why they live where they do:

```
<repo>/.secrets/                                        oauth-client.json, token.json (0600, gitignored)
<repo>/config.json                                      yours, gitignored
~/Library/Application Support/meeting-notification-bar/ events.json, drive-sync-state.json
~/Library/Logs/meeting-notification-bar/                menubar.log, drive-sync.log
                                                        …and *.launchd.log — launchd's own stderr,
                                                        which catches failures that happen before
                                                        the scripts' logging starts. Check these
                                                        when a log looks suspiciously empty.
```

Data and logs are kept apart on purpose, so `rm -rf` on the log directory cannot cost you the sync
cursor.

`events.json`'s path can be overridden with `$MNB_EVENTS_FILE` — set it before running the menu bar
app *and* before running `menubar/refresh-events.sh` (or export it for both, e.g. in the LaunchAgent
plist), since the app reads whatever path it resolves to and the script writes whatever path it
resolves to; if only one side sees the variable they end up pointing at two different files. This is
what lets a fixture drive the display for testing, or another system write the JSON without forking
the app. `lib/paths.js`'s `EVENTS_FILE` honours the same variable, for anything on the Node side that
needs to agree on the location (`bin/fetch-events.js` itself does not — it only ever writes to
stdout).

The other two overrides, for completeness: `$MNB_HOME` points the Node side at a different checkout
(`build.sh` stamps it into the bundle, since a GUI app cannot find the checkout by walking up from
inside its own `.app`), and `$MNB_CONFIG` points at a different `config.json` — which is how the test
suite reads fixture config on a machine that may have no `config.json` at all.

## Things that will bite you if you edit this

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
7. **Esc only works because the app activates itself.** The key monitor is a *local*
   `NSEvent.addLocalMonitorForEvents`, which only sees events delivered to this app — and an
   `.accessory` app is never active on its own, so without `NSApp.activate(ignoringOtherApps:)` in
   `openPanel()` the monitor is installed but can never fire. `closePanel()` calls
   `NSApp.deactivate()` on the way out, since nothing else returns focus to whatever app the user was
   in before. Activation is asynchronous and can itself surface a resign-active notification in the
   same beat (see point 8); `openPanel()` sets a short grace window (`suppressResignUntil`) so that
   doesn't slam the panel shut the instant it opens.
8. **The panel closes itself on more than a stray click now.** `didResignActiveNotification` and
   `NSWorkspace.activeSpaceDidChangeNotification` both call `closePanel()`, so a keyboard-only
   cmd-tab or a Space change no longer leaves a frozen panel floating over the wrong app on every
   Space — a transient `NSPopover` used to get this for free. If you add a new way to leave the app
   (another notification, a global monitor), route it through `closePanel()` too rather than
   inventing a second dismissal path.
9. **`closePanel()` defers releasing the content view.** It can be called synchronously from inside
   the SwiftUI row's own `onOpen` action, while AppKit is still dispatching that mouse-up through the
   `NSHostingView` being torn down — nil-ing `panel.contentView` immediately would be a
   use-after-free risk. The teardown happens on the next run-loop turn instead, guarded by a
   generation counter (`panelGeneration`) so a fast close-then-reopen doesn't wipe out the *new*
   content view when the deferred block finally runs.
10. **The Mac's timezone can change without a sleep.** `NSSystemTimeZoneDidChange` triggers the same
    refresh-and-re-render path as wake-from-sleep, and also calls `NSTimeZone.resetSystemTimeZone()`
    first — Foundation caches the system zone, and `Calendar.current` / the implicit-zone
    `DateFormatter`s in this file (`clockTime`, `needsRefresh`) would otherwise keep answering with
    the old zone. Nothing here stores a `Calendar` or `DateFormatter` across calls, so that reset is
    the only stale-cache concern.
11. **The dropdown's height is clamped, and the rows scroll, on purpose.** `openPanel()` used to hand
    `host.fittingSize` straight to the panel; on a busy day (roughly a dozen-plus meetings) that grows
    past the top of the screen, and because the panel draws at `.popUpMenu` level it then covers the
    *earliest* meetings with the menu bar instead of just running off the bottom. `clampedPanelHeight`
    (pure, tested in `--selftest` since `--print` has no window to measure a real screen from) caps
    the height to what actually fits below the menu bar; `DayView`'s `ScrollView` around the rows
    (`.frame(maxHeight: .infinity)`) is what lets the *rows* absorb that squeeze while "Today", the
    divider, and the Refresh/Quit footer keep their natural size and stay reachable. If you remove the
    `ScrollView`, the panel goes back to hiding the day's first meetings on a busy calendar.

## Tests

```bash
node --test          # 15 checks, no network, no GUI
menubar/build/NextMeeting.app/Contents/MacOS/NextMeeting --selftest    # 43 checks, no network, no GUI
```

The Node suite covers the pure functions: join-URL precedence, timezone offsets, Drive query quoting,
filename generation and collision handling, and config defaults. The Swift `--selftest` covers
duration and title formatting, decoding a JSON file written before `joinUrl` existed, all-day events
excluded from the countdown, `status()` picking the right event at five fixed clock times, and the
dropdown's height-clamp math (`clampedPanelHeight`) against three fixed screen geometries.

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

- The countdown rounds seconds *up* before converting to minutes, so it never reads `0m` while a
  meeting is still ahead of you. 19 minutes 59 seconds reads `19m left`; 40 seconds reads `1m left`.
- Only today. A meeting at 9am tomorrow shows as `No meetings` after today's last one ends.
- Multi-monitor: the panel opens on the screen holding the menu bar item and is clamped to that
  screen's visible frame.
- If you also run the `meeting-vault` version of this app, both install to
  `~/Applications/NextMeeting.app`. `build.sh --install` detects the other bundle identifier and
  refuses rather than clobbering it; remove one first.

## Licence

MIT. See [LICENSE](LICENSE).
