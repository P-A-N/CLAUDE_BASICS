<#
.SYNOPSIS
  Claude Code 用のシェルショートカットを PowerShell プロファイルに登録する。

.DESCRIPTION
  以下を冪等に追記する（既に登録済みならスキップ）:
    cc  ... claude --dangerously-skip-permissions（追加引数はそのまま渡す）
    cdx ... codex --dangerously-bypass-approvals-and-sandbox（追加引数はそのまま渡す）

  Windows PowerShell 5.1 と PowerShell 7 の両方のプロファイルに書く。
  -Scope で片方だけに絞れる。

.EXAMPLE
  pwsh -File claude-basics/setup/install_aliases.ps1
  powershell -File claude-basics/setup/install_aliases.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # 書き込み先。既定は 5.1 と 7 の両方。
    [ValidateSet('All', 'WindowsPowerShell', 'PowerShell')]
    [string]$Scope = 'All',

    # 既存の cc 定義を上書きする
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$marker = '# --- Claude Code (claude-basics) ---'

$docs = [Environment]::GetFolderPath('MyDocuments')
$targets = @()
if ($Scope -in 'All', 'WindowsPowerShell') {
    $targets += Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
}
if ($Scope -in 'All', 'PowerShell') {
    $targets += Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'
}

foreach ($path in $targets) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, 'create directory')) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $existing = if (Test-Path $path) { Get-Content $path -Raw } else { '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($existing -notmatch [regex]::Escape($marker)) {
        $lines.Add($marker)
    }
    if ($existing -notmatch '(?m)^\s*(function\s+cc\s*\{|Set-Alias\s+cc\b|New-Alias\s+cc\b)' -or $Force) {
        $lines.Add('function cc { claude --dangerously-skip-permissions @args }')
    }
    if ($existing -notmatch '(?m)^\s*(function\s+cdx\s*\{|Set-Alias\s+cdx\b|New-Alias\s+cdx\b)' -or $Force) {
        $lines.Add('function cdx { codex --dangerously-bypass-approvals-and-sandbox @args }')
    }

    if ($lines.Count -eq 0) {
        Write-Host "skip (登録済み): $path"
        continue
    }

    if ($PSCmdlet.ShouldProcess($path, 'append shell shortcuts')) {
        if ($existing -and -not $existing.EndsWith("`n")) { Add-Content -Path $path -Value '' }
        Add-Content -Path $path -Value ($lines -join [Environment]::NewLine) -Encoding utf8
        Write-Host "登録しました: $path"
    }
}

Write-Host ''
Write-Host '新しいシェルを開くか、`. $PROFILE` で読み直すと cc / cdx が使えます。'
