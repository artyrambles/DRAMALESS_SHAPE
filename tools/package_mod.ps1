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
  $Output = Join-Path (Split-Path $repo -Parent) ($modId + '-' + $modVersion + '.zip')
}
$Output = [System.IO.Path]::GetFullPath($Output)

$source = @()
foreach ($dir in @('data', 'lib')) {
  $source += Get-ChildItem -LiteralPath (Join-Path $repo $dir) -Recurse -File |
    ForEach-Object {
      Relative-Path $_.FullName
    }
}
$source += @('CHANGELOG.md', 'main.lua', 'manifest.json', 'mod.card', 'README.md')
$contracts = @(Get-ChildItem -LiteralPath (Join-Path $repo 'assets\battle') `
  -Recurse -File -Filter 'README.md' | ForEach-Object {
    Relative-Path $_.FullName
  })

# These files are deliberately ignored by Git, but a local test build should
# include them. This bridges a clean public branch and private BYO artwork.
$localArt = @(Get-ChildItem -LiteralPath (Join-Path $repo 'assets\battle') `
  -Recurse -File -Filter '*.png' -ErrorAction SilentlyContinue | ForEach-Object {
    $relative = Relative-Path $_.FullName
    # Authoring drafts may live beside a collection in a folder literally
    # named "backup". They are never runtime candidates and must not inflate
    # or leak into the private test package.
    if ($relative -notmatch '(?i)(^|/)backup(/|$)') { $relative }
  })
$files = @($source + $contracts + $localArt | Sort-Object -Unique)
if (-not $files.Count) { throw "no package files found" }

if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
$fileList = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllLines(
  $fileList,
  [string[]]$files,
  [System.Text.UTF8Encoding]::new($false)
)
Push-Location $repo
try {
  # Passing hundreds of asset paths as individual arguments exceeds the
  # Windows command-line limit. tar's list-file option keeps the invocation
  # short while preserving repository-relative paths inside the archive.
  & tar -a -cf $Output -T $fileList
  if ($LASTEXITCODE -ne 0) { throw "tar failed: $LASTEXITCODE" }
} finally {
  Pop-Location
  Remove-Item -LiteralPath $fileList -Force -ErrorAction SilentlyContinue
}

$entries = @(tar -tf $Output)
[PSCustomObject]@{
  Path = $Output
  Entries = $entries.Count
  LocalPngs = $localArt.Count
  Bytes = (Get-Item -LiteralPath $Output).Length
  SHA256 = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash
}
