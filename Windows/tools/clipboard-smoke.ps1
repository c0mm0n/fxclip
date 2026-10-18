param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
# WinForms/OLE clipboard writes require an STA thread.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    & (Get-Process -Id $PID).Path -STA -NoProfile -File $PSCommandPath -Executable $Executable
    exit $LASTEXITCODE
}
$process = $null
$temporary = Join-Path $env:RUNNER_TEMP ('fxclip-e2e-' + [guid]::NewGuid())
$originalAppData = $env:APPDATA
$result = 'FAIL: test did not finish'
$cases = [Collections.Generic.List[string]]::new()
function Check-Case([string]$Name, [scriptblock]$Check) {
    try { & $Check; $line = "PASS: $Name" }
    catch { $line = "FAIL: $Name — $($_.Exception.Message)" }
    $cases.Add($line)
    Write-Output $line
}
function Wait-Text([string]$Expected) {
    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 100
        if ($process.HasExited) { throw 'Published app exited while cleaning.' }
        $actual = [Windows.Forms.Clipboard]::GetText()
        if ($actual -ceq $Expected) { return }
    } while ((Get-Date) -lt $deadline)
    throw "Clipboard text did not match within eight seconds."
}
function Copy-Data([string]$Text, [switch]$Browser, [switch]$Excluded, [switch]$Restricted) {
    $data = [Windows.Forms.DataObject]::new()
    $data.SetText($Text, [Windows.Forms.TextDataFormat]::UnicodeText)
    if ($Browser) {
        $html = '<html><body><!--StartFragment--><a href="https://example.com/">link</a><!--EndFragment--></body></html>'
        $header = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
        $start = ($header -f 0,0,0,0).Length
        $cfHtml = ($header -f $start,($start + $html.Length),($start + $html.IndexOf('<a')),($start + $html.IndexOf('<!--EndFragment-->'))) + $html
        $data.SetText($cfHtml, [Windows.Forms.TextDataFormat]::Html)
        $data.SetData('Chromium internal source URL', $false, 'https://example.com/')
    }
    if ($Excluded) { $data.SetData('ExcludeClipboardContentFromMonitorProcessing', $false, [IO.MemoryStream]::new([byte[]](0,0,0,0))) }
    if ($Restricted) {
        foreach ($name in @('CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard')) {
            $data.SetData($name, $false, [IO.MemoryStream]::new([byte[]](0,0,0,0)))
        }
    }
    [Windows.Forms.Clipboard]::SetDataObject($data, $true)
}
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DesktopProbe {
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
    public static bool ZeroMarker(string name) {
        if (!OpenClipboard(IntPtr.Zero)) return false;
        try {
            var data = GetClipboardData(RegisterClipboardFormat(name));
            if (data == IntPtr.Zero) return false;
            var memory = GlobalLock(data);
            if (memory == IntPtr.Zero) return false;
            try { return Marshal.ReadInt32(memory) == 0; }
            finally { GlobalUnlock(data); }
        } finally { CloseClipboard(); }
    }
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
    Check-Case 'plain-text-raw-parameters' {
        Copy-Data 'https://example.com/path?keep=a%2Bb==&utm_source=ci&fbclid=tracking#fragment'
        Wait-Text 'https://example.com/path?keep=a%2Bb==#fragment'
    }
    Check-Case 'second-external-copy' {
        Copy-Data 'https://youtu.be/example?si=tracking&t=42'
        Wait-Text 'https://youtu.be/example?t=42'
    }
    Check-Case 'browser-html-metadata-cleaned' {
        Copy-Data 'https://example.com/?utm_source=browser&keep=1' -Browser
        Wait-Text 'https://example.com/?keep=1'
        $data = [Windows.Forms.Clipboard]::GetDataObject()
        if ($data.GetDataPresent('HTML Format') -or $data.GetDataPresent('Chromium internal source URL')) { throw 'Browser formats were not flattened to text.' }
    }
    Check-Case 'browser-rich-prose-preserved' {
        $text = 'Read https://example.com/?utm_source=browser'
        Copy-Data $text -Browser
        Start-Sleep -Seconds 1
        if ([Windows.Forms.Clipboard]::GetText() -cne $text -or ![Windows.Forms.Clipboard]::ContainsText([Windows.Forms.TextDataFormat]::Html)) { throw 'Rich prose was modified.' }
    }
    Check-Case 'excluded-source-untouched' {
        $text = 'https://example.com/?utm_source=excluded'
        Copy-Data $text -Browser -Excluded
        $sequence = [DesktopProbe]::GetClipboardSequenceNumber()
        Start-Sleep -Seconds 1
        if ([DesktopProbe]::GetClipboardSequenceNumber() -ne $sequence -or [Windows.Forms.Clipboard]::GetText() -cne $text -or ![Windows.Forms.Clipboard]::ContainsText([Windows.Forms.TextDataFormat]::Html)) { throw 'Excluded copy was modified.' }
    }
    Check-Case 'privacy-opt-outs-preserved' {
        Copy-Data 'https://example.com/?utm_source=private' -Restricted
        Wait-Text 'https://example.com/'
        foreach ($name in @('CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard')) {
            if (![DesktopProbe]::ZeroMarker($name)) { throw "Missing zero-valued $name marker." }
        }
    }
    if ($cases | Where-Object { $_.StartsWith('FAIL:') }) { throw 'One or more clipboard cases failed.' }
    if (!(Test-Path (Join-Path $temporary 'fxclip/settings.json'))) { throw 'Isolated settings file was not created.' }
    $result = 'PASS: all six published clipboard cases; usable desktop and clipboard confirmed.'
    Write-Output $result
} catch {
    if (!$result.StartsWith('UNAVAILABLE:')) { $result = 'FAIL: ' + $_.Exception.Message }
    Write-Warning $result
    throw
} finally {
    $env:APPDATA = $originalAppData
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path $temporary) { Remove-Item $temporary -Recurse -Force }
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY "Clipboard end-to-end: $result"
        foreach ($line in $cases) { Add-Content $env:GITHUB_STEP_SUMMARY "- $line" } }
}
