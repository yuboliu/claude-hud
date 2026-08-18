#!/usr/bin/env bash
# install-fork.sh — install the yuboliu/claude-hud fork as a local Claude Code
# marketplace + plugin, wire up the statusLine, and optionally set up the
# Kimi For Coding usage feeder.
#
# Usage:
#   scripts/install-fork.sh [--local PATH] [--with-kimi] [--with-cron]
#
# Options:
#   --local PATH   Register the marketplace from a local clone of the fork
#                  instead of cloning yuboliu/claude-hud from GitHub.
#   --with-kimi    Install the Kimi For Coding usage feeder into the plugin
#                  data dir and point display.externalUsagePath at it.
#   --with-cron    Additionally install a crontab entry refreshing the Kimi
#                  snapshot every 3 minutes (implies --with-kimi).
#
# Idempotent: safe to re-run, e.g. after `git push` to refresh the installed
# copy from the marketplace clone.
set -euo pipefail

FORK_REPO="yuboliu/claude-hud"
MARKETPLACE_NAME="claude-hud"
PLUGIN_ID="claude-hud@claude-hud"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DATA_DIR="$CLAUDE_DIR/plugins/claude-hud"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOCAL_PATH=""
WITH_KIMI=0
WITH_CRON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL_PATH="${2:?--local needs a path}"; shift 2 ;;
    --with-kimi) WITH_KIMI=1; shift ;;
    --with-cron) WITH_CRON=1; WITH_KIMI=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log() { printf '==> %s\n' "$*"; }

# --- prerequisites -----------------------------------------------------------
command -v claude >/dev/null 2>&1 || { echo "error: claude CLI not found in PATH" >&2; exit 1; }
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "error: node not found in PATH" >&2; exit 1; }
log "claude: $(command -v claude)"
log "node:   $NODE_BIN"

# --- 1. marketplace: replace upstream registration with the fork -------------
# The fork's marketplace.json declares the same marketplace name ("claude-hud")
# as upstream, so the old registration must be removed first.
if claude plugin marketplace list 2>/dev/null | grep -q "$MARKETPLACE_NAME"; then
  log "removing existing marketplace registration: $MARKETPLACE_NAME"
  claude plugin marketplace remove "$MARKETPLACE_NAME" || true
fi

if [ -n "$LOCAL_PATH" ]; then
  log "adding marketplace from local path: $LOCAL_PATH"
  claude plugin marketplace add "$LOCAL_PATH"
else
  log "adding marketplace from GitHub: $FORK_REPO"
  claude plugin marketplace add "$FORK_REPO"
fi

# --- 2. plugin: (re)install from the fork marketplace ------------------------
log "(re)installing plugin: $PLUGIN_ID"
claude plugin uninstall "$PLUGIN_ID" 2>/dev/null || true
claude plugin install "$PLUGIN_ID"

# --- 3. statusLine: dynamic lookup into the plugin cache ---------------------
# Resolves plugins/cache/<marketplace>/claude-hud/<version>/ at runtime, so
# version bumps keep working without editing settings.json.
STATUSLINE_CMD=$(cat <<'CMDEOF'
bash -c 'cols=${COLUMNS:-}; case "$cols" in ""|*[!0-9]*) cols=$(stty size 2>/dev/null </dev/tty | awk '"'"'{print $2}'"'"');; esac; case "$cols" in ""|*[!0-9]*) cols=120;; esac; export COLUMNS=$(( cols > 4 ? cols - 4 : 1 )); plugin_dir=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-hud/*/ 2>/dev/null | awk -F/ '"'"'{ print $(NF-1) "\t" $(0) }'"'"' | grep -E '"'"'^[0-9]+\.[0-9]+\.[0-9]+[[:space:]]'"'"' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-); exec "__NODE_BIN__" "${plugin_dir}dist/index.js"'
CMDEOF
)
STATUSLINE_CMD="${STATUSLINE_CMD//__NODE_BIN__/$NODE_BIN}"

SETTINGS="$CLAUDE_DIR/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
log "settings backup created next to $SETTINGS"

STATUSLINE_CMD="$STATUSLINE_CMD" "$NODE_BIN" -e '
const fs = require("fs");
const p = process.argv[1];
const s = JSON.parse(fs.readFileSync(p, "utf8"));
s.statusLine = Object.assign({}, s.statusLine, {
  type: "command",
  command: process.env.STATUSLINE_CMD,
});
fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
' "$SETTINGS"
log "statusLine configured in $SETTINGS"

# --- 4. optional: Kimi For Coding usage feeder --------------------------------
if [ "$WITH_KIMI" -eq 1 ]; then
  mkdir -p "$DATA_DIR"
  cp "$REPO_ROOT/examples/external-usage/kimi-usage-snapshot.mjs" "$DATA_DIR/"
  chmod 700 "$DATA_DIR/kimi-usage-snapshot.mjs"
  log "kimi feeder installed to $DATA_DIR/kimi-usage-snapshot.mjs"

  CFG="$DATA_DIR/config.json"
  [ -f "$CFG" ] || echo '{}' > "$CFG"
  DATA_DIR="$DATA_DIR" "$NODE_BIN" -e '
const fs = require("fs");
const p = process.argv[1];
const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
cfg.display = Object.assign({}, cfg.display, {
  showUsage: true,
  sevenDayThreshold: 0,
  externalUsagePath: process.env.DATA_DIR + "/kimi-usage-snapshot.json",
  externalUsageFreshnessMs: 600000,
});
fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
' "$CFG"
  log "claude-hud config.json pointed at the kimi snapshot"

  if "$NODE_BIN" "$DATA_DIR/kimi-usage-snapshot.mjs"; then
    log "kimi snapshot refreshed"
  else
    echo "warning: initial kimi snapshot fetch failed (check ANTHROPIC_AUTH_TOKEN in settings.json); cron will retry" >&2
  fi
fi

# --- 5. optional: crontab refresh --------------------------------------------
if [ "$WITH_CRON" -eq 1 ]; then
  CRON_LINE="*/3 * * * * $NODE_BIN $DATA_DIR/kimi-usage-snapshot.mjs >> $DATA_DIR/kimi-usage.log 2>&1"
  ( crontab -l 2>/dev/null | grep -v "kimi-usage-snapshot" || true; echo "$CRON_LINE" ) | crontab -
  log "crontab entry installed: $CRON_LINE"
fi

# --- 6. verify ---------------------------------------------------------------
log "verifying installed statusline..."
if echo '{"model":{"display_name":"verify"}}' | sh -c "$STATUSLINE_CMD" >/dev/null 2>&1; then
  log "OK — HUD renders. It appears below the input field after your next message."
else
  echo "error: statusline smoke test failed; check $SETTINGS" >&2
  exit 1
fi
