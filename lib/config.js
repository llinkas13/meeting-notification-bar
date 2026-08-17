'use strict';

/**
 * config.js — read config.json, fill in defaults, and resolve the timezone.
 *
 * The timezone is the one setting worth reading this file for, because getting it wrong is silent.
 * fetch-events.js asks the Calendar API for a day window; with no zone the window is built in UTC,
 * which in America/New_York runs from 8pm yesterday to 8pm today. Evening meetings vanish and
 * yesterday's evening meetings appear. Nothing errors.
 *
 * So: config → $TZ → whatever Intl says the system zone is. The last one always works on macOS,
 * which is why `timezone` in config.json is optional rather than required.
 */

const fs = require('fs');
const { CONFIG_FILE } = require('./paths');

const DEFAULTS = {
  calendarId: 'primary',
  timezone: '',
  driveSync: {
    enabled: false,
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

  cfg.timezone =
    cfg.timezone ||
    process.env.TZ ||
    Intl.DateTimeFormat().resolvedOptions().timeZone ||
    '';
  cfg.driveSync.outputDir = expandHome(cfg.driveSync.outputDir);

  return cfg;
}

module.exports = { load, DEFAULTS, expandHome };
