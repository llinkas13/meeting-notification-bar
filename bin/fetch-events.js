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

const { listEvents } = require('../lib/calendar');
const config = require('../lib/config');

const argv = process.argv.slice(2);
const has = f => argv.includes(f);
const arg = (flag, def) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : def; };

const cfg = config.load();
const date = arg('--date', new Date().toLocaleDateString('en-CA'));   // YYYY-MM-DD, local
const tz = arg('--tz', cfg.timezone);
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
