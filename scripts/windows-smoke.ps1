#requires -Version 5.1
<#
Install-and-launch smoke test for a release asset. Give it the zip or the installer:
  windows-smoke.ps1 -Asset windows\artifacts\release\Clio-1.1.2-win-x64.zip
  windows-smoke.ps1 -Asset windows\artifacts\release\Clio-1.1.2-win-x64-setup.exe
It installs into a temp directory, launches Clio.exe, checks it stays up, closes the window and checks
for a clean exit, then (installer only) uninstalls and checks the files and uninstall entry are gone.
It never uses a real document. It does create %LOCALAPPDATA%\Clio while the app runs; if that folder did
not exist before the run, it is removed afterwards.
#>
param(
    [Parameter(Mandatory)][string]$Asset,
    [int]$StaySeconds = 8,
    [int]$ExitTimeoutSeconds = 20
)
$ErrorActionPreference = 'Stop'
$Asset = (Resolve-Path $Asset).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("clio-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$target = Join-Path $work 'Clio'
$userData = Join-Path $env:LOCALAPPDATA 'Clio'
$userDataExisted = Test-Path $userData
$installer = $Asset.EndsWith('.exe')
New-Item -ItemType Directory -Force $work | Out-Null
$failed = $null

function Fail($msg) { $script:failed = $msg; Write-Host "FAIL: $msg" }

try {
    if ($installer) {
        Write-Host ">> install $Asset -> $target"
        $p = Start-Process $Asset -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=`"$target`"", "/LOG=`"$work\install.log`"" -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "installer exit code $($p.ExitCode)" }
    } else {
        Write-Host ">> extract $Asset -> $work"
        Expand-Archive $Asset -DestinationPath $work -Force
    }
    $exe = Join-Path $target 'Clio.exe'
    if (-not (Test-Path $exe)) { throw "Clio.exe not found in $target" }
    foreach ($f in 'clio-mcp-bridge.exe', 'THIRD-PARTY-NOTICES.md', 'LICENSE-Hack.md') {
        if (-not (Test-Path (Join-Path $target $f))) { throw "missing $f in install" }
    }
    $info = (Get-Item $exe).VersionInfo
    Write-Host "   Clio.exe $($info.FileVersion)"

    Write-Host ">> launch, stay up $StaySeconds s"
    $app = Start-Process $exe -PassThru
    Start-Sleep -Seconds $StaySeconds
    if ($app.HasExited) { throw ("Clio exited early with 0x{0:X}" -f $app.ExitCode) }
    $app.Refresh()
    if ($app.MainWindowHandle -eq 0) { Fail 'no main window after launch' }

    Write-Host '>> close window, expect clean exit'
    [void]$app.CloseMainWindow()
    if (-not $app.WaitForExit($ExitTimeoutSeconds * 1000)) {
        Stop-Process $app -Force
        Fail "did not exit within $ExitTimeoutSeconds s of closing the window"
    } elseif ($app.ExitCode -ne 0) {
        Fail ("exit code 0x{0:X}" -f $app.ExitCode)
    }

    if ($installer) {
        Write-Host '>> uninstall'
        $unins = Join-Path $target 'unins000.exe'
        if (-not (Test-Path $unins)) { throw 'unins000.exe missing' }
        $u = Start-Process $unins -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
        if ($u.ExitCode -ne 0) { Fail "uninstaller exit code $($u.ExitCode)" }
        # The uninstaller finishes by self-deleting; give it a moment.
        for ($i = 0; $i -lt 20 -and (Test-Path $exe); $i++) { Start-Sleep -Milliseconds 500 }
        if (Test-Path $exe) { Fail 'Clio.exe still present after uninstall' }
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F1D7C0E-3B52-4C0B-9D9E-5A2C41F0A7B3}_is1'
        if (Test-Path $key) { Fail 'uninstall registry entry still present' }
        if (Test-Path 'HKCU:\Software\Classes\Clio.Markdown') { Fail 'Clio.Markdown association key left behind' }
    }
} catch {
    Fail $_.Exception.Message
} finally {
    Get-Process -Name Clio -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($work, 'OrdinalIgnoreCase') } | Stop-Process -Force
    if (-not $userDataExisted -and (Test-Path $userData)) { Remove-Item $userData -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed) { throw "smoke test failed: $failed" }
Write-Host 'smoke test passed'
