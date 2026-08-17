'use strict';

/**
 * calendar.js — read-only Google Calendar access, no npm dependencies.
 *
 * Uses the shared token from google-auth.js. Run `node bin/auth.js --login` once.
 */

const { apiGet, parseJson } = require('./google-auth');

const API_HOST = 'www.googleapis.com';

/**
 * The UTC offset (+HH:MM / -HH:MM) for an IANA zone at the current moment. Intl handles DST, so
 * this is correct in March and November without a tz database package.
 */
function tzOffset(tz) {
  const now = new Date();
  const utc = new Date(now.toLocaleString('en-US', { timeZone: 'UTC' }));
  const local = new Date(now.toLocaleString('en-US', { timeZone: tz }));
  const diffMin = Math.round((local - utc) / 60000);
  const sign = diffMin >= 0 ? '+' : '-';
  const h = String(Math.floor(Math.abs(diffMin) / 60)).padStart(2, '0');
  const m = String(Math.abs(diffMin) % 60).padStart(2, '0');
  return `${sign}${h}:${m}`;
}

/**
 * List events on `calendarId` for `date` (YYYY-MM-DD) in `tz` (IANA name).
 * Returns [{title, start, end, attendees:[email], joinUrl, location, htmlLink}].
 *
 * Passing no `tz` builds the window in UTC, which is a silent wrong-day bug in any zone west of
 * Greenwich — config.js exists to make sure that never happens. See its header.
 *
 * Do NOT add `conferenceDataVersion: '1'` to the params below hoping to get entryPoints. That is a
 * write-path parameter — it governs insert/update/patch — and events.list ignores it. Checked
 * against the live API: the response is identical with and without it, and conferenceData already
 * arrives with entryPoints. Events that come back with none genuinely have no conferencing attached.
 */
async function listEvents(calendarId = 'primary', date, tz) {
  const offset = tz ? tzOffset(tz) : 'Z';
  const params = new URLSearchParams({
    timeMin: `${date}T00:00:00${offset}`,
    timeMax: `${date}T23:59:59${offset}`,
    singleEvents: 'true',      // expand recurring series into individual instances
    orderBy: 'startTime',      // only legal alongside singleEvents
    maxResults: '50',
  });
  const res = await apiGet(
    'calendar.events.list',
    API_HOST,
    `/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events?${params}`
  );
  const data = parseJson('calendar.events.list', res.body);
  return (data.items || []).map(e => ({
    title: e.summary || '(no title)',
    // All-day events carry `date` instead of `dateTime`. Kept as-is; the menu bar app excludes
    // anything without a time from the countdown rather than pretending it starts at midnight.
    start: e.start.dateTime || e.start.date,
    end: e.end.dateTime || e.end.date,
    attendees: (e.attendees || []).map(a => a.email).filter(Boolean),
    joinUrl: joinUrlOf(e),
    location: e.location || '',
    htmlLink: e.htmlLink || '',
  }));
}

/**
 * A clickable meeting URL, or '' when there isn't one. Google's own hangoutLink first, then the
 * first video conference entry point, then a URL sitting in `location` — which is where Zoom and
 * Teams invitations usually put it.
 */
function joinUrlOf(e) {
  if (e.hangoutLink) return e.hangoutLink;
  const points = (e.conferenceData && e.conferenceData.entryPoints) || [];
  const entry = points.find(p => p.entryPointType === 'video' && p.uri) || points.find(p => p.uri);
  if (entry) return entry.uri;
  const inLocation = (e.location || '').match(/https?:\/\/\S+/);
  return inLocation ? inLocation[0] : '';
}

module.exports = { listEvents, joinUrlOf, tzOffset };
