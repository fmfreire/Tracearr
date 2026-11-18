<#
.SYNOPSIS
  Auto-detects the next release version, bumps Chart.yaml, creates release notes
  if needed, merges to main, pushes the tag, and triggers the GitHub Actions release pipeline.

.DESCRIPTION
  Steps:
    1. Determine next version — from latest release-notes/*.json file (highest semver)
       or from the latest git tag + patch bump (whichever is newer).
    2. Ensure release-notes/<version>.json exists (auto-generates standard template if missing).
    3. Bump docker/helm/tracearr/Chart.yaml to the new version.
    4. Commit changes to branch, PR, and admin-merge to main.
    5. Push the vX.Y.Z tag with --no-verify (bypasses Husky pre-push).
    6. Print the Actions URL to watch the Docker build and release.

  Requirements:
    - git (with access to origin remote)
    - GitHub CLI (gh.exe) in PATH or standard install location
    - GH_TOKEN environment variable set (needs: repo, workflow scopes)

.PARAMETER Version
  Optional. Force a specific version (e.g. "3.2.1"). If omitted, auto-detects.

.PARAMETER SkipPR
  Optional. Skip the PR step (use only if main is already updated).

.EXAMPLE
  .\scripts\cut-release.ps1
  .\scripts\cut-release.ps1 -Version 3.2.1
#>

[CmdletBinding()]
param(
  [string]$Version = "",
  [switch]$SkipPR = $false,
  [switch]$Force = $false
)

$ErrorActionPreference = 'Continue'

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Utf8NoBom([string]$filePath, [string]$text) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($filePath, $text, $utf8NoBom)
}
$ghCmdPaths = @(
  "C:\Program Files\GitHub CLI",
  "C:\Users\$env:USERNAME\AppData\Local\Programs\GitHubCLI\bin"
)
foreach ($p in $ghCmdPaths) {
  if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) {
    $env:Path = "$p;$env:Path"
  }
}

# ── Token ─────────────────────────────────────────────────────────────────────
if (-not $env:GH_TOKEN) {
  $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable("GH_TOKEN", "User")
}
if (-not $env:GH_TOKEN) {
  Write-Error "GH_TOKEN is not set. Store it via: [System.Environment]::SetEnvironmentVariable('GH_TOKEN','ghp_...','User')"
  exit 1
}

# ── Repo root ──────────────────────────────────────────────────────────────────
$repoRoot = git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
if (-not $repoRoot) { $repoRoot = $PSScriptRoot | Split-Path }
Set-Location $repoRoot
Write-Host "📁 Repo root: $repoRoot" -ForegroundColor Cyan

# ── Ensure we're on main and up to date ───────────────────────────────────────
Write-Host "`n🔄 Ensuring main is up to date..." -ForegroundColor Cyan
git checkout . 2>$null
git checkout main
git pull origin main
$repo = git remote get-url origin | Select-String 'github\.com[:/](.+?)(?:\.git)?$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
Write-Host "   Remote: $repo"

# ── Determine next version ────────────────────────────────────────────────────
function Parse-SemVer($v) {
  $v = $v.TrimStart('v')
  if ($v -match '^(\d+)\.(\d+)\.(\d+)') {
    return [PSCustomObject]@{ Major=[int]$Matches[1]; Minor=[int]$Matches[2]; Patch=[int]$Matches[3]; Raw=$v }
  }
  return $null
}

if ($Version) {
  $nextVersion = $Version.TrimStart('v')
  Write-Host "`n📌 Using forced version: $nextVersion" -ForegroundColor Yellow
} else {
  Write-Host "`n🔍 Auto-detecting next version..." -ForegroundColor Cyan

  # Highest version from release-notes/*.json filenames
  $releaseNotesVersion = Get-ChildItem "$repoRoot\release-notes" -Filter "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^\d+\.\d+\.\d+$' } |
    ForEach-Object { Parse-SemVer $_.BaseName } |
    Where-Object { $_ } |
    Sort-Object { $_.Major * 1000000 + $_.Minor * 1000 + $_.Patch } |
    Select-Object -Last 1

  # Highest existing git tag (local + remote)
  git fetch origin --tags --quiet 2>$null
  $tagVersion = git tag --list "v*" |
    ForEach-Object { Parse-SemVer $_ } |
    Where-Object { $_ -and $_.Raw -notmatch '-' } |   # skip pre-release tags
    Sort-Object { $_.Major * 1000000 + $_.Minor * 1000 + $_.Patch } |
    Select-Object -Last 1

  Write-Host "   Latest release-notes version : $(if ($releaseNotesVersion) { $releaseNotesVersion.Raw } else { 'none' })"
  Write-Host "   Latest git tag version        : $(if ($tagVersion) { $tagVersion.Raw } else { 'none' })"

  # Use whichever is higher
  $rnScore  = if ($releaseNotesVersion) { $releaseNotesVersion.Major * 1000000 + $releaseNotesVersion.Minor * 1000 + $releaseNotesVersion.Patch } else { 0 }
  $tagScore = if ($tagVersion)          { $tagVersion.Major * 1000000          + $tagVersion.Minor * 1000          + $tagVersion.Patch }          else { 0 }

  if ($rnScore -gt $tagScore) {
    # release-notes has a version not yet tagged → that is the next version
    $nextVersion = $releaseNotesVersion.Raw
    Write-Host "   → Using release-notes version (not yet tagged): $nextVersion" -ForegroundColor Green
  } elseif ($tagScore -gt 0) {
    # Bump patch from latest tag
    $nextVersion = "$($tagVersion.Major).$($tagVersion.Minor).$($tagVersion.Patch + 1)"
    Write-Host "   → Bumping patch from latest tag: $nextVersion" -ForegroundColor Green
  } else {
    Write-Error "Could not determine next version. Pass -Version explicitly."
    exit 1
  }
}

$tag = "v$nextVersion"
Write-Host "`n🏷  Next release tag: $tag" -ForegroundColor Green

# ── Ensure release notes exist ────────────────────────────────────────────────
$releaseNotesFile = "$repoRoot\release-notes\$nextVersion.json"
$createdReleaseNotes = $false
if (-not (Test-Path $releaseNotesFile)) {
  Write-Host "📄 Auto-generating release-notes\$nextVersion.json..." -ForegroundColor Cyan
  $todayStr = (Get-Date).ToString("yyyy-MM-dd")
  $parsed = Parse-SemVer $nextVersion
  if ($parsed -and $parsed.Patch -eq 0 -and ($parsed.Major + $parsed.Minor -gt 0)) {
    $noteObj = [PSCustomObject]@{
      version = $nextVersion
      date = $todayStr
      headline = "Tracearr $nextVersion release"
      highlights = @(
        [PSCustomObject]@{
          title = "Release updates"
          body = "Includes latest upstream improvements and features."
        }
      )
      changes = @(
        [PSCustomObject]@{
          type = "new"
          text = "Synchronized with upstream releases."
          refs = @()
        }
      )
    }
  } else {
    $noteObj = [PSCustomObject]@{
      version = $nextVersion
      date = $todayStr
      changes = @(
        [PSCustomObject]@{
          type = "fix"
          text = "Maintenance release and upstream synchronization."
          refs = @()
        }
      )
    }
  }
  $template = $noteObj | ConvertTo-Json -Depth 5
  Write-Utf8NoBom $releaseNotesFile $template
  $createdReleaseNotes = $true
}

# ── Check tag doesn't already exist ───────────────────────────────────────────
$existingTag = git tag --list $tag
if ($existingTag) {
  if ($Force) {
    Write-Host "Overwriting existing local tag $tag (-Force)..." -ForegroundColor Yellow
    git tag -d $tag | Out-Null
  } else {
    Write-Error "Tag $tag already exists locally. Delete it first: git tag -d $tag (or pass -Force)"
    exit 1
  }
}
$remoteTag = git ls-remote origin "refs/tags/$tag"
if ($remoteTag) {
  if ($Force) {
    Write-Host "Overwriting existing remote tag $tag (-Force)..." -ForegroundColor Yellow
    $savedToken = $env:GH_TOKEN
    $env:GH_TOKEN = ""
    git push origin ":refs/tags/$tag" --no-verify 2>&1 | Out-Null
    $env:GH_TOKEN = $savedToken
  } else {
    Write-Error "Tag $tag already exists on remote. Nothing to do (or pass -Force to re-release)."
    exit 0
  }
}

# ── Bump Chart.yaml ───────────────────────────────────────────────────────────
$chartFile = "$repoRoot\docker\helm\tracearr\Chart.yaml"
$chartContent = Get-Content $chartFile -Raw

$currentChartVersion = if ($chartContent -match 'version:\s*(\S+)') { $Matches[1] } else { "unknown" }
Write-Host "`n📄 Chart.yaml current version: $currentChartVersion"

$needsChartBump = ($currentChartVersion -ne $nextVersion)

if (-not $needsChartBump -and -not $createdReleaseNotes -and (-not $SkipPR)) {
  Write-Host "   Chart.yaml and release-notes already up to date — skipping bump PR." -ForegroundColor Green
  $SkipPR = $true
}

if (-not $SkipPR) {
  Write-Host "`n📝 Preparing branch with updates for $nextVersion..." -ForegroundColor Cyan
  if ($needsChartBump) {
    $chartContent = $chartContent -replace '(?m)^version:\s*\S+', "version: $nextVersion"
    $appVerReplacement = 'appVersion: "' + $nextVersion + '"'
    $chartContent = $chartContent -replace '(?m)^appVersion:\s*"?\S+"?', $appVerReplacement
    Write-Utf8NoBom $chartFile $chartContent
  }

  $branch = "chore/bump-release-$nextVersion"
  git checkout -b $branch
  if ($needsChartBump) {
    git add docker/helm/tracearr/Chart.yaml
  }
  if ($createdReleaseNotes) {
    git add $releaseNotesFile
  }
  git commit --no-verify -m "chore: prepare release v$nextVersion"

  # Push branch (temporarily clearing GH_TOKEN so git uses keyring credential manager)
  $savedToken = $env:GH_TOKEN
  $env:GH_TOKEN = ""
  git push -u origin $branch --no-verify 2>&1 | Write-Host
  $env:GH_TOKEN = $savedToken

  Write-Host "`n🔀 Creating and merging PR..." -ForegroundColor Cyan
  $prUrl = gh pr create --repo $repo --base main --head $branch `
    --title "chore: prepare release v$nextVersion" `
    --body "Automated release bump and metadata ahead of release tag $tag." 2>&1 | Select-String "https://" | Select-Object -First 1
  Write-Host "   PR: $prUrl"

  gh pr merge $prUrl --repo $repo --merge --admin | Out-Null
  Write-Host "   ✅ PR merged"

  # Pull updated main
  git checkout .
  git checkout main
  git pull origin main
  git branch -d $branch 2>$null
}

# ── Push tag ──────────────────────────────────────────────────────────────────
Write-Host "`n🏷  Tagging $tag and pushing..." -ForegroundColor Cyan
git tag $tag

$savedToken = $env:GH_TOKEN
$env:GH_TOKEN = ""
$pushOutput = git push origin $tag --no-verify 2>&1
$env:GH_TOKEN = $savedToken

# A new tag line in output means success even if exit code is 1 (Husky noise)
if ($pushOutput -match "\* \[new tag\]") {
  Write-Host "   ✅ Tag $tag pushed successfully" -ForegroundColor Green
} elseif ($LASTEXITCODE -ne 0) {
  Write-Error "Tag push failed:`n$pushOutput"
  exit 1
}

# ── Report ────────────────────────────────────────────────────────────────────
Write-Host "`n🚀 Release pipeline triggered!" -ForegroundColor Green
Write-Host "   Tag    : $tag"
Write-Host "   Repo   : https://github.com/$repo"
Write-Host "   Actions: https://github.com/$repo/actions"
Write-Host "   Release: https://github.com/$repo/releases/tag/$tag"
Write-Host ""
Write-Host "The build takes ~20-30 min. Docker images will be published at:" -ForegroundColor Cyan
$owner = $repo.Split('/')[0].ToLower()
Write-Host "   ghcr.io/$owner/tracearr:$nextVersion"
Write-Host "   ghcr.io/$owner/tracearr:latest"
