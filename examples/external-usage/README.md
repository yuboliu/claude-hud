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

## usage-snapshot.mjs (multi-provider)

`kimi-usage-snapshot.mjs` is Kimi-only. `usage-snapshot.mjs` covers the case
where one machine switches Claude Code between providers: every run reads
`settings.json → env.ANTHROPIC_BASE_URL` and feeds whichever provider is
active, so switching providers needs no feeder change.

| Base URL host | Endpoint | Snapshot fields |
|---|---|---|
| `api.kimi.com` | `GET /coding/v1/usages` | `five_hour`, `seven_day` |
| `api.deepseek.com` | `GET /user/balance` | `balance_label` (e.g. `¥72.89`) |

Each snapshot also carries a `source` field (ignored by ClaudeHUD) so the
snapshot left behind by the *other* provider is never rendered as if it
belonged to the current one:

- success → snapshot overwritten with the current provider's data
- failure, same provider → previous snapshot kept (network blips don't flap the line)
- failure or unsupported provider, different provider → snapshot removed

### Setup

```bash
node usage-snapshot.mjs --verbose        # verify once
```

Then point ClaudeHUD at the snapshot and widen the freshness window:

```json
{
  "display": {
    "externalUsagePath": "C:\\Users\\<you>\\.claude\\plugins\\claude-hud\\usage-snapshot.json",
    "externalUsageFreshnessMs": 600000
  }
}
```

`externalUsagePath` must be absolute **and in the host OS path format**: under
Git Bash `$HOME` expands to `/c/Users/...`, which Node on Windows cannot read,
so write `C:\Users\...` there.

A custom base URL (proxy or gateway) can force the provider:

```bash
node usage-snapshot.mjs --provider kimi --base-url https://gateway.internal/kimi
```

### Windows: Task Scheduler without a flashing console window

Scheduling the `.mjs`, or a `.cmd` wrapper around it, makes Task Scheduler open
a **black console window on every run** — every 3 minutes, in the user's face.
`usage-snapshot-refresh.vbs` avoids that: `wscript.exe` is a GUI-subsystem host
that never allocates a console, and it starts the child hidden while keeping
the `>>` redirection that `schtasks /TR` cannot express.

```vbs
cmd = "cmd.exe /d /c " & q & q & nodeExe & q & " " & q & root & "\usage-snapshot.mjs" & q _
  & " >> " & q & root & "\usage-snapshot.log" & q & " 2>&1" & q
shell.Run cmd, 0, False      ' 0 = hidden window, False = don't wait
```

Install both files side by side and register the task:

```powershell
$d = "$env:USERPROFILE\.claude\plugins\claude-hud"
Copy-Item usage-snapshot.mjs, usage-snapshot-refresh.vbs $d
schtasks /Create /TN "claude-hud-usage-snapshot" /SC MINUTE /MO 3 `
  /TR "wscript.exe //B //Nologo `"$d\usage-snapshot-refresh.vbs`"" /F
schtasks /Run /TN "claude-hud-usage-snapshot"                          # run once now
schtasks /Query /TN "claude-hud-usage-snapshot" /FO LIST /V            # last result
schtasks /Change /TN "claude-hud-usage-snapshot" /DISABLE              # pause it
```

The launcher resolves its own folder, so the plugin directory can move freely,
and appends stdout/stderr to `usage-snapshot.log` next to it. Running the
feeder by hand should stay a plain command, where a console is expected:

```bash
node usage-snapshot.mjs --verbose
```

The switch takes effect on the next scheduled run, so for up to one interval
the HUD can still render the previous provider's snapshot.
