<#
.SYNOPSIS
  One-command install of the yuboliu/claude-hud fork on Windows.

.DESCRIPTION
  Reproduces every piece of the fork setup on a fresh machine:

    1. registers the fork marketplace and (re)installs + enables the plugin
    2. writes the statusLine (Git Bash flavour, plus refreshInterval) into
       %CLAUDE_CONFIG_DIR%\settings.json, with a timestamped backup
    3. installs the multi-provider usage feeder, points the HUD at its snapshot
       and schedules it through Task Scheduler using the hidden .vbs launcher
       (no console window flashes)
    4. copies the working statusLine into CC Switch's shared common config so
       provider switches stop wiping it (scripts/cc-switch-common-config.mjs)

  Every step is idempotent: re-run it after a git pull to refresh what changed.
  Nothing is written with a UTF-8 BOM, and settings.json keeps every key it
  already has.

.PARAMETER MarketplaceSource
  Marketplace to register, default yuboliu/claude-hud. Pass a local clone path
  or an https URL to install from somewhere else.

.PARAMETER ClaudeDir
  Claude config directory, default $env:CLAUDE_CONFIG_DIR or $HOME\.claude.

.PARAMETER RefreshInterval
  statusLine refreshInterval in seconds, default 5.

.PARAMETER FeederIntervalMinutes
  How often Task Scheduler refreshes the usage snapshot, default 3.

.PARAMETER SkipFeeder
  Do not install or schedule the usage feeder.

.PARAMETER SkipCCSwitch
  Do not touch the CC Switch database even when it is present.

.PARAMETER SkipSmokeTest
  Do not run the statusLine smoke test at the end.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-fork.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-fork.ps1 -SkipFeeder
#>
[CmdletBinding()]
param(
    [string]$MarketplaceSource = 'yuboliu/claude-hud',
    [string]$ClaudeDir = '',
    [int]$RefreshInterval = 5,
    [int]$FeederIntervalMinutes = 3,
    [switch]$SkipFeeder,
    [switch]$SkipCCSwitch,
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$PluginId = 'claude-hud@claude-hud'
$MarketplaceName = 'claude-hud'
$FeederTaskName = 'claude-hud-usage-snapshot'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" }
function Write-Skip([string]$Message) { Write-Host "    - $Message" -ForegroundColor DarkGray }

# Windows PowerShell 5.1 turns native stderr into a terminating error while
# $ErrorActionPreference is 'Stop', which would abort on harmless messages such
# as 'claude plugin enable' reporting 'already enabled'. Capture through
# 'Continue' and decide from the exit code instead.
function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $Executable @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Output = $output.Trim(); ExitCode = $code }
}

function Show-NativeOutput([string]$Output) {
    foreach ($line in ($Output -split "`r?`n")) {
        if ($line.Trim().Length -gt 0) { Write-Note $line.Trim() }
    }
}

function Get-GitBashPath {
    $candidates = @()
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
        $candidates += (Join-Path $gitRoot 'bin\bash.exe')
    }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return ''
}

# Claude Code runs statusLine commands through Git Bash on Windows, so the
# runtime path embedded in the command has to be the MSYS form.
function ConvertTo-BashPath([string]$WindowsPath) {
    if ($WindowsPath -match '^([A-Za-z]):[\\/](.*)$') {
        return '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
    }
    return ($WindowsPath -replace '\\', '/')
}

function New-StatusLineCommand([string]$NodeBashPath) {
    $runtime = $NodeBashPath
    if ($runtime -match '\s') { $runtime = '"' + $runtime + '"' }
    return 'cols=${COLUMNS:-}; ' +
        'case "$cols" in ""|*[!0-9]*) cols=$(stty size 2>/dev/null </dev/tty | awk ''{print $2}'');; esac; ' +
        'case "$cols" in ""|*[!0-9]*) cols=120;; esac; ' +
        'export COLUMNS=$(( cols > 4 ? cols - 4 : 1 )); ' +
        'plugin_dir=$(ls -1d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-hud/*/ 2>/dev/null | sort -V | tail -1); ' +
        'exec ' + $runtime + ' "${plugin_dir}dist/index.js"'
}

