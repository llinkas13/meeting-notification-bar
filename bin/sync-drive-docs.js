#!/usr/bin/env node
'use strict';

/**
 * sync-drive-docs.js — pull Google Docs whose title matches a marker down into a local folder as
 * markdown, one file per Doc, newest-first cursor kept between runs.
 *
 * The default marker is "Notes by Gemini", so out of the box this is a one-way mirror of your Gemini
 * meeting notes into plain files you own. Change `driveSync.titleContains` in config.json and it
 * mirrors any set of Docs you can name by title.
 *
 *   node bin/sync-drive-docs.js --dry-run          list what would be pulled, write nothing
 *   node bin/sync-drive-docs.js                    pull into driveSync.outputDir
 *   node bin/sync-drive-docs.js --since 2026-07-01T00:00:00Z
 *   node bin/sync-drive-docs.js --reset            forget the cursor and the seen list
 *   node bin/sync-drive-docs.js --force            re-download and overwrite existing files
 *
 * FOUR THINGS IT DELIBERATELY WILL NOT DO
 *   - It never writes over an existing file unless you pass --force. These are notes; you will edit
 *     them, and a scheduled job that silently reverts your edits is worse than no sync at all.
 *   - The cursor only advances on a successful run, and --dry-run never touches it. A failed or
 *     rehearsed run must not narrow the next real window.
 *   - It is one-way. Nothing is ever written back to Drive, and the scope is read-only, so it
 *     cannot be.
 *   - It writes into a folder, not into any note-taking app's database. Point it at an Obsidian
 *     vault or a plain Documents folder; the tool does not care and does not know.
 */

const fs = require('fs');
const path = require('path');

const { SYNC_STATE_FILE, DATA } = require('../lib/paths');
const { listFiles, exportDoc, docQuery } = require('../lib/drive');
const config = require('../lib/config');

const argv = process.argv.slice(2);
const has = f => argv.includes(f);
const arg = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

const DRY = has('--dry-run');
const RESET = has('--reset');
const FORCE = has('--force');

const log = (...a) => console.log(...a);
const say = m => console.error(`[sync] ${m}`);

// Cap the seen list so the state file cannot grow without bound. Oldest ids fall off first; a Doc
// old enough to age out is also long past the modifiedTime window, so it will not come back.
const SEEN_CAP = 800;

function readState() {
  try { return JSON.parse(fs.readFileSync(SYNC_STATE_FILE, 'utf8')); } catch (_) { return {}; }
}

function writeState(state) {
  fs.mkdirSync(DATA, { recursive: true });
  fs.writeFileSync(SYNC_STATE_FILE, JSON.stringify(state, null, 2));
}

/**
 * A filename that sorts chronologically and survives a round trip through Finder, Git and a
 * case-insensitive filesystem: 2026-08-17-team-standup.md.
 *
 * The Doc id is NOT in the name. Names should be readable and stable; the id lives in the
 * frontmatter, which is where the sync looks when it needs to know where a file came from.
 */
function fileNameFor(doc) {
  const date = String(doc.createdTime || '').slice(0, 10) || 'undated';
  const slug = String(doc.name || 'untitled')
    .toLowerCase()
    .replace(/notes by gemini/gi, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80) || 'untitled';
  return `${date}-${slug}.md`;
}

/** The doc_id recorded in an existing file's frontmatter, or null if there isn't one. */
function docIdOf(file) {
  try {
    const head = fs.readFileSync(file, 'utf8').slice(0, 600);
    const m = head.match(/^doc_id:\s*(\S+)\s*$/m);
    return m ? m[1] : null;
  } catch (_) { return null; }
}

/**
 * Where a Doc should land, disambiguating a genuine name collision.
 *
 * Two different Docs can produce the same filename — same title, same day, which happens with
 * back-to-back sessions of one recurring meeting. Without this the second one hits the
 * "already on disk" skip and is dropped in silence, which is the worst failure this tool has.
 * A file whose frontmatter carries a *different* doc_id gets a short id suffix instead.
 */
function resolveDest(doc, outDir) {
  const base = path.join(outDir, fileNameFor(doc));
  if (!fs.existsSync(base)) return base;
  const existing = docIdOf(base);
  if (existing === null || existing === doc.id) return base;   // same Doc, or unknowable — reuse
  return base.replace(/\.md$/, `-${String(doc.id).slice(0, 6)}.md`);
}

