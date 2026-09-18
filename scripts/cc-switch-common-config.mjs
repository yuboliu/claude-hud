#!/usr/bin/env node
/**
 * cc-switch-common-config.mjs — keep claude-hud alive across provider switches
 * made with CC Switch (https://github.com/farion1231/cc-switch).
 *
 * CC Switch rewrites `~/.claude/settings.json` wholesale on every switch: it
 * writes only the new `env` + `model` block for the selected provider and drops
 * every other key, so `statusLine` and `enabledPlugins` disappear and the HUD
 * silently turns off.
 *
 * CC Switch can merge a shared "common config" (通用配置) into every switch
 * instead. This script copies the statusLine that is already working in
 * `settings.json` into that common config and turns the feature on for every
 * Claude provider, so a fresh machine plus this script reproduces the setup.
 *
 * What it changes in `~/.cc-switch/cc-switch.db`:
 *   - settings.common_config_claude.statusLine       = settings.json statusLine
 *   - settings.common_config_claude.enabledPlugins   = { "claude-hud@claude-hud": true }
 *   - providers.meta.commonConfigEnabled             = true   (app_type = "claude")
 * Other keys of the common config (theme, hooks, permissions, ...) and other
 * provider meta fields are preserved.
 *
 * Usage:
 *   node cc-switch-common-config.mjs [--db PATH] [--claude-dir DIR] [--check] [--verbose]
 *
 * Close CC Switch while this runs, then start it again so its UI picks up the
 * change; a save from a stale editor window would write the old config back.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const PLUGIN_ID = 'claude-hud@claude-hud';
const SETTINGS_KEY = 'common_config_claude';
const APP_TYPE = 'claude';

const USAGE_TEXT = `Usage: node cc-switch-common-config.mjs [options]

Options:
  --db PATH          CC Switch database (default: ~/.cc-switch/cc-switch.db)
  --claude-dir DIR   Claude config dir (default: $CLAUDE_CONFIG_DIR or ~/.claude)
  --check            Report what would change without writing
  --verbose          Print every step
  -h, --help         Show this help
`;

function parseArgs(argv) {
  const args = { db: '', claudeDir: '', check: false, verbose: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--db') args.db = argv[++i] ?? '';
    else if (arg === '--claude-dir') args.claudeDir = argv[++i] ?? '';
    else if (arg === '--check') args.check = true;
    else if (arg === '--verbose') args.verbose = true;
    else if (arg === '-h' || arg === '--help') args.help = true;
    else throw new Error(`unknown option: ${arg}`);
  }
  return args;
}

function log(message, verbose, args) {
  if (verbose || !args.verbose) {
    process.stdout.write(`${message}\n`);
  }
}

/**
 * Key order differs between writers (Claude Code rewrites settings.json and
 * reorders top-level keys), so compare values with sorted keys instead of
 * string equality — otherwise every run looks like a change.
 */
function normalize(object) {
  if (object === null || typeof object !== 'object' || Array.isArray(object)) return object;
  const out = {};
  for (const key of Object.keys(object).sort()) out[key] = object[key];
  return out;
}

function sameJson(a, b) {
  return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
}

