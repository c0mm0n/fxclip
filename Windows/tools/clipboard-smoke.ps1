param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$process = $null
$temporary = Join-Path $env:RUNNER_TEMP ('fxclip-e2e-' + [guid]::NewGuid())
$originalAppData = $env:APPDATA
$result = 'FAIL: test did not finish'
try {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DesktopProbe {
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
}
'@
    $desktop = [DesktopProbe]::OpenInputDesktop(0, $false, 1)
    if ($desktop -eq [IntPtr]::Zero) {
        $result = 'UNAVAILABLE: OpenInputDesktop failed, Win32=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw $result
    }
    [void][DesktopProbe]::CloseDesktop($desktop)
    try {
        $probe = 'fxclip-desktop-probe-' + [guid]::NewGuid()
        Set-Clipboard -Value $probe
        if ((Get-Clipboard -Raw) -cne $probe) { throw 'clipboard probe did not round-trip' }
    } catch {
        $result = 'UNAVAILABLE: clipboard probe failed: ' + $_.Exception.Message
        throw $result
    }
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $env:APPDATA = $temporary
    $process = Start-Process -FilePath (Resolve-Path $Executable) -ArgumentList '--no-welcome' -PassThru
    Start-Sleep -Seconds 3
    if ($process.HasExited) { throw ('Published app exited before copy; exit code=' + $process.ExitCode) }
    $inputLink = 'https://example.com/path?keep=a%2Bb==&utm_source=ci&fbclid=tracking#fragment'
    $expected = 'https://example.com/path?keep=a%2Bb==#fragment'
    Set-Clipboard -Value $inputLink
    $deadline = (Get-Date).AddSeconds(12)
    do {
        Start-Sleep -Milliseconds 200
        $actual = Get-Clipboard -Raw
        if ($actual -ceq $expected) { break }
        if ($process.HasExited) { throw ('Published app exited while cleaning; exit code=' + $process.ExitCode) }
    } while ((Get-Date) -lt $deadline)
    if ($actual -cne $expected) { throw 'Published app did not clean the clipboard within 12 seconds.' }
    # A second external copy checks that our own write did not swallow later copies.
    Set-Clipboard -Value 'https://youtu.be/example?si=tracking&t=42'
    $deadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 200
        $actual = Get-Clipboard -Raw
    } while ($actual -cne 'https://youtu.be/example?t=42' -and (Get-Date) -lt $deadline)
    if ($actual -cne 'https://youtu.be/example?t=42') { throw 'Second external copy was not cleaned.' }
    if (!(Test-Path (Join-Path $temporary 'fxclip/settings.json'))) { throw 'Isolated settings file was not created.' }
    $result = 'PASS: published fxclip.exe cleaned two external clipboard copies and preserved raw parameters; usable desktop and clipboard confirmed.'
    Write-Output $result
} catch {
    if (!$result.StartsWith('UNAVAILABLE:')) { $result = 'FAIL: ' + $_.Exception.Message }
    Write-Warning $result
    throw
} finally {
    $env:APPDATA = $originalAppData
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path $temporary) { Remove-Item $temporary -Recurse -Force }
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY "Clipboard end-to-end: $result" }
}
