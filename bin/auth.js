#!/usr/bin/env node
'use strict';

/**
 * auth.js — one-time Google consent, and a probe to prove it worked.
 *
 *   node bin/auth.js --login    open the consent page, cache a refresh token
 *   node bin/auth.js --check    read-only "is this wired up" probe; prints no secret
 *   node bin/auth.js --logout   delete the cached token (the OAuth client stays)
 *
 * --check is the first thing to run when the menu bar looks wrong, because it separates "Google is
 * refusing us" from "the app is misdrawing".
 */

const fs = require('fs');
const path = require('path');

const { HOME, TOKEN_FILE, CLIENT_FILE } = require('../lib/paths');
const { login, token, SCOPE } = require('../lib/google-auth');
const { listFiles } = require('../lib/drive');
const { listEvents } = require('../lib/calendar');
const config = require('../lib/config');

const argv = process.argv.slice(2);
const say = msg => console.error(`[auth] ${msg}`);
const rel = f => path.relative(HOME, f) || f;

async function check() {
  const cfg = config.load();
  const t = await token();
  say(`ok: access token present (${t.length} chars)`);
  say(`     scopes: ${SCOPE}`);
  say(`     timezone in use: ${cfg.timezone || '(none — the day window would be UTC)'}`);

  const date = new Date().toLocaleDateString('en-CA');
  const events = await listEvents(cfg.calendarId, date, cfg.timezone);
  say(`ok: calendar reachable — ${events.length} event(s) today on "${cfg.calendarId}"`);

  const docs = await listFiles(
    "mimeType='application/vnd.google-apps.document' and trashed=false",
    { pageCap: 1, quiet: true }
  );
  say(`ok: drive reachable — ${docs.length} Doc(s) on the first page`);
}

async function main() {
  if (argv.includes('--login')) return void await login();

  if (argv.includes('--logout')) {
    if (fs.existsSync(TOKEN_FILE)) {
      fs.unlinkSync(TOKEN_FILE);
      say(`deleted ${rel(TOKEN_FILE)} — run --login to authorize again`);
    } else {
      say('no cached token to delete');
    }
    say(`${rel(CLIENT_FILE)} left in place; also revoke at myaccount.google.com/permissions if you want the grant gone`);
    return;
  }

  if (argv.includes('--check')) return void await check();

  // Asking for help is not an error, so --help exits 0; an unrecognised flag exits 2. The other two
  // entry points follow the same rule, and a coworker's agent probes with --help before anything.
  const usage = 'usage: node bin/auth.js [--login | --check | --logout]';
  say(usage);
  process.exit(argv.includes('--help') || argv.includes('-h') ? 0 : 2);
}

main().catch(err => { say(`FAILED: ${err.message}`); process.exit(1); });
