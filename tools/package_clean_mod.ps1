param(
  [string]$Output = ""
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Relative-Path([string]$FullName) {
  return $FullName.Substring($repo.Length + 1).Replace('\', '/')
}

# Derive the package name from the mod's own manifest (id + version) so the
# produced .zip matches what the in-game mod manager expects for auto-update:
# ModUpdate.pickZipAsset prefers exactly "<id>-<version>.zip". A hardcoded
# "DramaticShapeVoxelMod-battle-art" name stopped matching once the manifest
# id was renamed, which is why post-rename updates failed to resolve.
$manifest = Get-Content -Raw -LiteralPath (Join-Path $repo 'manifest.json') |
  ConvertFrom-Json
$modId = $manifest.id
$modVersion = ($manifest.version -replace '^[vV]', '')
if (-not $modId -or -not $modVersion) {
  throw "manifest.json is missing id or version"
}

if (-not $Output) {
  $Output = Join-Path (Split-Path $repo -Parent) `
    ($modId + '-' + $modVersion + '-clean.zip')
}
$Output = [System.IO.Path]::GetFullPath($Output)

# Match the installable runtime allowlist used by package_mod.ps1, then add
# the public authoring toolkit so a ZIP recipient does not need a Git clone.
$source = @()
foreach ($dir in @('data', 'lib', 'tools')) {
  $source += Get-ChildItem -LiteralPath (Join-Path $repo $dir) -Recurse -File |
    Where-Object {
      $_.Extension -ine '.pyc' -and
      $_.FullName -notmatch '(?i)[\\/]__pycache__[\\/]'
    } |
    ForEach-Object { Relative-Path $_.FullName }
}
$source += @('CHANGELOG.md', 'main.lua', 'manifest.json', 'mod.card', 'README.md')

$battleRoot = Join-Path $repo 'assets\battle'
$battleDirs = @(Get-ChildItem -LiteralPath $battleRoot -Recurse -Directory |
  ForEach-Object { (Relative-Path $_.FullName).TrimEnd('/') + '/' })
$battleDirs += 'assets/battle/'

# Keep contracts and future non-art metadata, but never ship local battle PNGs.
$battleFiles = @(Get-ChildItem -LiteralPath $battleRoot -Recurse -File -Force |
  Where-Object { $_.Extension -ine '.png' } |
  ForEach-Object { Relative-Path $_.FullName })

$entries = @($source + $battleDirs + $battleFiles | Sort-Object -Unique)
if (-not $entries.Count) { throw "no package entries found" }

if (Test-Path -LiteralPath $Output) {
  Remove-Item -LiteralPath $Output -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open(
  $Output,
  [System.IO.Compression.ZipArchiveMode]::Create
)
try {
  foreach ($entry in $entries) {
    if ($entry.EndsWith('/')) {
      # A ZIP directory entry keeps an otherwise-empty BYO generation folder
      # visible without recursively collecting anything stored below it.
      [void]$archive.CreateEntry($entry)
      continue
    }
    $fullName = Join-Path $repo ($entry.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $fullName -PathType Leaf)) {
      throw "package source file is missing: $entry"
    }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $archive,
      $fullName,
      $entry,
      [System.IO.Compression.CompressionLevel]::Optimal
    )
  }
} finally {
  $archive.Dispose()
}

$checkArchive = [System.IO.Compression.ZipFile]::OpenRead($Output)
try {
  $packed = @($checkArchive.Entries | ForEach-Object { $_.FullName })
} finally {
  $checkArchive.Dispose()
}
$battlePngs = @($packed | Where-Object {
  $_ -match '(?i)^assets/battle/.*\.png$'
})
if ($battlePngs.Count) {
  throw "clean package unexpectedly contains battle PNGs: $($battlePngs -join ', ')"
}

foreach ($required in @('manifest.json', 'main.lua', 'mod.card')) {
  if ($packed -notcontains $required) {
    throw "clean package is missing required install entry: $required"
  }
}

[PSCustomObject]@{
  Path = $Output
  Entries = $packed.Count
  BattlePngs = $battlePngs.Count
  BattleFolders = $battleDirs.Count
  Bytes = (Get-Item -LiteralPath $Output).Length
  SHA256 = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash
}
