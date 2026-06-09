<#
.SYNOPSIS
    Push the xui-outbound-termux project to GitHub.

.DESCRIPTION
    Initializes git (if needed), commits all changes, and pushes to the
    GitHub repo using a Personal Access Token (PAT).

    The token is NOT stored in the repo. Pass it as a parameter or set the
    GITHUB_TOKEN environment variable.

.EXAMPLE
    .\push-to-github.ps1 -Token "github_pat_xxx"

.EXAMPLE
    .\push-to-github.ps1 -Token "github_pat_xxx" -Message "fix install script"
#>
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$User = "asanseir724",
    [string]$Repo = "xui-outbound-termux",
    [string]$Branch = "main",
    [string]$Message = "Update xui-outbound-termux"
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "ERROR: No token provided." -ForegroundColor Red
    Write-Host 'Usage: .\push-to-github.ps1 -Token "github_pat_xxx"' -ForegroundColor Yellow
    exit 1
}

# Build the authenticated remote URL but keep the stored remote tokenless.
$cleanRemote = "https://github.com/$User/$Repo.git"
$authRemote  = "https://${User}:${Token}@github.com/$User/$Repo.git"

# 1. Init repo if needed
if (-not (Test-Path ".git")) {
    Write-Host "==> Initializing git repository..." -ForegroundColor Cyan
    git init | Out-Null
    git branch -M $Branch
}

# 2. Ensure remote 'origin' points at the clean URL (no token saved on disk)
$existing = git remote 2>$null
if ($existing -contains "origin") {
    git remote set-url origin $cleanRemote
} else {
    git remote add origin $cleanRemote
}

# 3. Stage + commit
Write-Host "==> Staging changes..." -ForegroundColor Cyan
git add -A

$pending = git status --porcelain
if ([string]::IsNullOrWhiteSpace($pending)) {
    Write-Host "==> Nothing to commit; will still try to push current branch." -ForegroundColor Yellow
} else {
    git commit -m $Message | Out-Null
    Write-Host "==> Committed: $Message" -ForegroundColor Green
}

# 4. Push using the token only for this command
Write-Host "==> Pushing to $cleanRemote ($Branch)..." -ForegroundColor Cyan
git -c credential.helper= push $authRemote "${Branch}:${Branch}" 2>&1 | ForEach-Object {
    # Hide the token if it ever appears in output
    ($_ -replace [regex]::Escape($Token), "***")
}

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "==> Done. Pushed to https://github.com/$User/$Repo" -ForegroundColor Green
    Write-Host "    IMPORTANT: Revoke this token now and create a new one (it was shared in chat)." -ForegroundColor Yellow
} else {
    Write-Host "==> Push failed (exit $LASTEXITCODE). Check repo name, branch, and token scopes (needs 'repo')." -ForegroundColor Red
    exit $LASTEXITCODE
}
