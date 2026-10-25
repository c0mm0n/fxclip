$ErrorActionPreference = 'Stop'
$prepareRelease = Join-Path $PSScriptRoot 'prepare-release.ps1'
$tempDirectory = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$fixtureRoot = Join-Path $tempDirectory ('fxclip-prepare-release-test-' + [guid]::NewGuid())
$legacyId = 'ArbitraryLegacyApplicationID'
$legacyPackage = "$legacyId-1.2.3-full.nupkg"
$packageBytes = [byte[]](0, 1, 2, 127, 128, 254, 255)

function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function New-Fixture([string]$Name) {
    $directory = Join-Path $fixtureRoot $Name
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $directory $legacyPackage), $packageBytes)
    [IO.File]::WriteAllBytes((Join-Path $directory "$legacyId-win-Portable.zip"), [byte[]](80, 75, 3, 4))
    [IO.File]::WriteAllBytes((Join-Path $directory "$legacyId-win-Setup.exe"), [byte[]](77, 90, 0, 255))
    foreach ($extra in @('RELEASES', 'assets.win.json', 'obsolete.txt')) {
        [IO.File]::WriteAllText((Join-Path $directory $extra), "auxiliary $extra")
    }
    $index = [ordered]@{
        Assets = @([ordered]@{
            PackageId = $legacyId
            Version = '1.2.3'
            Type = 'Full'
            FileName = $legacyPackage
            SHA256 = (Get-FileHash (Join-Path $directory $legacyPackage) -Algorithm SHA256).Hash
            SHA1 = (Get-FileHash (Join-Path $directory $legacyPackage) -Algorithm SHA1).Hash
            Size = 7
            FutureAssetField = [ordered]@{ Text = 'keep this'; Values = @(2, 5) }
        })
        FutureFeedField = 'also preserved'
    }
    $index | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $directory 'releases.win.json') -Encoding utf8
    return $directory
}

function Get-FileSnapshot([string]$Directory) {
    $files = [ordered]@{}
    foreach ($file in (Get-ChildItem $Directory -File | Sort-Object Name)) {
        $files[$file.Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
    }
    return ($files | ConvertTo-Json -Compress)
}

function Assert-RejectedWithoutMutation([string]$Directory) {
    $before = Get-FileSnapshot $Directory
    $rejected = $false
    try { & $prepareRelease -Directory $Directory }
    catch { $rejected = $true }
    Assert-True $rejected "Invalid fixture was accepted: $Directory"
    Assert-True ((Get-FileSnapshot $Directory) -ceq $before) "Rejected fixture was renamed, rewritten or cleaned: $Directory"
}

try {
    $good = New-Fixture 'valid'
    $before = Get-Content (Join-Path $good 'releases.win.json') -Raw | ConvertFrom-Json
    & $prepareRelease -Directory $good
    $expectedNames = @('fxclip-1.2.3-full.nupkg', 'fxclip-windows-setup.exe', 'fxclip-windows-x64.zip', 'releases.win.json') | Sort-Object
    $actualNames = @(Get-ChildItem $good -Force | Sort-Object Name | ForEach-Object Name)
    Assert-True (($actualNames -join '|') -ceq ($expectedNames -join '|')) 'Expected exactly four neutral public artifacts'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $good 'fxclip-1.2.3-full.nupkg'))) -ceq [Convert]::ToBase64String($packageBytes)) 'Package bytes changed'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $good 'fxclip-windows-setup.exe'))) -ceq 'TVoA/w==') 'Installer bytes changed'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $good 'fxclip-windows-x64.zip'))) -ceq 'UEsDBA==') 'Portable bytes changed'
    $after = Get-Content (Join-Path $good 'releases.win.json') -Raw | ConvertFrom-Json
    Assert-True (@($after.Assets).Count -eq 1) 'Feed asset count changed'
    Assert-True ($after.Assets[0].FileName -ceq 'fxclip-1.2.3-full.nupkg') 'Feed does not point to the neutral package'
    Assert-True ($after.Assets[0].Size -eq 7) 'Seven-byte package size changed'
    Assert-True ($after.Assets[0].PackageId -ceq $legacyId) 'Internal application identity changed'
    # Compare every feed field after allowing only the requested filename change.
    $after.Assets[0].FileName = $before.Assets[0].FileName
    Assert-True (($after | ConvertTo-Json -Depth 20 -Compress) -ceq ($before | ConvertTo-Json -Depth 20 -Compress)) 'Other feed metadata changed (including digests or unknown fields)'

    foreach ($failure in @('hash', 'size', 'version', 'feed-filename', 'feed-count')) {
        $directory = New-Fixture "invalid-$failure"
        $feedPath = Join-Path $directory 'releases.win.json'
        $index = Get-Content $feedPath -Raw | ConvertFrom-Json
        switch ($failure) {
            'hash' { $index.Assets[0].SHA256 = '0' * 64 }
            'size' { $index.Assets[0].Size = 8 }
            'version' { $index.Assets[0].Version = '../1.2.3' }
            'feed-filename' { $index.Assets[0].FileName = 'another-1.2.3-full.nupkg' }
            'feed-count' { $index.Assets = @($index.Assets[0], $index.Assets[0]) }
        }
        $index | ConvertTo-Json -Depth 10 | Set-Content $feedPath -Encoding utf8
        Assert-RejectedWithoutMutation $directory
    }
    foreach ($missing in @('portable', 'setup', 'package', 'feed')) {
        $directory = New-Fixture "missing-$missing"
        $name = switch ($missing) {
            'portable' { "$legacyId-win-Portable.zip" }
            'setup' { "$legacyId-win-Setup.exe" }
            'package' { $legacyPackage }
            'feed' { 'releases.win.json' }
        }
        Remove-Item (Join-Path $directory $name)
        Assert-RejectedWithoutMutation $directory
    }
    $duplicate = New-Fixture 'two-packages'
    Copy-Item (Join-Path $duplicate $legacyPackage) (Join-Path $duplicate 'another-1.2.3-full.nupkg')
    Assert-RejectedWithoutMutation $duplicate
    Write-Host 'prepare-release.ps1: normalization and rejection-without-mutation fixtures passed.'
} finally {
    if (Test-Path $fixtureRoot) { Remove-Item $fixtureRoot -Recurse -Force }
}
