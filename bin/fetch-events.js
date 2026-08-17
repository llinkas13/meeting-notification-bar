#!/usr/bin/env node
'use strict';

/**
 * fetch-events.js — write one day's calendar events as JSON to stdout.
 *
 * This is the only thing that talks to Google on the menu bar path. The Swift app never does; it
 * reads the file this produces. No LLM, no MCP server, no Claude CLI — one HTTPS GET to
 * googleapis.com and some JSON.
 *
 *   node bin/fetch-events.js
 *   node bin/fetch-events.js --date 2026-08-18 --tz America/New_York --calendar primary
 *   node bin/fetch-events.js --pretty
 *
 * Output: a JSON array on stdout — [{title, start, end, attendees, joinUrl, location, htmlLink}].
 * Errors go to stderr and exit nonzero, so the caller can keep the previous good file.
 */

const { listEvents, todayIn } = require('../lib/calendar');
const config = require('../lib/config');

const argv = process.argv.slice(2);
const has = f => argv.includes(f);
const arg = (flag, def) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : def; };

// Reject unknown flags before the network call. An unrecognised flag used to be ignored, so a typo
// like `--timezone` (instead of `--tz`) silently fetched the default zone's day instead of failing
// — and `--help` fetched a day's events rather than printing anything helpful. Usage goes to
// stderr, never stdout, because stdout here is the JSON that refresh-events.sh writes to disk.
const BOOL_FLAGS = ['--pretty'];
const VALUE_FLAGS = ['--tz', '--date', '--calendar'];
const USAGE = `fetch-events.js — print one day's calendar events as JSON on stdout.

  --date <YYYY-MM-DD>  the day to fetch (default: today, in --tz)
  --tz <IANA zone>     e.g. America/New_York (default: this Mac's zone)
  --calendar <id>      calendar address (default: config calendarId, normally "primary")
  --pretty             indent the JSON

The date and the day window's UTC offset are always taken from the same zone, so they cannot
disagree and fetch the wrong day.`;

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (VALUE_FLAGS.includes(a)) { i++; continue; }
  if (BOOL_FLAGS.includes(a)) continue;
  console.error(USAGE);
  process.exit(a === '--help' || a === '-h' ? 0 : 2);
}

const cfg = config.load();
const tz = arg('--tz', cfg.timezone);
// todayIn(tz) uses the *same* zone as `tz` above, so the date and the UTC offset built from it
// always agree — computing the date in the process zone instead (e.g. a bare
// `new Date().toLocaleDateString('en-CA')` with no `timeZone`) is the exact bug this file exists
// to avoid: the process zone and `tz` can disagree on the calendar day near midnight, silently
// fetching the wrong day's events.
const date = arg('--date', todayIn(tz));
const calendar = arg('--calendar', cfg.calendarId);

listEvents(calendar, date, tz)
  .then(events => {
    process.stdout.write(has('--pretty')
      ? JSON.stringify(events, null, 2) + '\n'
      : JSON.stringify(events));
  })
  .catch(err => {
    process.stderr.write(`[fetch-events] FAILED: ${err.message}\n`);
    process.exit(1);
  });
