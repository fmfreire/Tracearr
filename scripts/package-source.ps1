$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$archivePath = Join-Path $root 'Tracearr-main.zip'
$temporaryArchivePath = Join-Path $root (".Tracearr-main-" + [System.Guid]::NewGuid().ToString("N") + ".zip.tmp")
$includeDirectories = @(
  'apps',
  'assets',
  'data',
  'docker',
  'docs',
  'packages',
  'release-notes',
  'scripts'
)
$includeFiles = @(
  'turbo.json',
  'tsconfig.base.json',
  'package.json',
  'pnpm-lock.yaml',
  'pnpm-workspace.yaml'
)
$excludedDirectoryNames = @('node_modules', '.git', '.turbo')

foreach ($directory in $includeDirectories) {
  if (-not (Test-Path -LiteralPath (Join-Path $root $directory) -PathType Container)) {
    throw "Required directory not found: $directory"
  }
}

foreach ($file in $includeFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) {
    throw "Required file not found: $file"
  }
}

$filesToArchive = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$directoriesToVisit = [System.Collections.Generic.Stack[string]]::new()

foreach ($directory in $includeDirectories) {
  $directoriesToVisit.Push((Join-Path $root $directory))
}

while ($directoriesToVisit.Count -gt 0) {
  $currentDirectory = $directoriesToVisit.Pop()
  foreach ($entry in Get-ChildItem -LiteralPath $currentDirectory -Force) {
    if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      continue
    }

    if ($entry.PSIsContainer) {
      if ($excludedDirectoryNames -notcontains $entry.Name) {
        $directoriesToVisit.Push($entry.FullName)
      }
    } else {
      $filesToArchive.Add($entry)
    }
  }
}

foreach ($file in $includeFiles) {
  $filesToArchive.Add((Get-Item -LiteralPath (Join-Path $root $file)))
}

if (Test-Path -LiteralPath $temporaryArchivePath) {
  Remove-Item -LiteralPath $temporaryArchivePath -Force
}

$archiveStream = $null
$archive = $null
try {
  $archiveStream = [System.IO.File]::Open(
    $temporaryArchivePath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
  $archive = [System.IO.Compression.ZipArchive]::new(
    $archiveStream,
    [System.IO.Compression.ZipArchiveMode]::Create,
    $false
  )

  foreach ($file in $filesToArchive) {
    $relativePath = $file.FullName.Substring($root.Length).TrimStart('\', '/')
    $entryPath = $relativePath.Replace('\', '/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $archive,
      $file.FullName,
      $entryPath,
      [System.IO.Compression.CompressionLevel]::Optimal
    ) | Out-Null
  }
} finally {
  if ($null -ne $archive) {
    $archive.Dispose()
  }
  if ($null -ne $archiveStream) {
    $archiveStream.Dispose()
  }
}

Move-Item -LiteralPath $temporaryArchivePath -Destination $archivePath -Force
$archiveInfo = Get-Item -LiteralPath $archivePath
Write-Output "Created $($archiveInfo.FullName)"
Write-Output "Included $($filesToArchive.Count) files ($([math]::Round($archiveInfo.Length / 1MB, 1)) MB)"
Write-Output 'Excluded nested node_modules, .git, .turbo, and reparse-point entries.'
