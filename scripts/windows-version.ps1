#requires -Version 5.1
# Single source of truth for the Windows version: project.yml MARKETING_VERSION / CURRENT_PROJECT_VERSION,
# the same values the macOS app ships. Run this file; it returns an object with Version, Build, FileVersion.
$yml = Get-Content (Join-Path $PSScriptRoot '..\project.yml') -Raw
$m = [regex]::Match($yml, '(?m)^\s*MARKETING_VERSION:\s*"?(\d+\.\d+\.\d+)"?\s*$')
$b = [regex]::Match($yml, '(?m)^\s*CURRENT_PROJECT_VERSION:\s*"?(\d+)"?\s*$')
if (-not $m.Success -or -not $b.Success) { throw 'project.yml has no MARKETING_VERSION / CURRENT_PROJECT_VERSION' }
[pscustomobject]@{
    Version     = $m.Groups[1].Value
    Build       = $b.Groups[1].Value
    FileVersion = "$($m.Groups[1].Value).$($b.Groups[1].Value)"
}
