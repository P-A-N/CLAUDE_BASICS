<#
.SYNOPSIS
  Claude Code 開発環境に必要なツールを一括インストールする（Windows / winget + npm）。

.DESCRIPTION
  以下を「入っていなければ入れる」方式でセットアップする:

    winget: Git / Python 3 / Node.js LTS / GitHub CLI (gh) / jq / uv / PowerShell 7(任意)
    npm -g: Claude Code (@anthropic-ai/claude-code) / Codex CLI (@openai/codex)

  既にコマンドが PATH にあるものはスキップする（-Force で再インストール）。
  winget 本体は Windows 10 1809+ に標準搭載。無い場合は Microsoft Store の
  「アプリ インストーラー」を先に入れること。

.PARAMETER DryRun
  何を入れるかだけ表示して、実際にはインストールしない。

.PARAMETER Skip
  スキップしたいツール名（Key 列）。例: -Skip python,node

.PARAMETER Only
  指定したツールだけ処理する。

.PARAMETER IncludeOptional
  任意扱いのツール（pwsh）も入れる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File claude-basics/setup/install_tools.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File claude-basics/setup/install_tools.ps1
  powershell -ExecutionPolicy Bypass -File claude-basics/setup/install_tools.ps1 -Only codex
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string[]]$Skip = @(),
    [string[]]$Only = @(),
    [switch]$IncludeOptional,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Key / 表示名 / 検出コマンド / インストール方法 / パッケージ ID / 任意フラグ
$tools = @(
    [pscustomobject]@{ Key = 'git';    Name = 'Git';            Probe = 'git';    Via = 'winget'; Id = 'Git.Git';                     Optional = $false }
    [pscustomobject]@{ Key = 'python'; Name = 'Python 3';       Probe = 'python'; Via = 'winget'; Id = 'Python.Python.3.13';          Optional = $false }
    [pscustomobject]@{ Key = 'node';   Name = 'Node.js LTS';    Probe = 'node';   Via = 'winget'; Id = 'OpenJS.NodeJS.LTS';           Optional = $false }
    [pscustomobject]@{ Key = 'gh';     Name = 'GitHub CLI';     Probe = 'gh';     Via = 'winget'; Id = 'GitHub.cli';                  Optional = $false }
    [pscustomobject]@{ Key = 'jq';     Name = 'jq';             Probe = 'jq';     Via = 'winget'; Id = 'jqlang.jq';                   Optional = $false }
    [pscustomobject]@{ Key = 'uv';     Name = 'uv / uvx';       Probe = 'uv';     Via = 'winget'; Id = 'astral-sh.uv';                Optional = $false }
    [pscustomobject]@{ Key = 'pwsh';   Name = 'PowerShell 7';   Probe = 'pwsh';   Via = 'winget'; Id = 'Microsoft.PowerShell';        Optional = $true  }
    [pscustomobject]@{ Key = 'claude'; Name = 'Claude Code';    Probe = 'claude'; Via = 'npm';    Id = '@anthropic-ai/claude-code';   Optional = $false }
    [pscustomobject]@{ Key = 'codex';  Name = 'Codex CLI';      Probe = 'codex';  Via = 'npm';    Id = '@openai/codex';               Optional = $false }
)

function Test-RealCommand {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    # Microsoft Store の python.exe / python3.exe スタブは実体ではないので未導入扱い
    if ($cmd.Source -and $cmd.Source -like '*\WindowsApps\*' -and $Name -like 'python*') { return $false }
    return $true
}

function Invoke-Install {
    param([pscustomobject]$Tool)

    if ($Tool.Via -eq 'winget') {
        $wargs = @('install', '--id', $Tool.Id, '-e', '--source', 'winget',
                   '--accept-package-agreements', '--accept-source-agreements')
        Write-Host "  winget $($wargs -join ' ')" -ForegroundColor DarkGray
        if (-not $DryRun) { & winget @wargs }
    }
    else {
        Write-Host "  npm install -g $($Tool.Id)" -ForegroundColor DarkGray
        if (-not $DryRun) { & npm install -g $Tool.Id }
    }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warning 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れてから再実行すること。'
}

$installed = @()
$skipped = @()
$failed = @()

foreach ($t in $tools) {
    if ($Only.Count -gt 0 -and $Only -notcontains $t.Key) { continue }
    if ($Skip -contains $t.Key) { $skipped += "$($t.Name) (--Skip)"; continue }
    if ($t.Optional -and -not $IncludeOptional -and $Only.Count -eq 0) {
        $skipped += "$($t.Name) (任意 / -IncludeOptional で導入)"
        continue
    }

    if ((Test-RealCommand $t.Probe) -and -not $Force) {
        $src = (Get-Command $t.Probe -ErrorAction SilentlyContinue).Source
        Write-Host "OK   $($t.Name) -> $src" -ForegroundColor Green
        $skipped += "$($t.Name) (導入済み)"
        continue
    }

    Write-Host "INST $($t.Name) [$($t.Via): $($t.Id)]" -ForegroundColor Cyan

    # npm 経由のものは node が要る
    if ($t.Via -eq 'npm' -and -not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Warning "  npm が無いので $($t.Name) をスキップ。Node.js 導入後にシェルを開き直して再実行すること。"
        $failed += "$($t.Name) (npm なし)"
        continue
    }

    try {
        Invoke-Install $t
        if (-not $DryRun) { $installed += $t.Name }
    }
    catch {
        Write-Warning "  失敗: $($t.Name) — $($_.Exception.Message)"
        $failed += $t.Name
    }
}

Write-Host ''
Write-Host '--- まとめ ---'
if ($DryRun)          { Write-Host '(dry-run: 実際のインストールはしていない)' -ForegroundColor Yellow }
if ($installed)       { Write-Host "installed: $($installed -join ', ')" -ForegroundColor Green }
if ($skipped)         { Write-Host "skipped  : $($skipped -join ', ')" }
if ($failed)          { Write-Host "failed   : $($failed -join ', ')" -ForegroundColor Red }

Write-Host ''
Write-Host '次にやること:'
Write-Host '  1. 新しいシェルを開く（PATH 反映のため）'
Write-Host '  2. gh auth login        … GitHub 認証'
Write-Host '  3. codex login          … ChatGPT アカウントで Codex CLI 認証'
Write-Host '  4. setup\install_aliases.ps1 … cc ショートカット登録'
