'use strict';

/**
 * drive.js — search Drive and export Docs as markdown, no npm dependencies.
 */

const { apiGet, parseJson, form } = require('./google-auth');

const API_HOST = 'www.googleapis.com';

const say = msg => console.error(`[drive] ${msg}`);

/**
 * files.list across every drive the account can see, fully paginated.
 *
 * The all-drives trio (corpora / includeItemsFromAllDrives / supportsAllDrives) is what makes this
 * see files organised by other people and shared with you. Without it you only get your own My
 * Drive, which for meeting notes is usually the empty half of the problem.
 *
 * `pageCap` exists because an unbounded pagination loop is a hang, not a bug report — Drive has been
 * observed handing back a nextPageToken alongside an empty page.
 */
async function listFiles(q, { fields, pageCap = 40, quiet = false } = {}) {
  const out = [];
  let pageToken = null;
  const wanted = fields ||
    'id,name,createdTime,modifiedTime,owners(displayName,emailAddress),driveId,webViewLink';

  for (let page = 0; page < pageCap; page++) {
    const params = form(Object.assign({
      q,
      corpora: 'allDrives',
      includeItemsFromAllDrives: 'true',
      supportsAllDrives: 'true',
      orderBy: 'createdTime',
      pageSize: '100',
      fields: `nextPageToken,files(${wanted})`,
    }, pageToken ? { pageToken } : {}));

    const res = await apiGet('files.list', API_HOST, `/drive/v3/files?${params}`);
    const data = parseJson('files.list', res.body);
    out.push(...(data.files || []));
    pageToken = data.nextPageToken;
    if (!pageToken) return out;
  }
  // `quiet` is for callers that deliberately ask for one page — a probe that only wants to know
  // whether Drive answers at all should not print an incomplete-results warning.
  if (!quiet) say(`WARNING: stopped at the ${pageCap}-page cap; results may be incomplete`);
  return out;
}

/**
 * Export a Doc as text. `text/markdown` is the whole reason to do this locally rather than reading
 * the Doc by hand: Drive renders the headings and bullets, so you get structure instead of a
 * flattened wall of text/plain.
 */
async function exportDoc(fileId, mimeType = 'text/markdown') {
  const res = await apiGet(
    'files.export',
    API_HOST,
    `/drive/v3/files/${encodeURIComponent(fileId)}/export?mimeType=${encodeURIComponent(mimeType)}`
  );
  return res.body;
}

/** Build a files.list query for Docs whose title contains `marker`, modified since an ISO time. */
function docQuery(marker, sinceIso) {
  // Single quotes inside a Drive `q` need escaping or the request 400s on a title like "Bob's 1:1".
  const safe = String(marker).replace(/'/g, "\\'");
  return [
    "mimeType='application/vnd.google-apps.document'",
    `name contains '${safe}'`,
    `modifiedTime > '${sinceIso}'`,
    'trashed=false',
  ].join(' and ');
}

module.exports = { listFiles, exportDoc, docQuery };
