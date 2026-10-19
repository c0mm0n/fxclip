param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference = 'Stop'
$portable = @(Get-ChildItem $Directory -Filter '*-Portable.zip')
$setup = @(Get-ChildItem $Directory -Filter '*-Setup.exe')
$package = @(Get-ChildItem $Directory -Filter '*-full.nupkg')
if ($portable.Count -ne 1 -or $setup.Count -ne 1 -or $package.Count -ne 1) { throw 'Incomplete Velopack release' }
Move-Item $portable[0].FullName (Join-Path $Directory 'fxclip-windows-x64.zip')
Move-Item $setup[0].FullName (Join-Path $Directory 'fxclip-windows-setup.exe')
$feed = Join-Path $Directory 'releases.win.json'
if (!(Test-Path $feed)) { throw 'Missing Windows update feed' }
$assets = (Get-Content $feed -Raw | ConvertFrom-Json).Assets
if ($assets.Count -ne 1 -or $assets[0].FileName -ne $package[0].Name) { throw 'Unexpected update feed' }
if ((Get-FileHash $package[0].FullName -Algorithm SHA256).Hash -ne $assets[0].SHA256) { throw 'Package digest mismatch' }
# vpk writes auxiliary files for its own upload tools; publish only the required stable artifacts.
Get-ChildItem $Directory -File | Where-Object { $_.Name -notin @('fxclip-windows-x64.zip','fxclip-windows-setup.exe','releases.win.json',$package[0].Name) } | Remove-Item
