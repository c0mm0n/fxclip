param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference = 'Stop'
$portable = @(Get-ChildItem $Directory -Filter '*-Portable.zip')
$setup = @(Get-ChildItem $Directory -Filter '*-Setup.exe')
$package = @(Get-ChildItem $Directory -Filter '*-full.nupkg')
if ($portable.Count -ne 1 -or $setup.Count -ne 1 -or $package.Count -ne 1) { throw 'Incomplete Velopack release' }
$feed = Join-Path $Directory 'releases.win.json'
if (!(Test-Path $feed)) { throw 'Missing Windows update feed' }
$index = Get-Content $feed -Raw | ConvertFrom-Json
$assets = $index.Assets
if ($assets.Count -ne 1 -or $assets[0].FileName -ne $package[0].Name) { throw 'Unexpected update feed' }
if ((Get-FileHash $package[0].FullName -Algorithm SHA256).Hash -ne $assets[0].SHA256) { throw 'Package digest mismatch' }
if ($assets[0].Type -ne 'Full' -or $assets[0].Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Invalid full package version' }
if ($package[0].Length -ne $assets[0].Size) { throw 'Package size mismatch' }
$publicPackage = "fxclip-$($assets[0].Version)-full.nupkg"
$destination = Join-Path $Directory $publicPackage
if ($package[0].Name -ne $publicPackage -and (Test-Path $destination)) { throw 'Public package already exists' }
Move-Item $portable[0].FullName (Join-Path $Directory 'fxclip-windows-x64.zip')
Move-Item $setup[0].FullName (Join-Path $Directory 'fxclip-windows-setup.exe')
# Keep the installed application identity and package bytes unchanged. Only the
# public asset name and the feed's download filename change together.
if ($package[0].Name -ne $publicPackage) { Move-Item $package[0].FullName $destination }
$assets[0].FileName = $publicPackage
$index | ConvertTo-Json -Depth 100 | Set-Content $feed -Encoding utf8
# vpk writes auxiliary files for its own upload tools; publish only the required stable artifacts.
Get-ChildItem $Directory -File | Where-Object { $_.Name -notin @('fxclip-windows-x64.zip','fxclip-windows-setup.exe','releases.win.json',$publicPackage) } | Remove-Item
