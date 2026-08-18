# External usage feeders

ClaudeHUD renders usage windows from the statusline stdin `rate_limits`
payload, which Claude Code only sends for Anthropic subscriber (OAuth)
sessions. When Claude Code runs against a third-party provider via
`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`, that payload is absent and
the usage line stays hidden.

The feeders in this directory close that gap: each is a small standalone
script that polls the provider's quota endpoint and writes a local
snapshot file in the shape ClaudeHUD reads via `display.externalUsagePath`.

## kimi-usage-snapshot.mjs

Feeds **Kimi For Coding** (`https://api.kimi.com/coding/`) token-plan
usage into ClaudeHUD — the same endpoint and response parsing as
[cc-switch](https://github.com/farion1231/cc-switch)'s
`coding_plan.rs::query_kimi`:

- `GET https://api.kimi.com/coding/v1/usages` with `Authorization: Bearer <token>`
- `limits[].detail` → five-hour window (`limit` / `remaining` / `resetTime`)
- `usage` → weekly window (`limit` / `remaining` / `resetTime`)

### Setup

1. Copy the script somewhere private and make it executable:

   ```bash
   mkdir -p ~/.claude/plugins/claude-hud
   cp kimi-usage-snapshot.mjs ~/.claude/plugins/claude-hud/
   chmod 700 ~/.claude/plugins/claude-hud/kimi-usage-snapshot.mjs
   ```

2. Run it once to verify (requires Node 18+; the token is read from
   `~/.claude/settings.json` → `env.ANTHROPIC_AUTH_TOKEN` and never printed):

   ```bash
   node ~/.claude/plugins/claude-hud/kimi-usage-snapshot.mjs
   # kimi-usage snapshot updated: 5h=49% (resets …) 7d=40% (resets …)
   ```

3. Point ClaudeHUD at the snapshot and widen the freshness window:

   ```json
   {
     "display": {
       "externalUsagePath": "/home/<you>/.claude/plugins/claude-hud/kimi-usage-snapshot.json",
       "externalUsageFreshnessMs": 600000
     }
   }
   ```

4. Refresh the snapshot on a schedule, e.g. cron every 3 minutes:

   ```cron
   */3 * * * * node ~/.claude/plugins/claude-hud/kimi-usage-snapshot.mjs >> ~/.claude/plugins/claude-hud/kimi-usage.log 2>&1
   ```

The HUD then shows the provider windows on line 2, e.g.:

```
Context ░░░░░░░░░░ 0% │ Usage █████░░░░░ 49% (resets in 3h 39m) | Weekly ████░░░░░░ 40% (resets in 6d)
```

### Failure behavior

On any error (network, 401/403, unexpected response) the script exits
non-zero and keeps the previous snapshot. ClaudeHUD quietly ignores
snapshots older than `externalUsageFreshnessMs`, so a stale feed hides the
usage line instead of showing wrong data. Check the log first; the most
common cause is an expired token (HTTP 401).