function Register-HudTask([string]$TaskName, [string]$VbsPath, [int]$Minutes, [string]$Description) {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "{0}"' -f $VbsPath)
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $taskSettings -Description $Description -Force | Out-Null
    Write-Note ("scheduled task '{0}' every {1} minute(s)" -f $TaskName, $Minutes)
}

# 'claude plugin list' prints 'Status: <check> enabled' or 'Status: <cross> disabled'.
function Test-PluginEnabled([string]$PluginListOutput) {
    if ($PluginListOutput -notmatch [regex]::Escape($PluginId)) { return $false }
    foreach ($line in ($PluginListOutput -split "`r?`n")) {
        if ($line -match 'Status:' -and $line -match 'enabled' -and $line -notmatch 'disabled') { return $true }
    }
    return $false
}

# --- 0. prerequisites --------------------------------------------------------
Write-Step 'checking prerequisites'
$ClaudeCmd = 'claude'
$cmdShim = Get-Command claude.cmd -ErrorAction SilentlyContinue
if ($cmdShim) { $ClaudeCmd = $cmdShim.Source }
if (-not (Get-Command $ClaudeCmd -ErrorAction SilentlyContinue) -and -not $cmdShim) {
    throw 'claude CLI not found in PATH'
}
$nodePath = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $nodePath) { $nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source }
if (-not $nodePath) { throw 'Node.js not found in PATH (install Node.js LTS first)' }
$bashPath = Get-GitBashPath
if (-not $bashPath) { throw 'Git Bash not found (install Git for Windows; Claude Code needs it for statusLine commands)' }

$nodeBashPath = ConvertTo-BashPath $nodePath
$statusLineCommand = New-StatusLineCommand $nodeBashPath
Write-Note "claude: $ClaudeCmd"
Write-Note "node:   $nodeBashPath"
Write-Note "bash:   $bashPath"

if (-not $ClaudeDir) {
    if ($env:CLAUDE_CONFIG_DIR) { $ClaudeDir = $env:CLAUDE_CONFIG_DIR } else { $ClaudeDir = Join-Path $HOME '.claude' }
}
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$PluginDataDir = Join-Path (Join-Path $ClaudeDir 'plugins') 'claude-hud'
Write-Note "claude dir: $ClaudeDir"

# --- 1. marketplace + plugin -------------------------------------------------
Write-Step 'registering marketplace and plugin'
$listResult = Invoke-Native $ClaudeCmd @('plugin', 'marketplace', 'list')
if ($listResult.ExitCode -ne 0) { throw "claude plugin marketplace list failed: $($listResult.Output)" }
$marketplaces = $listResult.Output

if ($marketplaces -match [regex]::Escape($MarketplaceSource)) {
    Write-Skip "marketplace already points at $MarketplaceSource"
} else {
    if ($marketplaces -match [regex]::Escape($MarketplaceName)) {
        Write-Note "removing the existing '$MarketplaceName' registration (upstream or stale source)"
        Invoke-Native $ClaudeCmd @('plugin', 'marketplace', 'remove', $MarketplaceName) | Out-Null
    }
    $addResult = Invoke-Native $ClaudeCmd @('plugin', 'marketplace', 'add', $MarketplaceSource)
    if ($addResult.ExitCode -ne 0) { throw "claude plugin marketplace add failed for ${MarketplaceSource}: $($addResult.Output)" }
    Write-Note "marketplace added: $MarketplaceSource"
}

$listResult = Invoke-Native $ClaudeCmd @('plugin', 'list')
if ($listResult.ExitCode -ne 0) { throw "claude plugin list failed: $($listResult.Output)" }
$plugins = $listResult.Output

if ($plugins -match [regex]::Escape($PluginId)) {
    Write-Skip "$PluginId already installed"
} else {
    $installResult = Invoke-Native $ClaudeCmd @('plugin', 'install', $PluginId, '-y')
    if ($installResult.ExitCode -ne 0) { throw "claude plugin install failed for ${PluginId}: $($installResult.Output)" }
    Write-Note "installed $PluginId"
}

