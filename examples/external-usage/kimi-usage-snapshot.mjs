#!/usr/bin/env node
/**
 * Kimi For Coding usage feeder for claude-hud.
 *
 * Mirrors cc-switch's query_kimi() (src-tauri/src/services/coding_plan.rs):
 *   GET https://api.kimi.com/coding/v1/usages  (Authorization: Bearer <token>)
 *   - limits[].detail  -> five-hour window  { limit, remaining, resetTime }
 *   - usage            -> weekly window     { limit, remaining, resetTime }
 *
 * Writes a claude-hud external-usage snapshot to
 *   ~/.claude/plugins/claude-hud/kimi-usage-snapshot.json
 * in the exact shape claude-hud writes itself:
 *   { updated_at, five_hour: {used_percentage, resets_at},
 *     seven_day: { used_percentage, resets_at } }
 *
 * The token is read from ~/.claude/settings.json env.ANTHROPIC_AUTH_TOKEN
 * and is never printed. On any failure the previous snapshot is kept and
 * the exit code is non-zero (claude-hud quietly ignores stale files).
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const SETTINGS_PATH = path.join(CLAUDE_DIR, 'settings.json');
const SNAPSHOT_PATH = path.join(CLAUDE_DIR, 'plugins', 'claude-hud', 'kimi-usage-snapshot.json');
const USAGES_URL = 'https://api.kimi.com/coding/v1/usages';
const TIMEOUT_MS = 15000;

function readToken() {
  const settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
  const token = settings?.env?.ANTHROPIC_AUTH_TOKEN;
  if (typeof token !== 'string' || token.length === 0) {
    throw new Error('env.ANTHROPIC_AUTH_TOKEN missing in settings.json');
  }
  return token;
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

function num(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const n = Number.parseFloat(value);
    return Number.isFinite(n) ? n : null;
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

async function main() {
  const token = readToken();
  const resp = await fetch(USAGES_URL, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (resp.status === 401 || resp.status === 403) {
    throw new Error(`Kimi auth failed (HTTP ${resp.status}) — token expired?`);
  }
  if (!resp.ok) {
    throw new Error(`Kimi usages API error (HTTP ${resp.status})`);
  }
  const body = await resp.json();

  // Five-hour windows: limits[].detail — if several, surface the busiest one
  let fiveHour = null;
  const limits = Array.isArray(body?.limits) ? body.limits : [];
  for (const item of limits) {
    const w = windowFrom(item?.detail);
    if (w && (!fiveHour || w.used_percentage > fiveHour.used_percentage)) fiveHour = w;
  }

  // Weekly window: body.usage
  const sevenDay = windowFrom(body?.usage);

  if (!fiveHour && !sevenDay) {
    throw new Error('No usage windows found in Kimi response');
  }

  const snapshot = {
    updated_at: new Date().toISOString(),
    five_hour: fiveHour ?? { used_percentage: null, resets_at: null },
    seven_day: sevenDay ?? { used_percentage: null, resets_at: null },
  };

  fs.mkdirSync(path.dirname(SNAPSHOT_PATH), { recursive: true });
  const tmp = SNAPSHOT_PATH + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(snapshot, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, SNAPSHOT_PATH);

  // Safe summary (no token, no absolute quota values beyond percentages)
  const fmt = (w) => (w ? `${w.used_percentage}% (resets ${w.resets_at ?? '?'})` : 'n/a');
  console.log(`kimi-usage snapshot updated: 5h=${fmt(fiveHour)} 7d=${fmt(sevenDay)}`);
}

main().catch((err) => {
  console.error(`kimi-usage-snapshot: ${err.message}`);
  process.exit(1);
});
