#Requires -Version 5.1
<#
    Clipboard Widget uninstaller
    ----------------------------
    Stops the widget, removes the shortcuts and (optionally) the saved data.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
        powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepData
#>
param(
    [switch]$KeepData
)

$ErrorActionPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSCommandPath
$target = Join-Path $root 'clipboard-widget.ps1'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($target) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$desktop = [Environment]::GetFolderPath('Desktop')
$startup = [Environment]::GetFolderPath('Startup')

$desktopLnk = Join-Path $desktop '剪贴板助手.lnk'
$startupLnk = Join-Path $startup '剪贴板助手.lnk'
if (Test-Path -LiteralPath $desktopLnk) { Remove-Item -LiteralPath $desktopLnk -Force }
if (Test-Path -LiteralPath $startupLnk) { Remove-Item -LiteralPath $startupLnk -Force }

if (-not $KeepData) {
    $dataDir = Join-Path $env:APPDATA 'ClipboardWidget'
    if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
}

Write-Host 'Clipboard Widget uninstalled.'
