param(
    [string]$Source = ".\Coinflip_V1.10.pb",
    [string]$OutputDir = ".\build"
)

$ErrorActionPreference = "Stop"

$compiler = Get-Command pbcompiler -ErrorAction SilentlyContinue
if (-not $compiler) {
    throw "pbcompiler was not found on PATH. Open a new terminal and try again."
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourcePath = Join-Path $repoRoot $Source

if (-not (Test-Path $sourcePath)) {
    throw "Source file not found: $sourcePath"
}

$resolvedSource = (Resolve-Path $sourcePath).Path
$outputRoot = Join-Path $repoRoot $OutputDir
$null = New-Item -ItemType Directory -Path $outputRoot -Force

$exeName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedSource) + ".exe"
$outputPath = Join-Path $outputRoot $exeName

& $compiler.Source $resolvedSource /THREAD /OPTIMIZER /OUTPUT $outputPath

if ($LASTEXITCODE -ne 0) {
    throw "PureBasic compilation failed."
}

Write-Host "Built:" $outputPath

