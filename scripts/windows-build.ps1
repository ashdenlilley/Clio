#requires -Version 5.1
# Windows port gate: build everything warnings-as-errors, run tests, publish unpackaged x64.
$ErrorActionPreference = 'Stop'
$win = Join-Path $PSScriptRoot '..\windows'
Push-Location $win
try {
    function Step($cmd) { Write-Host ">> $cmd"; Invoke-Expression $cmd; if ($LASTEXITCODE -ne 0) { throw "failed: $cmd" } }
    Step 'dotnet build Clio.slnx -c Release'
    Step 'dotnet test Clio.Core.Tests -c Release'
    Step 'dotnet test Clio.Editor.Tests -c Release'
    Step 'dotnet test Clio.Export.Tests -c Release'
    Step 'dotnet test Clio.Mcp.Tests -c Release'
    Step 'dotnet test Clio.Intelligence.Tests -c Release'
    Step 'dotnet publish Clio.App -c Release -p:Platform=x64 -o artifacts\Clio'
    # The stdio bridge ships next to Clio.exe as one self-contained file, launched by the MCP client.
    Step 'dotnet publish Clio.McpBridge -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:PublishTrimmed=true -o artifacts\Clio'
} finally { Pop-Location }
