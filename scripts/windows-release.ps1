#requires -Version 5.1
<#
Builds the unsigned Windows x64 release assets into windows\artifacts\release:
  Clio-<version>-win-x64.zip            self-contained app + clio-mcp-bridge.exe + notices
  Clio-<version>-win-x64-setup.exe      per-user Inno Setup installer (needs ISCC.exe)
  SHA256SUMS-windows.txt
The version comes from project.yml (see windows-version.ps1). Builds are unsigned.
#>
param(
    [switch]$SkipTests,
    [switch]$RequireInstaller,   # fail instead of warn when Inno Setup is missing
    [string]$ExpectTag           # e.g. v1.1.2; must match project.yml
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$win = Join-Path $repo 'windows'
$v = & (Join-Path $PSScriptRoot 'windows-version.ps1')
if ($ExpectTag -and $ExpectTag -ne "v$($v.Version)") { throw "tag $ExpectTag does not match project.yml version $($v.Version)" }

$artifacts = Join-Path $win 'artifacts'
$out = Join-Path $artifacts 'release'
$stage = Join-Path $out 'stage\Clio'
if (Test-Path $artifacts) { Remove-Item $artifacts -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

function Step($cmd) { Write-Host ">> $cmd"; Invoke-Expression $cmd; if ($LASTEXITCODE -ne 0) { throw "failed: $cmd" } }
$ver = "-p:Version=$($v.Version) -p:FileVersion=$($v.FileVersion) -p:InformationalVersion=$($v.Version)"

Push-Location $win
try {
    Step "dotnet build Clio.slnx -c Release $ver"
    if (-not $SkipTests) {
        foreach ($t in 'Core', 'Editor', 'Export', 'Intelligence', 'Mcp') { Step "dotnet test Clio.$t.Tests -c Release --no-build" }
    }
    Step "dotnet publish Clio.App -c Release -p:Platform=x64 $ver -o `"$stage`""
    # The stdio bridge ships next to Clio.exe as one self-contained file, launched by the MCP client.
    Step "dotnet publish Clio.McpBridge -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:PublishTrimmed=true $ver -o `"$stage`""
} finally { Pop-Location }

foreach ($f in 'Clio.exe', 'clio-mcp-bridge.exe') {
    if (-not (Test-Path (Join-Path $stage $f))) { throw "missing $f in publish output" }
}
Get-ChildItem $stage -Filter *.pdb | Remove-Item -Force

# Notices and licences ship with the binaries (Hack is OFL: the licence must travel with the font).
Copy-Item (Join-Path $repo 'Clio\Resources\THIRD-PARTY-NOTICES.md') $stage
Copy-Item (Join-Path $repo 'Clio\Resources\Fonts\LICENSE-Hack.md') $stage
foreach ($lic in 'LICENSE', 'LICENSE.md', 'LICENSE.txt') {
    if (Test-Path (Join-Path $repo $lic)) { Copy-Item (Join-Path $repo $lic) $stage }
}
Copy-Item (Join-Path $win 'installer\README-Windows.txt') $stage

# Zip: one top-level folder so extraction never scatters files.
$zip = Join-Path $out "Clio-$($v.Version)-win-x64.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $stage -Parent), $zip, [IO.Compression.CompressionLevel]::Optimal, $false)

# Installer.
$iscc = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($iscc) {
    Step "& `"$iscc`" /Qp `"/DAppVersion=$($v.Version)`" `"/DFileVersion=$($v.FileVersion)`" `"/DSourceDir=$stage`" `"/DOutputDir=$out`" `"$win\installer\Clio.iss`""
} elseif ($RequireInstaller) {
    throw 'Inno Setup (ISCC.exe) not found'
} else {
    Write-Warning 'Inno Setup not found: installer skipped. Install it (https://jrsoftware.org/isinfo.php) to build it.'
}

# Checksums in `sha256sum -c` format.
$assets = Get-ChildItem $out -File | Where-Object { $_.Extension -in '.zip', '.exe' }
$lines = foreach ($a in $assets) { "$((Get-FileHash $a.FullName -Algorithm SHA256).Hash.ToLower())  $($a.Name)" }
[IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS-windows.txt'), (($lines -join "`n") + "`n"))
Remove-Item (Join-Path $out 'stage') -Recurse -Force
Write-Host "`nRelease assets in ${out}:"
Get-ChildItem $out | ForEach-Object { '{0,12:N0}  {1}' -f $_.Length, $_.Name }
