'use strict';

/**
 * config.js — read config.json, fill in defaults, and resolve the timezone.
 *
 * The timezone always follows the Mac: $TZ if set, otherwise whatever Intl reports as the system
 * zone. It is not a config.json key — a user-set zone that drifted from the laptop's actual zone
 * is exactly the silent wrong-day bug this file used to warn about, so there is nothing to
 * override here anymore. fetch-events.js computes the day's date in this same zone, so the date
 * and the UTC offset it builds the request window from always agree.
 */

const fs = require('fs');
const { CONFIG_FILE } = require('./paths');

const DEFAULTS = {
  calendarId: 'primary',
  driveSync: {
    titleContains: 'Notes by Gemini',
    outputDir: '~/Documents/meeting-notes',
    lookbackDays: 30,
    maxPerRun: 60,
    exclude: '',
  },
};

function expandHome(p) {
  if (!p) return p;
  return p.startsWith('~') ? p.replace(/^~/, require('os').homedir()) : p;
}

function load() {
  let raw = {};
  if (fs.existsSync(CONFIG_FILE)) {
    try {
      raw = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    } catch (e) {
      throw new Error(`${CONFIG_FILE} is not valid JSON: ${e.message}`);
    }
  }

  const cfg = {
    ...DEFAULTS,
    ...raw,
    driveSync: { ...DEFAULTS.driveSync, ...(raw.driveSync || {}) },
  };

  cfg.timezone = process.env.TZ || Intl.DateTimeFormat().resolvedOptions().timeZone || '';
  cfg.driveSync.outputDir = expandHome(cfg.driveSync.outputDir);

  return cfg;
}

module.exports = { load, DEFAULTS, expandHome };