function readJson(filePath, what) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    throw new Error(`cannot read ${what} at ${filePath}: ${err.message}`);
  }
  try {
    return JSON.parse(text.replace(/^\uFEFF/, ''));
  } catch (err) {
    throw new Error(`${what} at ${filePath} is not valid JSON: ${err.message}`);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(USAGE_TEXT);
    return;
  }

  const homeDir = os.homedir();
  const claudeDir = args.claudeDir
    || process.env.CLAUDE_CONFIG_DIR?.trim()
    || path.join(homeDir, '.claude');
  const settingsPath = path.join(claudeDir, 'settings.json');
  const dbPath = args.db || path.join(homeDir, '.cc-switch', 'cc-switch.db');

  if (!fs.existsSync(dbPath)) {
    process.stdout.write(`cc-switch-common-config: skipped — no CC Switch database at ${dbPath}\n`);
    return;
  }

  // The statusLine that already works in settings.json is the source of truth:
  // this script never builds a command of its own.
  const settings = readJson(settingsPath, 'Claude settings');
  const statusLine = settings?.statusLine;
  if (!statusLine || typeof statusLine !== 'object' || typeof statusLine.command !== 'string' || !statusLine.command) {
    throw new Error(`no statusLine.command in ${settingsPath}; install the HUD statusline first`);
  }

  const desiredStatusLine = { ...statusLine, type: 'command' };
  const db = new DatabaseSync(dbPath);

  try {
    const hasSettingsTable = db.prepare("select name from sqlite_master where type = 'table' and name = 'settings'").get();
    const hasProvidersTable = db.prepare("select name from sqlite_master where type = 'table' and name = 'providers'").get();
    if (!hasSettingsTable || !hasProvidersTable) {
      throw new Error(`${dbPath} does not look like a CC Switch database (settings/providers tables missing)`);
    }

    const row = db.prepare('select value from settings where key = ?').get(SETTINGS_KEY);
    const commonConfig = row?.value ? JSON.parse(row.value) : {};
    if (commonConfig === null || typeof commonConfig !== 'object' || Array.isArray(commonConfig)) {
      throw new Error(`${SETTINGS_KEY} is not a JSON object`);
    }

    const changes = [];
    if (!sameJson(commonConfig.statusLine ?? null, desiredStatusLine)) {
      changes.push(`${SETTINGS_KEY}.statusLine`);
    }
    if (commonConfig.enabledPlugins?.[PLUGIN_ID] !== true) {
      changes.push(`${SETTINGS_KEY}.enabledPlugins[${PLUGIN_ID}]`);
    }

    const providers = db.prepare('select id, name, meta from providers where app_type = ?').all(APP_TYPE);
    const providersToEnable = [];
    for (const provider of providers) {
      let meta = {};
      try {
        meta = provider.meta ? JSON.parse(provider.meta) : {};
      } catch {
        throw new Error(`provider ${provider.id} has unparseable meta JSON`);
      }
      if (meta === null || typeof meta !== 'object' || Array.isArray(meta)) meta = {};
      if (meta.commonConfigEnabled !== true) {
        providersToEnable.push({ id: provider.id, name: provider.name, meta: { ...meta, commonConfigEnabled: true } });
      }
    }

    if (changes.length === 0 && providersToEnable.length === 0) {
      process.stdout.write(`cc-switch-common-config: already configured (${SETTINGS_KEY}: statusLine + ${PLUGIN_ID}, ${providers.length} Claude provider(s))\n`);
      return;
    }

    const plan = [
      ...changes.map((c) => `set ${c}`),
      ...providersToEnable.map((p) => `enable common config for provider "${p.name}"`),
    ];
    if (args.check) {
      process.stdout.write(`cc-switch-common-config: would ${plan.join('; ')} (--check, nothing written)\n`);
      return;
    }

    const backupPath = `${dbPath}.bak.${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)}`;
    fs.copyFileSync(dbPath, backupPath);

    const nextCommonConfig = {
      ...commonConfig,
      statusLine: desiredStatusLine,
      enabledPlugins: { ...(commonConfig.enabledPlugins ?? {}), [PLUGIN_ID]: true },
    };

    db.exec('begin immediate');
    try {
      if (row) {
        db.prepare('update settings set value = ? where key = ?').run(JSON.stringify(nextCommonConfig, null, 2), SETTINGS_KEY);
      } else {
        db.prepare('insert into settings (key, value) values (?, ?)').run(SETTINGS_KEY, JSON.stringify(nextCommonConfig, null, 2));
      }
      for (const provider of providersToEnable) {
        db.prepare('update providers set meta = ? where id = ?').run(JSON.stringify(provider.meta), provider.id);
      }
      db.exec('commit');
    } catch (err) {
      db.exec('rollback');
      throw err;
    }

    process.stdout.write(`cc-switch-common-config: ${plan.join('; ')}\n`);
    process.stdout.write(`cc-switch-common-config: database backed up to ${backupPath}\n`);
    process.stdout.write('cc-switch-common-config: restart CC Switch so its editor does not write the old config back\n');
    if (args.verbose) {
      log(`cc-switch-common-config: db=${dbPath} settings=${settingsPath}`, true, args);
    }
  } finally {
    db.close();
  }
}

try {
  main();
} catch (err) {
  const busy = /SQLITE_BUSY|database is locked/i.test(String(err?.message ?? err));
  process.stderr.write(`cc-switch-common-config: ${err.message}${busy ? ' (close CC Switch and run again)' : ''}\n`);
  process.exit(1);
}