if (Test-PluginEnabled $plugins) {
    Write-Skip "$PluginId already enabled"
} else {
    $enableResult = Invoke-Native $ClaudeCmd @('plugin', 'enable', $PluginId)
    if ($enableResult.ExitCode -ne 0 -and $enableResult.Output -notmatch 'already enabled') {
        throw "claude plugin enable failed for ${PluginId}: $($enableResult.Output)"
    }
    Write-Note "$PluginId enabled"
}

# --- 2. statusLine -----------------------------------------------------------
Write-Step 'configuring the statusLine'
if (Test-Path $SettingsPath) {
    $backup = '{0}.bak.{1}' -f $SettingsPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $SettingsPath $backup -Force
    Write-Note "settings backed up to $backup"
} else {
    Set-Content -Path $SettingsPath -Value '{}' -Encoding ascii
    Write-Note "created $SettingsPath"
}

$statusLineJson = @{
    type = 'command'
    command = $statusLineCommand
    refreshInterval = $RefreshInterval
} | ConvertTo-Json -Compress
$env:HUD_STATUSLINE_JSON = $statusLineJson
$mergeSettingsJs = @'
const fs = require('fs');
const settingsPath = process.argv[1];
const patch = JSON.parse(process.env.HUD_STATUSLINE_JSON);
const text = fs.readFileSync(settingsPath, 'utf8');
const settings = JSON.parse(text.replace(/^\uFEFF/, ''));
settings.statusLine = Object.assign({}, settings.statusLine, patch);
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
console.log('statusLine written (refreshInterval ' + patch.refreshInterval + ')');
'@
$mergeResult = Invoke-Native $nodePath @('-e', $mergeSettingsJs, $SettingsPath)
Remove-Item Env:HUD_STATUSLINE_JSON -ErrorAction SilentlyContinue
if ($mergeResult.ExitCode -ne 0) { throw "failed to write the statusLine into ${SettingsPath}: $($mergeResult.Output)" }
Show-NativeOutput $mergeResult.Output

# --- 3. usage feeder + scheduled task ---------------------------------------
if ($SkipFeeder) {
    Write-Step 'usage feeder skipped (-SkipFeeder)'
} else {
    Write-Step 'installing the multi-provider usage feeder'
    New-Item -ItemType Directory -Force -Path $PluginDataDir | Out-Null
    $examplesDir = Join-Path $RepoRoot 'examples\external-usage'
    $feederSource = Join-Path $examplesDir 'usage-snapshot.mjs'
    $launcherSource = Join-Path $examplesDir 'usage-snapshot-refresh.vbs'
    if (-not (Test-Path $feederSource) -or -not (Test-Path $launcherSource)) {
        throw "feeder sources not found under $examplesDir"
    }
    Copy-Item $feederSource (Join-Path $PluginDataDir 'usage-snapshot.mjs') -Force
    Copy-Item $launcherSource (Join-Path $PluginDataDir 'usage-snapshot-refresh.vbs') -Force
    Write-Note "feeder + hidden launcher copied to $PluginDataDir"

    $snapshotPath = Join-Path $PluginDataDir 'usage-snapshot.json'
    $configPath = Join-Path $PluginDataDir 'config.json'
    $feederConfig = @{
        showUsage = $true
        sevenDayThreshold = 0
        externalUsagePath = $snapshotPath
        externalUsageFreshnessMs = 600000
    } | ConvertTo-Json -Compress
    $env:HUD_CONFIG_JSON = $feederConfig
    $mergeConfigJs = @'
const fs = require('fs');
const configPath = process.argv[1];
const patch = JSON.parse(process.env.HUD_CONFIG_JSON);
let config = {};
try { config = JSON.parse(fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, '')); } catch (err) { config = {}; }
config.display = Object.assign({}, config.display, patch);
fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
console.log('config.json updated');
'@
    $configResult = Invoke-Native $nodePath @('-e', $mergeConfigJs, $configPath)
    Remove-Item Env:HUD_CONFIG_JSON -ErrorAction SilentlyContinue
    if ($configResult.ExitCode -ne 0) { throw "failed to write ${configPath}: $($configResult.Output)" }
    Write-Note "config.json points display.externalUsagePath at $snapshotPath"

    $feederVbs = Join-Path $PluginDataDir 'usage-snapshot-refresh.vbs'
    Register-HudTask -TaskName $FeederTaskName -VbsPath $feederVbs -Minutes $FeederIntervalMinutes -Description 'claude-hud usage snapshot refresh (hidden window)'

    Write-Note 'running the feeder once...'
    $feederResult = Invoke-Native $nodePath @((Join-Path $PluginDataDir 'usage-snapshot.mjs'))
    Show-NativeOutput $feederResult.Output
    if ($feederResult.ExitCode -eq 0) {
        Write-Note 'snapshot written'
    } else {
        Write-Host '    ! the feeder could not reach the provider yet (missing or expired token?) - the scheduled task will retry' -ForegroundColor Yellow
    }
}

