'use strict';

/**
 * google-auth.js — OAuth for a desktop app, on the Node standard library alone.
 *
 * WHY NO `googleapis` PACKAGE
 * There is no package.json and no node_modules in this repo, so `node bin/<anything>.js` works on a
 * fresh clone with nothing installed. Adding the Google SDK for three REST calls would end that.
 * `https` is enough.
 *
 * WHAT IT DOES
 *   login()  one-time interactive consent over a loopback redirect, caches a refresh token
 *   token()  a valid access token, refreshing the cached one when it is spent
 *
 * Both scopes are read-only and share one token file, so consent happens once for calendar and
 * Drive together.
 *
 * Secrets live in .secrets/ (gitignored, written 0600) and are never logged. Anything printed about
 * a token is a boolean or a length, never a value.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { execFile } = require('child_process');

const { SECRETS, CLIENT_FILE, TOKEN_FILE, HOME } = require('./paths');

const SCOPE = [
  'https://www.googleapis.com/auth/calendar.readonly',
  'https://www.googleapis.com/auth/drive.readonly',
].join(' ');

const TOKEN_HOST = 'oauth2.googleapis.com';

// Refresh a little early: a token that expires mid-pagination costs a confusing 401 halfway through
// a run, which is far more annoying to debug than one extra refresh call.
const EXPIRY_SKEW_MS = 60 * 1000;

const rel = f => path.relative(HOME, f) || f;
const say = msg => console.error(`[auth] ${msg}`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const truncate = (s, n = 300) => (s && s.length > n ? `${s.slice(0, n)}…` : s || '');

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

// 0600 from the moment it exists — writeFileSync's mode only applies on create, so chmod after.
function writeSecret(file, obj) {
  fs.mkdirSync(SECRETS, { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, JSON.stringify(obj, null, 2), { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}

function clientCreds() {
  const raw = readJson(CLIENT_FILE);
  // A Desktop client's JSON nests everything under "installed"; accept a flattened copy too.
  const c = raw && (raw.installed || raw.web || raw);
  if (!c || !c.client_id || !c.client_secret) {
    throw new Error(
      `no OAuth client at ${rel(CLIENT_FILE)} — see docs/google-cloud-setup.md`
    );
  }
  return { id: c.client_id, secret: c.client_secret };
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

/**
 * One request, promised. Resolves { status, body } with body as a string — callers decide whether it
 * is JSON (a Doc export is not). Never throws on a non-2xx; retry policy is the caller's.
 */