/** YAML frontmatter, so a file can be traced back to its Doc without a lookup table. */
function frontmatter(doc) {
  const owner = (doc.owners && doc.owners[0] && doc.owners[0].emailAddress) || '';
  const esc = s => String(s).replace(/"/g, '\\"');
  return [
    '---',
    `title: "${esc(doc.name)}"`,
    `source: google-doc`,
    `doc_id: ${doc.id}`,
    doc.webViewLink ? `doc_url: ${doc.webViewLink}` : null,
    owner ? `owner: ${owner}` : null,
    doc.createdTime ? `created: ${doc.createdTime}` : null,
    doc.modifiedTime ? `modified: ${doc.modifiedTime}` : null,
    '---',
    '',
  ].filter(Boolean).join('\n');
}

function sinceIso(state, cfg) {
  const explicit = arg('--since');
  if (explicit) return new Date(explicit).toISOString();
  if (state.lastRun) return new Date(state.lastRun).toISOString();
  return new Date(Date.now() - cfg.driveSync.lookbackDays * 86400_000).toISOString();
}

async function main() {
  const cfg = config.load();

  if (RESET) {
    if (fs.existsSync(SYNC_STATE_FILE)) fs.unlinkSync(SYNC_STATE_FILE);
    say(`state cleared — next run looks back ${cfg.driveSync.lookbackDays} days`);
  }

  const outDir = cfg.driveSync.outputDir;
  const marker = arg('--marker', cfg.driveSync.titleContains);
  const state = readState();
  const seen = new Set(state.seen || []);
  const since = sinceIso(state, cfg);

  let exclude = null;
  const excludeSrc = arg('--exclude', cfg.driveSync.exclude || '');
  if (excludeSrc) {
    try { exclude = new RegExp(excludeSrc, 'i'); } catch (e) {
      say(`FAILED: exclude is not a valid regex: ${e.message}`);
      process.exit(2);
    }
    say(`exclude filter active: /${excludeSrc}/i`);
  }

  say(`${DRY ? 'DRY RUN — ' : ''}searching all drives for "${marker}" modified since ${since}`);
  const found = await listFiles(docQuery(marker, since));
  say(`Drive returned ${found.length} Doc(s)`);

  const queue = [];
  for (const f of found) {
    const owner = (f.owners && f.owners[0] && f.owners[0].emailAddress) || 'unknown';
    const dest = resolveDest(f, outDir);
    if (exclude && exclude.test(f.name)) { log(`SKIP  excluded       ${f.name}`); continue; }
    // `seen` is only a fast path. The file on disk is the real state, which is what makes a
    // hand-deleted state file harmless: the next run re-lists everything and skips what exists.
    if (!FORCE && fs.existsSync(dest)) { log(`SKIP  already on disk ${path.basename(dest)}`); seen.add(f.id); continue; }
    if (!FORCE && seen.has(f.id)) { log(`SKIP  already synced  ${f.name}`); continue; }
    queue.push({ doc: f, dest });
    log(`PULL  ${String(f.createdTime).slice(0, 10)}  ${owner.padEnd(28)}  ${f.name}`);
  }

  if (queue.length > cfg.driveSync.maxPerRun) {
    say(`WARNING: ${queue.length} Docs queued, capping at ${cfg.driveSync.maxPerRun} this run — rerun for the rest`);
    queue.length = cfg.driveSync.maxPerRun;
  }

  if (DRY) {
    say(`would write ${queue.length} file(s) into ${outDir}; nothing written, state untouched`);
    return;
  }

  if (!queue.length) {
    say(`nothing new; ${outDir} is up to date`);
    writeState({ lastRun: new Date().toISOString(), seen: [...seen].slice(-SEEN_CAP) });
    return;
  }

  fs.mkdirSync(outDir, { recursive: true });

  const written = [];
  const failed = [];
  for (const { doc, dest } of queue) {
    try {
      const md = await exportDoc(doc.id, 'text/markdown');
      // Temp file + rename, so a half-downloaded Doc is never visible as a note.
      const tmp = `${dest}.tmp.${process.pid}`;
      fs.writeFileSync(tmp, frontmatter(doc) + md);
      fs.renameSync(tmp, dest);
      written.push(path.basename(dest));
      seen.add(doc.id);
    } catch (e) {
      // One unreadable Doc must not cost the whole run — record it and carry on. Its id stays out
      // of `seen`, so the next run retries it.
      failed.push(doc.name);
      say(`ERROR exporting "${doc.name}": ${e.message}`);
    }
  }

  writeState({ lastRun: new Date().toISOString(), seen: [...seen].slice(-SEEN_CAP) });

  say(`wrote ${written.length} file(s) to ${outDir}${failed.length ? `; ${failed.length} failed` : ''}`);
  for (const name of written) log(`  ${name}`);
}

// Exported for test/; the require.main guard is what lets the test file import them without the
// module immediately trying to talk to Google.
module.exports = { fileNameFor, frontmatter, resolveDest, docIdOf };

if (require.main === module) {
  main().catch(err => { say(`FAILED: ${err.message}`); process.exit(1); });
}
