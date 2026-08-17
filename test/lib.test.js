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

const { joinUrlOf, tzOffset, todayIn } = require('../lib/calendar');
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
// Regression for the silent wrong-day bug: fetch-events.js used to compute the calendar date in
// the *process's* zone (a bare `new Date().toLocaleDateString('en-CA')`, no `timeZone`) while the
// day window's UTC offset came from `tz`. When those two zones disagree near midnight, the date
// and the offset stop describing the same day and the wrong day's events get fetched — nothing
// errors. todayIn(tz) is the fix: it always takes the date from the same zone as the offset.
//
// A helper that fakes "now" to a fixed instant and lets a test swap process.env.TZ around it.
function withFixedNow(isoInstant, fn) {
  const fixedNow = new Date(isoInstant);
  const RealDate = Date;
  global.Date = class extends RealDate {
    constructor(...args) { return args.length ? new RealDate(...args) : new RealDate(fixedNow); }
    static now() { return fixedNow.getTime(); }
  };
  try {
    fn();
  } finally {
    global.Date = RealDate;
  }
}

function withTz(tz, fn) {
  const saved = process.env.TZ;
  process.env.TZ = tz;
  try {
    fn();
  } finally {
    if (saved === undefined) delete process.env.TZ; else process.env.TZ = saved;
  }
}

test('process.env.TZ actually changes the process-local calendar day (precondition for the next test)', () => {
  // 01:30 UTC on the 17th is still the 16th in New York (UTC-4 in August) but already the 17th in
  // Auckland (UTC+12 in August) — a genuine different-calendar-day case in two directions at once.
  withFixedNow('2026-08-17T01:30:00Z', () => {
    withTz('America/New_York', () => {
      assert.equal(new Date().toLocaleDateString('en-CA'), '2026-08-16');
    });
    withTz('Pacific/Auckland', () => {
      assert.equal(new Date().toLocaleDateString('en-CA'), '2026-08-17');
    });
  });
});

test('todayIn(tz) tracks the given zone, not the process zone — this is the actual bug fix', () => {
  withFixedNow('2026-08-17T01:30:00Z', () => {
    // Process zone is Auckland (the 17th there); todayIn is asked for New York (still the 16th).
    // The old, buggy code (`new Date().toLocaleDateString('en-CA')` with no timeZone) would return
    // the process zone's date, '2026-08-17' — the wrong day for a New York day window. This test
    // fails against that old code and passes against todayIn().
    withTz('Pacific/Auckland', () => {
      assert.equal(todayIn('America/New_York'), '2026-08-16');
      assert.equal(todayIn('Pacific/Auckland'), '2026-08-17');
    });
    // And it holds regardless of what the process zone happens to be.
    withTz('America/New_York', () => {
      assert.equal(todayIn('Pacific/Auckland'), '2026-08-17');
    });
  });
});

test('todayIn(tz) and tzOffset(tz) describe the same day window when given the same zone', () => {
  // The invariant the bug broke: pairing the date from one zone with the offset from another.
  // Fixed 01:30 UTC on the 17th — New York's day window for '2026-08-16' at offset '-04:00' must
  // actually contain this instant.
  withFixedNow('2026-08-17T01:30:00Z', () => {
    withTz('Pacific/Auckland', () => {
      const date = todayIn('America/New_York');
      const offset = tzOffset('America/New_York');
      assert.equal(date, '2026-08-16');
      assert.equal(offset, '-04:00');
      const windowStart = new Date(`${date}T00:00:00${offset}`);
      const windowEnd = new Date(`${date}T23:59:59${offset}`);
      const now = new Date();
      assert.ok(now >= windowStart && now <= windowEnd, 'now must fall inside its own day window');
    });
  });
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
test('config fills in defaults and resolves a timezone from $TZ, not from config.json', () => {
  // fixture.config.json intentionally has no `timezone` key any more — timezone is no longer a
  // config setting, it always follows the Mac ($TZ, or the system zone via Intl).
  withTz('America/New_York', () => {
    const cfg = config.load();
    assert.equal(cfg.calendarId, 'test-calendar@example.test');
    assert.equal(cfg.timezone, 'America/New_York');
    assert.equal(cfg.driveSync.titleContains, 'Notes by Gemini');   // default, absent from the fixture
    assert.equal(cfg.driveSync.lookbackDays, 7);                    // fixture overrides the default
    assert.ok(path.isAbsolute(cfg.driveSync.outputDir), 'a leading ~ must be expanded');
  });
});

test('config ignores a timezone key even if one is present in config.json', () => {
  // Belt-and-braces: even if a stray `timezone` key survives in someone's config.json (fixture
  // used to have one), it must not win over the resolved zone.
  const fs = require('node:fs');
  const os = require('node:os');
  const path2 = require('node:path');
  const dir = fs.mkdtempSync(path2.join(os.tmpdir(), 'mnb-cfg-'));
  const file = path2.join(dir, 'config.json');
  fs.writeFileSync(file, JSON.stringify({ calendarId: 'x', timezone: 'Pacific/Auckland' }));
  const savedConfig = process.env.MNB_CONFIG;
  process.env.MNB_CONFIG = file;
  delete require.cache[require.resolve('../lib/paths')];
  delete require.cache[require.resolve('../lib/config')];
  try {
    withTz('America/New_York', () => {
      const freshConfig = require('../lib/config');
      const cfg = freshConfig.load();
      assert.equal(cfg.timezone, 'America/New_York');
    });
  } finally {
    process.env.MNB_CONFIG = savedConfig;
    fs.rmSync(dir, { recursive: true, force: true });
    delete require.cache[require.resolve('../lib/paths')];
    delete require.cache[require.resolve('../lib/config')];
  }
});
