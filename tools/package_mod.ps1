param([string]$Output = "")
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifest = Get-Content -Raw -LiteralPath (Join-Path $repo "manifest.json") | ConvertFrom-Json
if (-not $Output) {
  $Output = Join-Path (Split-Path $repo -Parent) ($manifest.id + "-" + $manifest.version + ".zip")
}
$Output = [IO.Path]::GetFullPath($Output)
$files = @()
foreach ($dir in @("assets", "data", "lib")) {
  $path = Join-Path $repo $dir
  if (Test-Path -LiteralPath $path) {
    $files += Get-ChildItem -LiteralPath $path -Recurse -File | ForEach-Object {
      $_.FullName.Substring($repo.Length + 1).Replace("\", "/")
    }
  }
}
$files += @("CHANGELOG.md", "LICENSE", "README.md", "main.lua", "manifest.json", "mod.card")
$files = @($files | Sort-Object -Unique)
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
$list = [IO.Path]::GetTempFileName()
try {
  [IO.File]::WriteAllLines($list, [string[]]$files, [Text.UTF8Encoding]::new($false))
  Push-Location $repo
  try { & tar -a -cf $Output -T $list; if ($LASTEXITCODE) { throw "tar failed" } }
  finally { Pop-Location }
} finally { Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue }
$entries = @(tar -tf $Output)
$forbidden = @($entries | Where-Object {
  $_ -match "(?i)(^|/)(assets/battle|assets/vr|model_extract)(/|$)" -or
  $_ -match "(?i)(BattleArt|OverworldBattle|StadiumRom|VRXR)"
})
if ($forbidden.Count) { throw "package contains removed 1.x content: $($forbidden -join ', ')" }
[PSCustomObject]@{
  Path = $Output; Entries = $entries.Count; Bytes = (Get-Item $Output).Length
  SHA256 = (Get-FileHash $Output -Algorithm SHA256).Hash
}
