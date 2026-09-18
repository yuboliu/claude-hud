#!/usr/bin/env node
/**
 * Multi-provider usage feeder for claude-hud.
 *
 * Claude Code only sends `rate_limits` on the statusline stdin payload for
 * Anthropic subscriber sessions. When it runs against a third-party provider
 * (`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`), that payload is absent and
 * the usage line stays hidden. This feeder polls whichever provider the
 * current settings.json points at and writes one local snapshot in the shape
 * ClaudeHUD reads via `display.externalUsagePath`:
 *
 *   { updated_at, five_hour: { used_percentage, resets_at },
 *     seven_day: { used_percentage, resets_at } }   // kimi
 *   { updated_at, balance_label: "¥110.00" }        // deepseek
 *
 * Supported providers, selected from `settings.json → env.ANTHROPIC_BASE_URL`:
 *   - Kimi For Coding  (api.kimi.com)   GET /coding/v1/usages        → 5h/7d windows
 *   - DeepSeek         (api.deepseek.com) GET /user/balance          → balance label
 *
 * Switching providers in Claude Code needs no feeder change: the next run
 * follows `ANTHROPIC_BASE_URL`, and a snapshot left behind by the *other*
 * provider is dropped instead of being rendered as if it belonged to the
 * current one. On any failure the previous snapshot is kept only when it came
 * from the same provider.
 *
 * Token: read from `settings.json → env.ANTHROPIC_AUTH_TOKEN` and never printed.
 * Exit code: 0 on success (or when the provider is unsupported), non-zero on failure.
 *
 * Usage:
 *   node usage-snapshot.mjs [--base-url URL] [--out PATH] [--verbose]
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR?.trim() || path.join(os.homedir(), '.claude');
const SETTINGS_PATH = path.join(CLAUDE_DIR, 'settings.json');
const DEFAULT_SNAPSHOT_PATH = path.join(CLAUDE_DIR, 'plugins', 'claude-hud', 'usage-snapshot.json');
const TIMEOUT_MS = 15000;

const CURRENCY_SYMBOLS = { CNY: '¥', USD: '$', EUR: '€' };

const USAGE_TEXT = `Usage: node usage-snapshot.mjs [options]

Options:
  --base-url URL   Provider base URL to use instead of settings.json
  --provider NAME  Force the provider (kimi, deepseek) for custom base URLs
  --out PATH       Snapshot path to write (default: ${DEFAULT_SNAPSHOT_PATH})
  --verbose        Print the settings path and detected provider
  -h, --help       Show this help

Reads the token from settings.json -> env.ANTHROPIC_AUTH_TOKEN.
Windows: schedule it every few minutes with Task Scheduler, e.g.
  schtasks /Create /TN "claude-hud-usage" /SC MINUTE /MO 3 /TR "<node.exe> <this file>"
`;

// Filled in by main() so the failure path knows what it was operating on.
const resolved = { snapshotPath: DEFAULT_SNAPSHOT_PATH, provider: null };

function parseArgs(argv) {
  const parsed = { baseUrl: '', provider: '', out: '', verbose: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--base-url') parsed.baseUrl = argv[++i] ?? '';
    else if (arg === '--provider') parsed.provider = argv[++i] ?? '';
    else if (arg === '--out') parsed.out = argv[++i] ?? '';
    else if (arg === '--verbose') parsed.verbose = true;
    else if (arg === '-h' || arg === '--help') parsed.help = true;
    else throw new Error(`unknown option: ${arg}`);
  }
  if (parsed.provider && !['kimi', 'deepseek'].includes(parsed.provider)) {
    throw new Error(`unknown provider: ${parsed.provider} (expected kimi or deepseek)`);
  }
  return parsed;
}

function readSettings() {
  try {
    return JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
  } catch (err) {
    throw new Error(`cannot read ${SETTINGS_PATH}: ${err.message}`);
  }
}

/** Never echo URL credentials (user:pass@host) into the log. */
function safeUrl(baseUrl) {
  try {
    const url = new URL(baseUrl);
    return url.username || url.password
      ? `${url.protocol}//${url.host}${url.pathname}`
      : baseUrl;
  } catch {
    return baseUrl;
  }
}

/**
 * Strip userinfo from anything that looks like a URL before it reaches the log.
 * Node's own fetch errors quote the request URL verbatim
 * ("Request cannot be constructed from a URL that includes credentials: ..."),
 * so a base URL carrying a token would otherwise be written to the log file.
 */