# --- 4. CC Switch common config ---------------------------------------------
if ($SkipCCSwitch) {
    Write-Step 'CC Switch common config skipped (-SkipCCSwitch)'
} else {
    Write-Step 'mirroring the statusLine into the CC Switch common config'
    $ccSwitchScript = Join-Path (Join-Path $RepoRoot 'scripts') 'cc-switch-common-config.mjs'
    $ccSwitchResult = Invoke-Native $nodePath @($ccSwitchScript, '--claude-dir', $ClaudeDir)
    Show-NativeOutput $ccSwitchResult.Output
    if ($ccSwitchResult.ExitCode -ne 0) {
        Write-Host '    ! could not update the CC Switch database (close CC Switch and re-run this script)' -ForegroundColor Yellow
    }
}

# --- 5. smoke test ----------------------------------------------------------
if ($SkipSmokeTest) {
    Write-Step 'smoke test skipped (-SkipSmokeTest)'
} else {
    Write-Step 'smoke testing the statusLine'
    $payload = '{"model":{"display_name":"verify"},"context_window":{"current_usage":{"input_tokens":45000},"context_window_size":200000},"cwd":"' + ($PWD.Path -replace '\\', '/') + '"}'
    # Hand the command to bash as a file: passing it as an argument would need
    # the embedded quotes to survive PowerShell's native-argument quoting, which
    # Windows PowerShell 5.1 does not do reliably.
    $smokeScript = Join-Path $env:TEMP ('claude-hud-statusline-smoke-' + [guid]::NewGuid().ToString('N') + '.sh')
    [System.IO.File]::WriteAllText($smokeScript, $statusLineCommand + "`n", (New-Object System.Text.UTF8Encoding $false))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = $payload | & $bashPath $smokeScript 2>&1 | Out-String
        $smokeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        Remove-Item $smokeScript -Force -ErrorAction SilentlyContinue
    }
    if ($smokeExit -ne 0 -or $output.Trim().Length -eq 0) {
        throw 'the statusLine command produced no output; check the plugin cache and the node path'
    }
    Write-Note 'statusLine renders:'
    Show-NativeOutput $output
}

# --- 6. summary --------------------------------------------------------------
Write-Step 'done'
Write-Note "settings:  $SettingsPath"
Write-Note "plugin:    $PluginId (user scope, enabled)"
if (-not $SkipFeeder) {
    Write-Note "feeder:    $PluginDataDir\usage-snapshot.mjs + task '$FeederTaskName' every $FeederIntervalMinutes min"
    Write-Note "           log: $PluginDataDir\usage-snapshot.log"
}
Write-Host ''
Write-Host 'The HUD appears below the input field after your next interaction.'
Write-Host 'If it does not show up, restart Claude Code.'
Write-Host ''
Write-Host 'Useful afterwards:'
Write-Host "  schtasks /Query  /TN `"$FeederTaskName`" /FO LIST /V"
Write-Host "  schtasks /Change /TN `"$FeederTaskName`" /DISABLE"
Write-Host "  node `"$PluginDataDir\usage-snapshot.mjs`" --verbose"
