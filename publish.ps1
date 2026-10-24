param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

if (-not (Test-Path (Join-Path $root '.git'))) {
    throw 'This folder is not a git repository.'
}

$git = 'git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $candidate = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    if (Test-Path -LiteralPath $candidate) { $git = $candidate }
    else { throw 'git.exe was not found. Install Git for Windows first.' }
}

$existing = & $git remote 2>$null
if ($existing -contains 'origin') {
    & $git remote remove origin
}
& $git remote add origin $RepoUrl
& $git branch -M main

Write-Host "Pushing to $RepoUrl ..."
& $git push -u origin main

Write-Host ''
Write-Host 'Done. Open the repository page on GitHub to check it.'
