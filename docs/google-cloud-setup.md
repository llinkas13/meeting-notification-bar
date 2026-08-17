# Google Cloud setup

The only part of installation that needs a browser. Ten minutes, once, and it never repeats — the
refresh token cached afterwards does not expire on a normal schedule.

You are creating an OAuth client that belongs to *you* and runs only on this Mac. Nothing is
published, nothing is reviewed by Google, and no verification is needed, because the app stays in
testing mode with you as the only user.

## 1. Create a project

<https://console.cloud.google.com/projectcreate>

Any name. If you already have a personal project, reuse it.

## 2. Enable the two APIs

Both are free and read-only in the way this repo uses them.

- <https://console.cloud.google.com/apis/library/calendar-json.googleapis.com> → **Enable**
- <https://console.cloud.google.com/apis/library/drive.googleapis.com> → **Enable**

Skip the Drive one if you only want the menu bar. `bin/auth.js --check` will then report the Drive
probe as failed, and nothing else breaks.

## 3. Configure the consent screen

**APIs & Services → OAuth consent screen**

- User type: **External**. (**Internal** is offered only on Workspace accounts and is fine too —
  it skips the test-user step below.)
- App name: anything. Support email and developer email: your own address.
- Publishing status: leave it as **Testing**. Do not click "Publish app".
- **Audience → Test users → Add users**: add the Google account whose calendar you want. This step
  is the one people skip, and skipping it makes consent fail later with `access_denied`.

Testing mode has one consequence worth knowing: a refresh token issued by an app in testing expires
after **7 days** on a consumer `@gmail.com` account. On a Google Workspace account it does not. If
you are on gmail.com and the menu bar goes stale weekly, that is why — re-run
`node bin/auth.js --login`, or publish the app to move to a non-expiring token.

## 4. Create the OAuth client

**APIs & Services → Credentials → Create credentials → OAuth client ID**

- Application type: **Desktop app**. This matters. A "Web application" client requires a registered
  redirect URI, and the loopback flow this repo uses picks a random localhost port at runtime, which
  you cannot register. A Desktop client accepts any `127.0.0.1` port by design.
- Name: anything.
- **Download JSON**.

## 5. Put the JSON where the code looks for it

```bash
cd /path/to/meeting-notification-bar
mkdir -p .secrets
mv ~/Downloads/client_secret_*.json .secrets/oauth-client.json
chmod 700 .secrets && chmod 600 .secrets/oauth-client.json
```

`.secrets/` is gitignored. Nothing in this repo ever prints a token or a client secret — the most
you get is a character count.

## 6. Consent

```bash
node bin/auth.js --login     # a browser opens; approve read-only Calendar + Drive
node bin/auth.js --check     # proves it works, prints no secret
```

You will see an "app isn't verified" warning. That is expected for a testing-mode app; **Advanced →
Go to (unsafe)**. The app is yours, running on your machine, and the scopes it is asking for are the
read-only ones listed on the screen.

Then `bash setup.sh` and you are done.

## Undoing it

```bash
node bin/auth.js --logout                        # delete the local token
```

Then revoke the grant at <https://myaccount.google.com/permissions>, and delete the project in the
Cloud console if you want no trace of it.

## Failure modes, and what they actually mean

| What you see | Cause |
|---|---|
| `access_denied` on the consent screen | The account is not in **Test users**, or you approved with a different Google account than the one you added. |
| `Google returned no refresh_token` | A previous grant is still live, so Google reissued without one. Revoke at myaccount.google.com/permissions and retry. |
| `not authorized yet` | No `.secrets/token.json`. Run `--login`. |
| `no OAuth client at .secrets/oauth-client.json` | Step 5 did not happen, or the file is named differently. |
| `HTTP 403 … has not been used in project` | The API from step 2 is not enabled. The message names which one. |
| Menu bar shows the wrong day's meetings | A timezone problem, not an auth problem. See the timezone note in the main README. |
| Weekly re-auth on a gmail.com account | Testing-mode 7-day refresh token expiry. See step 3. |
