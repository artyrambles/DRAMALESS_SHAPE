param([string]$Output = "")
# 2.0 has no private battle-art payload; the normal package is already clean.
& (Join-Path $PSScriptRoot "package_mod.ps1") -Output $Output