function request(opts, payload) {
  return new Promise((resolve, reject) => {
    const req = https.request(opts, res => {
      const chunks = [];
      res.on('data', d => chunks.push(d));
      res.on('end', () => resolve({
        status: res.statusCode,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

/**
 * Retry 429 and 5xx with exponential backoff. The per-user quota is generous, but a first sync that
 * walks every Doc in an org can trip it, and a bare 429 inside a scheduled run looks identical to a
 * broken script. Any other 4xx is a real error — fail fast, do not retry.
 */
async function withRetry(label, fn, attempts = 4) {
  let wait = 500;
  for (let i = 1; i <= attempts; i++) {
    const res = await fn();
    if (res.status < 400) return res;
    const retryable = res.status === 429 || res.status >= 500;
    if (!retryable || i === attempts) {
      throw new Error(`${label}: HTTP ${res.status} ${truncate(res.body)}`);
    }
    say(`${label}: HTTP ${res.status}, retrying in ${wait}ms (${i}/${attempts - 1})`);
    await sleep(wait);
    wait *= 2;
  }
}

/** JSON.parse that says which call produced the unparseable body. A raw SyntaxError here is
 *  near-undebuggable: Google returns HTML for some 5xx and gateway errors. */
function parseJson(label, body) {
  try { return JSON.parse(body); } catch (_) {
    throw new Error(`${label}: response was not JSON — ${truncate(body, 200)}`);
  }
}

function form(obj) {
  return Object.entries(obj)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&');
}

function postToken(params) {
  const payload = form(params);
  return withRetry('token', () => request({
    host: TOKEN_HOST,
    path: '/token',
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'content-length': Buffer.byteLength(payload),
    },
  }, payload));
}

// ---------------------------------------------------------------------------
// OAuth
// ---------------------------------------------------------------------------

/**
 * Interactive first-run consent, loopback flow — the supported Desktop-app redirect since the
 * out-of-band copy-paste flow was retired. Serves exactly one request on 127.0.0.1, captures
 * ?code=, trades it for a refresh token, and shuts the listener down.
 *
 * Port 0 means the OS picks a free port, so there is no port to register in the Cloud console: a
 * Desktop client accepts any 127.0.0.1 port by design.
 */
async function login() {
  const { id, secret } = clientCreds();

  const server = http.createServer();
  await new Promise(res => server.listen(0, '127.0.0.1', res));
  const redirect = `http://127.0.0.1:${server.address().port}`;

  const authUrl = 'https://accounts.google.com/o/oauth2/v2/auth?' + form({
    client_id: id,
    redirect_uri: redirect,
    response_type: 'code',
    scope: SCOPE,
    access_type: 'offline',
    prompt: 'consent',              // force a refresh_token even on a re-auth
  });

  const codePromise = new Promise((resolve, reject) => {
    server.once('request', (req, res) => {
      const q = new URL(req.url, redirect).searchParams;
      const code = q.get('code');
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end(code ? 'Authorized. You can close this tab.' : `Authorization failed: ${q.get('error')}`);
      server.close();
      code ? resolve(code) : reject(new Error(`consent denied: ${q.get('error') || 'no code'}`));
    });
    setTimeout(() => { server.close(); reject(new Error('consent timed out after 5 min')); }, 5 * 60_000);
  });

  say('opening the consent page — approve read-only Calendar + Drive access');
  say(`if nothing opens, visit:\n${authUrl}`);
  execFile('open', [authUrl], () => {});   // macOS; failure is fine, the URL is printed above

  const code = await codePromise;
  const res = await postToken({
    code,
    client_id: id,
    client_secret: secret,
    redirect_uri: redirect,
    grant_type: 'authorization_code',
  });
  const tok = parseJson('token exchange', res.body);
  if (!tok.refresh_token) {
    throw new Error('Google returned no refresh_token — revoke the app at myaccount.google.com/permissions and retry');
  }
  writeSecret(TOKEN_FILE, {
    refresh_token: tok.refresh_token,
    access_token: tok.access_token,
    expires_at: Date.now() + (tok.expires_in || 3600) * 1000,
  });
  say(`refresh token cached in ${rel(TOKEN_FILE)} (0600)`);
  return true;
}

/** A valid access token, refreshing if the cached one is spent. Resolves to a string; the value is
 *  never logged. */
async function token() {
  const cached = readJson(TOKEN_FILE);
  if (!cached || !cached.refresh_token) {
    throw new Error('not authorized yet — run: node bin/auth.js --login');
  }
  if (cached.access_token && cached.expires_at - EXPIRY_SKEW_MS > Date.now()) {
    return cached.access_token;
  }
  const { id, secret } = clientCreds();
  const res = await postToken({
    refresh_token: cached.refresh_token,
    client_id: id,
    client_secret: secret,
    grant_type: 'refresh_token',
  });
  const tok = parseJson('token refresh', res.body);
  if (!tok.access_token) {
    throw new Error(`token refresh returned no access_token — ${truncate(res.body, 200)}`);
  }
  writeSecret(TOKEN_FILE, {
    refresh_token: cached.refresh_token,       // refresh tokens are not rotated on use
    access_token: tok.access_token,
    expires_at: Date.now() + (tok.expires_in || 3600) * 1000,
  });
  return tok.access_token;
}

/** GET against a googleapis host with a bearer token, retried. Shared by calendar.js and drive.js. */
async function apiGet(label, host, urlPath) {
  const bearer = await token();
  return withRetry(label, () => request({
    host,
    path: urlPath,
    method: 'GET',
    headers: { authorization: `Bearer ${bearer}` },
  }));
}

module.exports = { login, token, apiGet, parseJson, form, SCOPE };
