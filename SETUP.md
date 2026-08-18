# SETUP.md — handoff for an agent installing this with its user

Read this file to the end before running anything.

`setup.sh` does the entire install and is safe to re-run. Two of its steps need a human, and one of
them will hang forever if you run it yourself. That is the only reason this file exists.

The menu bar is the whole install by default. Drive sync (Google Docs → local markdown) only goes
in if you pass `--with-sync` — ask before adding it, don't assume it's wanted.

## The two steps you cannot do

1. **Create the Google OAuth client.** Clicks in the Google Cloud console — create a project, enable
   the Calendar and Drive APIs, make an OAuth client of type *Desktop app*, download the JSON.
   `docs/google-cloud-setup.md` is the six-step version. There is no API for this.
2. **Approve the consent screen.** `node bin/auth.js --login` opens a browser and blocks until
   somebody clicks Allow. Run it yourself and you will sit there until the tool times out.

Your own harness may additionally refuse to let you copy files into `.secrets/` or call `launchctl`.
That is a guardrail on you, not a restriction on your user — their terminal runs those fine. Hand the
command over rather than looking for a way around it.

**Handing a command over:** in Claude Code, tell them to paste it with a `!` prefix — `! node
bin/auth.js --login` — so it runs in the session and you see the output. Elsewhere, just ask them to
run it and paste the result.

## Before you ask for consent

Tell them what they are approving, because the consent screen itself is vague: **read-only** access
to Calendar and Drive, a token cached at `.secrets/token.json` on their own disk, and no server
anywhere. Both scopes are requested at this step regardless of `--with-sync` — the Drive scope just
sits unused if sync is never installed. If their Google account is a personal `gmail.com` one and the
Cloud project is still in testing mode, the refresh token expires after 7 days and they will
re-approve weekly. Workspace accounts do not have this problem. Worth saying up front — it is the
single most common surprise.

## The sequence

1. **[you]** `bash setup.sh --check` — changes nothing, prints the state of all five steps. Start
   here even on a fresh clone; it tells you which of the following you can skip.
   **Exit 0 means ready; exit 1 means it is not, and the count of unmet checks is on the last line.**
   Trust the exit code over the prose — and re-run it after every step below to confirm the step
   actually took, rather than assuming it did.
2. **[them]** If `--check` says `no .secrets/oauth-client.json`: `docs/google-cloud-setup.md`, then
   `mkdir -p .secrets && mv ~/Downloads/client_secret_*.json .secrets/oauth-client.json`
3. **[them]** If `--check` says `not authorized yet`: `! node bin/auth.js --login`
4. **[you]** `bash setup.sh` — or `bash setup.sh --with-sync` if they also want Google Docs mirrored
   to local markdown every 30 minutes. Ask; it is a separate feature, not part of the menu bar.
5. **[you]** Verify (below).

Steps 2 and 3 are the only handoffs. Everything else is yours.

## Verify

```
~/Applications/NextMeeting.app/Contents/MacOS/NextMeeting --print
```

Prints what the menu bar is currently drawing, where it read it from, how stale that file is, and
every event it parsed. A healthy result has a low `file age` and a plausible event list. This is the
one command worth teaching your user, because it answers "why is it showing that?" without you.

Then ask them to look at the top-right of their screen — you cannot see the menu bar, and a running
process is not proof that anything is drawn.

## When it does not work

**`not authorized yet` in the log, but `.secrets/token.json` exists.** The app is pointed at a
different checkout than the one holding the token. The bundle hard-codes `MNB_HOME` at build time —
check `~/Applications/NextMeeting.app/Contents/Resources/refresh-events.sh` and confirm the path it
exports is the checkout you have been working in. Rebuild from the right one.

**Menu bar frozen on old data.** `--print` shows a large `file age`. The app is fine; the refresh is
failing. `tail -20 ~/Library/Logs/meeting-notification-bar/menubar.log` names the reason. Note the
app deliberately keeps the last good file rather than blanking — stale beats empty, so a frozen
countdown is the designed failure mode, not a crash.

**`REFUSING TO INSTALL: ... already belongs to <id>`.** Another checkout owns
`~/Applications/NextMeeting.app`. Two LaunchAgents pointing at one binary fight silently, so the
build stops instead. It prints the three commands to clear the other one — those are `launchctl` and
`rm`, so they are probably a handoff to your user.

**`swiftc not found`.** `xcode-select --install`. Command Line Tools, not the full Xcode download.

## What you are allowed to change

`config.json` is theirs — created from `config.example.json` on first run and never overwritten.
Timezone is not in it: the app always follows the Mac and reacts live when the system zone changes.
If they ask to pin a zone, the answer is that there is deliberately no setting for it.