function redact(text) {
  return String(text).replace(/([a-z][a-z0-9+.-]*:\/\/)[^\s/?#@]*@/gi, '$1[redacted]@');
}

function detectProvider(baseUrl) {
  let host;
  try {
    host = new URL(baseUrl).hostname.toLowerCase();
  } catch {
    return null;
  }
  if (host === 'kimi.com' || host.endsWith('.kimi.com')) return 'kimi';
  if (host === 'deepseek.com' || host.endsWith('.deepseek.com')) return 'deepseek';
  return null;
}

async function getJson(url, token) {
  const resp = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (resp.status === 401 || resp.status === 403) {
    throw new Error(`auth failed (HTTP ${resp.status}) — token rejected by ${new URL(url).hostname}`);
  }
  if (!resp.ok) {
    throw new Error(`API error (HTTP ${resp.status}) at ${new URL(url).hostname}`);
  }
  return resp.json();
}

function num(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const n = Number.parseFloat(value);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

// resetTime comes as ISO string or epoch (seconds or milliseconds)
function toIso(value) {
  if (typeof value === 'string' && value.length > 0) {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }
  if (typeof value === 'number' && value > 0) {
    const ms = value < 1e12 ? value * 1000 : value;
    return new Date(ms).toISOString();
  }
  return null;
}

function windowFrom(detail) {
  if (!detail || typeof detail !== 'object') return null;
  const limit = num(detail.limit) ?? 1;
  const remaining = num(detail.remaining) ?? 0;
  const used = Math.max(0, limit - remaining);
  const usedPct = limit > 0 ? (used / limit) * 100 : 0;
  return {
    used_percentage: Math.round(usedPct * 10) / 10,
    resets_at: toIso(detail.resetTime),
  };
}

/** Kimi For Coding: limits[].detail → 5h window (busiest one), usage → weekly. */
async function fetchKimi(baseUrl, token) {
  const body = await getJson(new URL('/coding/v1/usages', baseUrl).href, token);

  let fiveHour = null;
  for (const item of Array.isArray(body?.limits) ? body.limits : []) {
    const w = windowFrom(item?.detail);
    if (w && (!fiveHour || w.used_percentage > fiveHour.used_percentage)) fiveHour = w;
  }
  const sevenDay = windowFrom(body?.usage);

  if (!fiveHour && !sevenDay) {
    throw new Error('no usage windows found in Kimi response');
  }
  return {
    five_hour: fiveHour ?? { used_percentage: null, resets_at: null },
    seven_day: sevenDay ?? { used_percentage: null, resets_at: null },
    summary: `5h=${pct(fiveHour)} 7d=${pct(sevenDay)}`,
  };
}

/** DeepSeek: balance_infos[] → "¥110.00" (claude-hud's balance_label slot). */
async function fetchDeepseek(baseUrl, token) {
  const body = await getJson(new URL('/user/balance', baseUrl).href, token);
  const infos = Array.isArray(body?.balance_infos) ? body.balance_infos : [];
  const info = infos.find((i) => (i?.currency ?? '').toUpperCase() === 'CNY') ?? infos[0];
  if (!info) {
    throw new Error('no balance_infos found in DeepSeek response');
  }
  const amount = num(info.total_balance) ?? num(info.topped_up_balance);
  if (amount === null) {
    throw new Error('no total_balance found in DeepSeek response');
  }
  const currency = typeof info.currency === 'string' ? info.currency.toUpperCase() : '';
  const text = amount.toFixed(2);
  const symbol = CURRENCY_SYMBOLS[currency];
  const label = symbol ? `${symbol}${text}` : currency ? `${text} ${currency}` : text;
  return { balance_label: label, summary: `balance=${label}` };
}

function pct(w) {
  return w ? `${w.used_percentage}%` : 'n/a';
}

function readSnapshotSource(snapshotPath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));
    return typeof parsed?.source === 'string' ? parsed.source : null;
  } catch {
    return null;
  }
}

function writeSnapshot(snapshotPath, payload) {
  fs.mkdirSync(path.dirname(snapshotPath), { recursive: true });
  const tmp = `${snapshotPath}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, snapshotPath);
}

function dropForeignSnapshot(snapshotPath, provider) {
  const previous = readSnapshotSource(snapshotPath);
  if (previous === null || previous === provider) {
    return previous;
  }
  fs.rmSync(snapshotPath, { force: true });
  return previous;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(USAGE_TEXT);
    return;
  }

  const snapshotPath = args.out || DEFAULT_SNAPSHOT_PATH;
  const settings = readSettings();
  const baseUrl = args.baseUrl || settings?.env?.ANTHROPIC_BASE_URL || '';
  const provider = args.provider || detectProvider(baseUrl);

  resolved.snapshotPath = snapshotPath;
  resolved.provider = provider;
  if (args.verbose) {
    process.stdout.write(`usage-snapshot: settings=${SETTINGS_PATH} base_url=${safeUrl(baseUrl) || '(none)'} provider=${provider ?? 'unsupported'}\n`);
  }

  if (!provider) {
    const dropped = dropForeignSnapshot(snapshotPath, null);
    const detail = baseUrl ? `base URL ${baseUrl}` : 'no ANTHROPIC_BASE_URL in settings.json';
    process.stdout.write(dropped
      ? `usage-snapshot: unsupported provider (${detail}); dropped stale ${dropped} snapshot\n`
      : `usage-snapshot: unsupported provider (${detail}); nothing to do\n`);
    return;
  }

  const token = settings?.env?.ANTHROPIC_AUTH_TOKEN;
  if (typeof token !== 'string' || token.length === 0) {
    throw new Error('env.ANTHROPIC_AUTH_TOKEN missing in settings.json');
  }

  const data = provider === 'kimi'
    ? await fetchKimi(baseUrl, token)
    : await fetchDeepseek(baseUrl, token);

  const { summary, ...fields } = data;
  writeSnapshot(snapshotPath, {
    updated_at: new Date().toISOString(),
    source: provider,
    ...fields,
  });
  process.stdout.write(`usage-snapshot[${provider}]: updated ${summary}\n`);
}

main().catch((err) => {
  const { snapshotPath, provider } = resolved;
  const previous = readSnapshotSource(snapshotPath);
  if (previous !== null && previous !== provider) {
    fs.rmSync(snapshotPath, { force: true });
    process.stderr.write(`usage-snapshot: dropped stale ${previous} snapshot (current provider: ${provider ?? 'unknown'})\n`);
  } else if (previous !== null) {
    process.stderr.write('usage-snapshot: keeping previous snapshot\n');
  }
  process.stderr.write(`${redact(`usage-snapshot[${provider ?? 'unknown'}]: ${err.message}`)}\n`);
  process.exit(1);
});
