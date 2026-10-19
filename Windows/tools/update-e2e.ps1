$ErrorActionPreference = 'Stop'
$proof = Join-Path $pwd 'Windows/update-proof'
$root = Join-Path $env:RUNNER_TEMP ('fxclip-update-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $root,$proof | Out-Null
$priorAppData = $env:APPDATA
$server = $null
try {
    foreach ($version in @('1.0.0','1.0.1')) {
        $publish = Join-Path $root "publish-$version"
        dotnet publish Windows/Fxclip -c Release -r win-x64 --self-contained true -o $publish "-p:Version=$version" "-p:AssemblyVersion=$version.0" "-p:FileVersion=$version.0" -p:DefineConstants=UPDATE_TESTING -p:ContinuousIntegrationBuild=true
        if ($LASTEXITCODE -ne 0) { throw 'QA publish failed' }
        $releases = Join-Path $root "release-$version"
        ./Windows/vpk/vpk.exe pack --packId FxclipUpdateQA --packTitle 'fxclip Update QA' --packAuthors c0mm0n --packVersion $version --packDir $publish --mainExe fxclip.exe --delta None --outputDir $releases --skip-updates
        if ($LASTEXITCODE -ne 0) { throw 'QA pack failed' }
    }
    $log = Join-Path $proof 'requests.log'
    $portFile = Join-Path $root 'port'
    $server = Start-Process python -ArgumentList 'Windows/tools/update-server.py', (Join-Path $root 'release-1.0.1'), $log, $portFile -PassThru -NoNewWindow
    for ($i=0; $i -lt 50 -and !(Test-Path $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $base = 'http://127.0.0.1:' + (Get-Content $portFile -Raw)
    $env:APPDATA = Join-Path $root 'appdata'
    $data = Join-Path $env:APPDATA 'fxclip'
    New-Item -ItemType Directory $data -Force | Out-Null
    Set-Content (Join-Path $data 'settings.json') '{"trackersEverywhere":false}' -NoNewline
    Set-Content (Join-Path $data 'preferences.json') '{"trackersRemoved":42}' -NoNewline
    $settingsHash = (Get-FileHash (Join-Path $data 'settings.json')).Hash
    function New-Portable($name) {
        $destination = Join-Path $root $name
        Expand-Archive (Get-ChildItem (Join-Path $root 'release-1.0.0') -Filter '*-Portable.zip').FullName $destination
        $exe = Get-ChildItem $destination -Filter fxclip.exe -Recurse | Select-Object -First 1
        if (!$exe) { throw 'Portable entry point missing' }
        return $exe.FullName
    }
    function Run-Phase($exe, $phase, $source, $resultName) {
        $result = Join-Path $proof "$resultName.json"
        $process = Start-Process $exe -ArgumentList '--update-test', $phase, $source, $result -PassThru
        if (!$process.WaitForExit(120000)) { $process.Kill(); throw "Timed out: $phase" }
        if ($process.ExitCode -ne 0) { if (Test-Path $result) { Get-Content $result }; throw "Failed: $phase" }
        # The pending phase exits before Update.exe replaces files and starts the verifier.
        for ($i=0; $i -lt 300 -and !(Test-Path $result); $i++) { Start-Sleep -Milliseconds 200 }
        if (!(Test-Path $result)) { throw "Missing result: $phase" }
        $value = Get-Content $result -Raw | ConvertFrom-Json
        if ($value.status -ne 'passed') { throw "Unexpected result: $phase" }
        if ((Get-FileHash (Join-Path $data 'settings.json')).Hash -ne $settingsHash) { throw 'Settings changed' }
    }
    $exe = New-Portable 'installed'
    Run-Phase $exe 'offline-default' "$base/normal" 'offline-default'
    if (Test-Path $log) { throw 'Network request without consent' }
    Run-Phase $exe 'decline' "$base/normal" 'decline'
    if (Select-String $log -Pattern '\.nupkg') { throw 'Download before confirmation' }
    Run-Phase (New-Portable 'cancel') 'cancel' "$base/slow" 'cancel'
    Run-Phase (New-Portable 'corrupt') 'corrupt' "$base/corrupt" 'corrupt'
    Run-Phase $exe 'older' "$base/older" 'older'
    Run-Phase $exe 'network' 'http://127.0.0.1:1/unavailable' 'network-error'
    Run-Phase $exe 'automatic' "$base/normal" 'automatic-daily'
    Run-Phase $exe 'download' "$base/normal" 'download'
    Run-Phase $exe 'pending' "$base/normal" 'installed-and-relaunched'
    # Verify a real replacement: the current executable's version and unchanged AppData.
    if ((Get-Content (Join-Path $proof 'installed-and-relaunched.json') -Raw | ConvertFrom-Json).version -ne '1.0.1') { throw 'New version not running' }
    $running = @(Get-Process fxclip -ErrorAction SilentlyContinue | Where-Object { $_.Path.StartsWith($root) })
    if ($running.Count -gt 1) { throw 'Duplicate instances after update' }
    # Exercise the real per-user setup, including an enabled login entry left by the legacy ZIP.
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $priorLogin = (Get-ItemProperty -Path $runKey -Name fxclip -ErrorAction SilentlyContinue).fxclip
    try {
        New-Item $runKey -Force | Out-Null
        Set-ItemProperty $runKey -Name fxclip -Value ('"' + $exe + '"')
        $installed = Join-Path $root 'setup-install'
        $setup = (Get-ChildItem (Join-Path $root 'release-1.0.0') -Filter '*-Setup.exe').FullName
        $result = Join-Path $proof 'setup-login-migration.json'
        $process = Start-Process $setup -ArgumentList '--silent', '--installto', $installed, '--', '--update-test', 'migrate-login', "$base/normal", $result -PassThru
        if (!$process.WaitForExit(120000) -or $process.ExitCode -ne 0) { throw 'Per-user setup failed' }
        for ($i=0; $i -lt 150 -and !(Test-Path $result); $i++) { Start-Sleep -Milliseconds 200 }
        if (!(Test-Path $result) -or (Get-Content $result -Raw | ConvertFrom-Json).status -ne 'passed') { throw 'Setup launch/login migration failed' }
        $installedExe = Join-Path $installed 'current/fxclip.exe'
        Run-Phase $installedExe 'download' "$base/normal" 'setup-download'
        Run-Phase $installedExe 'pending' "$base/normal" 'setup-installed-and-relaunched'
    } finally {
        if ($priorLogin) { Set-ItemProperty $runKey -Name fxclip -Value $priorLogin }
        else { Remove-ItemProperty $runKey -Name fxclip -ErrorAction SilentlyContinue }
    }
    Add-Content $env:GITHUB_STEP_SUMMARY 'Real Velopack portable and per-user setup 1.0.0 → 1.0.1 replacement and relaunch passed; AppData preserved; opt-in, decline, cancellation, corrupt archive, pending restart and older-version checks passed.'
} finally {
    if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -Force }
    $env:APPDATA = $priorAppData
}
