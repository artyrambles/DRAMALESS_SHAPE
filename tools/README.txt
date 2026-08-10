Build by executing this command in powershell in the folder above. Or adjust the tools part and run it in this folder

With your gitignored art (package full art build)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\package_mod.ps1

Without your gitignored art (package clean build) - including the tools & scripts
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\package_clean_mod.ps1