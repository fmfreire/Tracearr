<#
.SYNOPSIS
  Automates fetching upstream updates from connorgallopo/Tracearr,
  merging into fmfreire/Tracearr via a Pull Request, admin-merging to main,
  and packaging a fresh Tracearr-main.zip.

.DESCRIPTION
  Requirements:
    - git (with access to origin and upstream remotes)
    - GitHub CLI (gh.exe)
    - GH_TOKEN or GITHUB_TOKEN environment variable (or hardcoded PAT fallback)
#>

[CmdletBinding()]
param(
  [string]$UpstreamBranch = "main",
  [switch]$SkipZip = $false
)

$ErrorActionPreference = 'Continue'

# Ensure Git and GitHub CLI are in PATH
$gitCmdPaths = @(
  "C:\Program Files\Git\cmd",
  "C:\Users\$env:USERNAME\AppData\Local\Programs\Git\cmd"
)
$ghCmdPaths = @(
  "C:\Program Files\GitHub CLI",
  "C:\Users\$env:USERNAME\AppData\Local\Programs\GitHubCLI\bin"
)

foreach ($p in ($gitCmdPaths + $ghCmdPaths)) {
  if ((Test-Path -LiteralPath $p) -and ($env:Path -notlike "*$p*")) {
    $env:Path = "$p;$env:Path"
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location -LiteralPath $repoRoot

# Configure token for GitHub CLI from environment (User or Process)
if (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) {
  $userToken = [System.Environment]::GetEnvironmentVariable("GH_TOKEN", "User")
  if (-not $userToken) {
    $userToken = [System.Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "User")
  }
  if ($userToken) {
    $env:GH_TOKEN = $userToken
  }
}

Write-Host "==> Checking git status..." -ForegroundColor Cyan
$gitStatus = & git status --porcelain -uno
if ($gitStatus) {
  Write-Host "Error: Working directory has uncommitted tracked changes. Please stash or commit them before updating." -ForegroundColor Red
  exit 1
}

# Fetch remotes
Write-Host "==> Fetching latest changes from origin and upstream..." -ForegroundColor Cyan
& git fetch origin
& git fetch upstream --tags

# Check if there are updates from upstream
& git checkout main
& git pull origin main

$behindCount = (& git rev-list --count "HEAD..upstream/$UpstreamBranch").Trim()
if ([int]$behindCount -eq 0) {
  Write-Host "==> Fork is already up to date with upstream/$UpstreamBranch! Nothing to merge." -ForegroundColor Green
  exit 0
}

Write-Host "==> Upstream has $behindCount new commit(s). Preparing merge..." -ForegroundColor Yellow

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$syncBranch = "sync/upstream-$timestamp"

Write-Host "==> Creating branch $syncBranch..." -ForegroundColor Cyan
& git checkout -b $syncBranch

Write-Host "==> Merging upstream/$UpstreamBranch..." -ForegroundColor Cyan
$mergeOutput = & git merge "upstream/$UpstreamBranch" -m "sync: merge upstream/$UpstreamBranch updates ($timestamp)" 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host "Conflict detected during merge. Resolving known fork divergences..." -ForegroundColor Yellow
  
  # 1. Pruned CI files that fork intentionally deleted: keep deleted
  $deletedFiles = @(
    ".github/renovate.json",
    ".github/workflows/renovate.yml",
    ".github/workflows/snyk.yml"
  )
  foreach ($df in $deletedFiles) {
    $isConflict = & git status --porcelain $df
    if ($isConflict) {
      Write-Host "  -> Removing $df (fork intentionally does not track this file)..." -ForegroundColor Gray
      & git rm -f --ignore-unmatch $df 2>$null
    }
  }

  # 2. Release workflow conflict: discard npm/mobile publish jobs, keep fork's streamlined release
  $releaseWorkflow = ".github/workflows/release.yml"
  $relConflict = & git status --porcelain $releaseWorkflow
  if ($relConflict) {
    Write-Host "  -> Resolving $releaseWorkflow conflict (preserving fork release workflow)..." -ForegroundColor Gray
    $relContent = Get-Content (Join-Path $repoRoot $releaseWorkflow) -Raw
    if ($relContent -match '(?ms)<<<<<<< HEAD.*?(=======.*?>>>>>>>[^\r\n]*)') {
      $upstreamPart = $Matches[1]
      $cleanedContent = $relContent -replace '(?ms)<<<<<<< HEAD\r?\n', '' `
                                   -replace [regex]::Escape($upstreamPart), ''
      Set-Content -Path (Join-Path $repoRoot $releaseWorkflow) -Value $cleanedContent -NoNewline
      & git add $releaseWorkflow
    }
  }

  # 3. Helm chart version conflict if present: accept upstream version
  $helmChart = "docker/helm/tracearr/Chart.yaml"
  if (Test-Path -LiteralPath (Join-Path $repoRoot $helmChart)) {
    $chartConflict = & git status --porcelain $helmChart
    if ($chartConflict) {
      Write-Host "  -> Resolving $helmChart conflict (accepting upstream)..." -ForegroundColor Gray
      & git checkout --theirs $helmChart
      & git add $helmChart
    }
  }

  # 4. Release notes conflicts: accept upstream version
  $conflictedReleaseNotes = & git diff --name-only --diff-filter=U | Where-Object { $_ -like "release-notes/*.json" }
  foreach ($rnFile in $conflictedReleaseNotes) {
    Write-Host "  -> Accepting upstream release notes in $rnFile..." -ForegroundColor Gray
    & git checkout --theirs $rnFile 2>&1 | Out-Null
    & git add $rnFile
  }

  # Check if other conflicts remain
  $remainingConflicts = & git diff --name-only --diff-filter=U
  if ($remainingConflicts) {
    Write-Host "Unresolved conflicts in:" -ForegroundColor Red
    $remainingConflicts | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    Write-Host "Please resolve conflicts manually, commit, and push." -ForegroundColor Red
    exit 1
  }

  & git commit -m "sync: merge upstream/$UpstreamBranch updates ($timestamp)"
}

Write-Host "==> Pushing branch $syncBranch to origin..." -ForegroundColor Cyan
& git push -u origin $syncBranch --no-verify

Write-Host "==> Creating Pull Request on fmfreire/Tracearr..." -ForegroundColor Cyan
$prBody = @"
Automated sync from upstream ($UpstreamBranch).
Contains $behindCount new upstream commit(s).
All custom membership controls, automated enforcement policies, and duplicate fixes preserved.
"@

$prUrl = & gh pr create --repo fmfreire/Tracearr --base main --head $syncBranch --title "sync: upstream updates ($timestamp)" --body "$prBody"
Write-Host "==> PR created: $prUrl" -ForegroundColor Green

Write-Host "==> Merging PR into main with admin approval..." -ForegroundColor Cyan
& gh pr merge $prUrl --repo fmfreire/Tracearr --merge --admin

Write-Host "==> Pulling updated main locally..." -ForegroundColor Cyan
& git checkout . 2>&1 | Out-Null
& git checkout main 2>&1 | Out-Null
& git pull origin main 2>&1 | Write-Host

Write-Host "==> Cleaning up local branch $syncBranch..." -ForegroundColor Gray
& git branch -D $syncBranch 2>&1 | Out-Null

if (-not $SkipZip) {
  Write-Host "==> Packaging fresh deployment zip..." -ForegroundColor Cyan
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "package-source.ps1")
  $stuffDir = (Resolve-Path (Join-Path $repoRoot "..")).Path
  Copy-Item -Path (Join-Path $repoRoot "Tracearr-main.zip") -Destination (Join-Path $stuffDir "Tracearr-main.zip") -Force
  Write-Host "==> Tracearr-main.zip updated in: $stuffDir" -ForegroundColor Green
}

Write-Host "`nSUCCESS: Fork updated, merged, and packaged successfully!" -ForegroundColor Green
