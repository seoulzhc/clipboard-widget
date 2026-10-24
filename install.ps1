#Requires -Version 5.1
<#
    Clipboard Widget installer
    --------------------------
    Creates a desktop shortcut and (optionally) a startup shortcut,
    copies the icon to %APPDATA%\ClipboardWidget and starts the widget.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\install.ps1
        powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoStartup
        powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoStartup -NoLaunch
#>
param(
    [switch]$NoStartup,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$root   = Split-Path -Parent $PSCommandPath
$script = Join-Path $root 'clipboard-widget.ps1'
if (-not (Test-Path -LiteralPath $script)) {
    throw 'clipboard-widget.ps1 was not found next to install.ps1.'
}

$dataDir = Join-Path $env:APPDATA 'ClipboardWidget'
if (-not (Test-Path -LiteralPath $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

$iconSource = Join-Path $root 'icon.ico'
$iconTarget = Join-Path $dataDir 'icon.ico'
if (Test-Path -LiteralPath $iconSource) {
    try { Copy-Item -LiteralPath $iconSource -Destination $iconTarget -Force } catch { }
}

$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-Sta -NoProfile -ExecutionPolicy Bypass -File "' + $script + '"'

$shell = New-Object -ComObject WScript.Shell

function New-ClipboardWidgetShortcut {
    param(
        [string]$Path
    )
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $exe
    $lnk.Arguments = $arguments
    $lnk.WorkingDirectory = $root
    $lnk.WindowStyle = 1
    $lnk.Description = '剪贴板助手 - 复制记录与收藏'
    if (Test-Path -LiteralPath $iconTarget) {
        $lnk.IconLocation = $iconTarget + ',0'
    }
    $lnk.Save()
}

$desktop = [Environment]::GetFolderPath('Desktop')
$desktopLnk = Join-Path $desktop '剪贴板助手.lnk'
New-ClipboardWidgetShortcut -Path $desktopLnk
Write-Host "Desktop shortcut : $desktopLnk"

if (-not $NoStartup) {
    $startup = [Environment]::GetFolderPath('Startup')
    $startupLnk = Join-Path $startup '剪贴板助手.lnk'
    New-ClipboardWidgetShortcut -Path $startupLnk
    Write-Host "Startup shortcut : $startupLnk"
}

if (-not $NoLaunch) {
    Start-Process -FilePath $exe -ArgumentList @('-Sta', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) | Out-Null
    Write-Host 'Clipboard Widget started.'
}

Write-Host ''
Write-Host 'Done. The tray icon appears when you press the minus button in the panel.'
