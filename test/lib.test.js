'use strict';

/**
 * node --test test/
 *
 * Covers the pure functions only — everything that can be wrong without a network call. No mocking
 * of Google, no fixtures to keep in sync: the parts that talk to the API are three lines each and
 * are exercised for real by `node bin/auth.js --check`.
 *
 * MNB_CONFIG is pointed at a fixture so the suite reads the same values on any machine, whether or
 * not the person running it has a config.json.
 */

const test = require('node:test');
const assert = require('node:assert');
const path = require('path');

process.env.MNB_CONFIG = path.join(__dirname, 'fixture.config.json');

const { joinUrlOf, tzOffset } = require('../lib/calendar');
const { docQuery } = require('../lib/drive');
const { fileNameFor, frontmatter, resolveDest } = require('../bin/sync-drive-docs');
const config = require('../lib/config');

// ---------------------------------------------------------------------------
test('joinUrl prefers hangoutLink over everything else', () => {
  const url = joinUrlOf({
    hangoutLink: 'https://meet.google.com/abc-defg-hij',
    conferenceData: { entryPoints: [{ entryPointType: 'video', uri: 'https://zoom.us/j/1' }] },
    location: 'https://teams.microsoft.com/l/2',
  });
  assert.equal(url, 'https://meet.google.com/abc-defg-hij');
});

test('joinUrl falls back to the video entry point, not the phone one', () => {
  const url = joinUrlOf({
    conferenceData: {
      entryPoints: [
        { entryPointType: 'phone', uri: 'tel:+15551234567' },
        { entryPointType: 'video', uri: 'https://zoom.us/j/99' },
      ],
    },
  });
  assert.equal(url, 'https://zoom.us/j/99');
});

test('joinUrl digs a URL out of location — where Zoom and Teams invites put it', () => {
  const url = joinUrlOf({ location: 'Room 4 / https://teams.microsoft.com/l/meetup-join/xyz' });
  assert.equal(url, 'https://teams.microsoft.com/l/meetup-join/xyz');
});

test('joinUrl is empty when there is genuinely nothing to open', () => {
  assert.equal(joinUrlOf({ location: 'Conference room B' }), '');
  assert.equal(joinUrlOf({}), '');
});

// ---------------------------------------------------------------------------
test('tzOffset returns a signed HH:MM offset', () => {
  assert.match(tzOffset('America/New_York'), /^-0[45]:00$/);
  assert.equal(tzOffset('UTC'), '+00:00');
});

// ---------------------------------------------------------------------------
test('docQuery escapes apostrophes — an unescaped one 400s the Drive request', () => {
  const q = docQuery("Bob's 1:1", '2026-08-01T00:00:00Z');
  assert.ok(q.includes("name contains 'Bob\\'s 1:1'"), q);
  assert.ok(q.includes('trashed=false'));
  assert.ok(q.includes("modifiedTime > '2026-08-01T00:00:00Z'"));
});

// ---------------------------------------------------------------------------
test('fileNameFor sorts chronologically and strips the Gemini boilerplate', () => {
  assert.equal(
    fileNameFor({ name: 'Team Standup - Notes by Gemini', createdTime: '2026-08-17T14:00:00Z' }),
    '2026-08-17-team-standup.md'
  );
});

test('fileNameFor survives punctuation, unicode and a missing date', () => {
  assert.equal(
    fileNameFor({ name: 'Q3 Planning / Roadmap (draft!)', createdTime: '2026-08-17T14:00:00Z' }),
    '2026-08-17-q3-planning-roadmap-draft.md'
  );
  assert.equal(fileNameFor({ name: '???' }), 'undated-untitled.md');
});

test('frontmatter escapes quotes in the title so the YAML stays parseable', () => {
  const fm = frontmatter({ id: 'abc', name: 'The "big" review' });
  assert.ok(fm.includes('title: "The \\"big\\" review"'), fm);
  assert.ok(fm.includes('doc_id: abc'));
  assert.ok(fm.startsWith('---\n') && fm.trimEnd().endsWith('---'));
});

// ---------------------------------------------------------------------------
test('resolveDest suffixes a different Doc that wants an occupied filename', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mnb-'));
  const doc = { id: 'abcdef123456', name: 'Standup', createdTime: '2026-08-17T14:00:00Z' };
  const taken = path.join(dir, '2026-08-17-standup.md');

  // Nothing there yet: the plain name.
  assert.equal(resolveDest(doc, dir), taken);

  // Occupied by this same Doc: reuse it, so --force overwrites in place instead of piling up copies.
  fs.writeFileSync(taken, frontmatter(doc));
  assert.equal(resolveDest(doc, dir), taken);

  // Occupied by a DIFFERENT Doc: suffix, rather than silently dropping this one.
  const other = { ...doc, id: 'zzzzzz999999' };
  assert.equal(resolveDest(other, dir), path.join(dir, '2026-08-17-standup-zzzzzz.md'));

  fs.rmSync(dir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
test('config fills in defaults and resolves a timezone', () => {
  const cfg = config.load();
  assert.equal(cfg.calendarId, 'test-calendar@example.test');
  assert.equal(cfg.timezone, 'America/New_York');
  assert.equal(cfg.driveSync.titleContains, 'Notes by Gemini');   // default, absent from the fixture
  assert.equal(cfg.driveSync.lookbackDays, 7);                    // fixture overrides the default
  assert.ok(path.isAbsolute(cfg.driveSync.outputDir), 'a leading ~ must be expanded');
});
