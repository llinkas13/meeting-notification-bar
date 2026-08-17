# meeting-notification-bar — rules for agents

**Installing this for the first time? Read `SETUP.md` first.** It is the install handoff and names
the two steps you cannot do yourself. This file is the standing rules; that file is the procedure.

## What this is

A macOS menu bar countdown to your next meeting, plus an optional one-way Google Docs → markdown
mirror. Pure Node standard library and one Swift file — no npm dependencies, no `package.json`, no
model or MCP server anywhere on the runtime path. If you are about to add a dependency, don't.

The Swift app never talks to Google. `bin/fetch-events.js` writes `events.json`; the app reads it.
Keep that seam — it is why the app can be tested with a fixture and why a network failure leaves a
stale countdown instead of a blank one.

## Do not run these yourself

- `node bin/auth.js --login` — opens a browser and blocks until a human clicks Allow. Hand it over.
- `bash setup.sh` (without `--check`), `bash menubar/build.sh --install`, anything `launchctl`,
  anything writing to `~/Applications` or `~/Library/LaunchAgents` — these change the user's live
  login items. Ask first, every time. An agent installed this app unasked once already and left the
  menu bar broken for 90 minutes.
- `git commit` / `git push` — only when asked in the session. Leave work in the working tree.

To hand a command over in Claude Code, ask the user to paste it with a `!` prefix so you see the
output: `! node bin/auth.js --login`.

**`uninstall.sh` cannot be safely tested in a sandbox.** Overriding `$HOME` and copying the script
somewhere temporary is not enough: it also calls `launchctl` and `pkill -f NextMeeting`, and neither
honours `$HOME`. Both reach the live machine from any working directory. That is not hypothetical —
it has killed the running menu bar twice, once from a `--help` probe and once from a run against a
copy under a fake `$HOME`. Read this file rather than executing it, at any flag.

The general form, worth carrying to other repos: a sandbox built from paths only contains things
addressed by path. Process and service management are addressed by name, and escape it.

## Every entrypoint must be safe to probe

`--help` and an unrecognised flag must print usage and change nothing, in every script and binary
here. This is a rule about the code, not about you: `uninstall.sh --help` once performed a real
uninstall, because it set its one flag from `$1` and then ran the removal regardless of what `$1`
actually was. An agent doing the cautious thing — ask the tool what it does before running it — was
the thing that destroyed a live install.

So if you add an entrypoint, parse and reject arguments *before* the first side effect. And do not
rely on a list of dangerous commands to keep you safe: nobody typed `launchctl` that day. They typed
`--help` at a script that contained one.

## Trust exit codes, not output

`bash setup.sh --check` changes nothing and is always safe. **Exit 0 means ready; exit 1 means not
ready**, and it prints a count of what is wrong. Read the code, not the prose above it. Re-run it
after each step.

The same rule applies to the app itself. `NextMeeting --print` is the diagnostic worth learning: it
prints what the menu bar is drawing, which file it came from, and **how stale that file is**. A
large `file age` means the fetch is failing while the display looks fine — the designed failure mode
is stale-not-blank, so a frozen countdown is not a crash. `tail -20
~/Library/Logs/meeting-notification-bar/menubar.log` names the reason.

You cannot see the menu bar. A running process is not proof anything is drawn — ask the human to
look.

## Things that look like bugs and are not

- **No timezone setting.** The zone always follows the Mac and reacts live when it changes. This is
  deliberate: a pinned zone drifts from the laptop's real one and silently fetches the wrong day.
- **The sync never overwrites without `--force`.** These are notes people edit; a job that reverts
  edits is worse than no job.
- **Unknown flags exit 2 with usage.** Including `--help`, which exits 0. Deliberate — an ignored
  flag once meant `--help` started a real Drive sync.

## Before you edit

Re-read the file from disk immediately before editing it; a human may be working in parallel.
Run `node --test` (no network, no credentials needed) and, for Swift changes,
`menubar/build/NextMeeting.app/Contents/MacOS/NextMeeting --selftest`. Both must stay green.
