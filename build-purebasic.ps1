param(
    [string]$Source = ".\Coinflip_V1.12.pb",
    [string]$OutputDir = ".\build",
    [string]$CertificateThumbprint,
    [string]$TimestampUrl
)

$ErrorActionPreference = "Stop"

function Write-BuildInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    Write-Host ("  {0,-14} {1}" -f ($Label + ":"), $Value)
}

function Get-CodeSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )

    $normalizedThumbprint = ($Thumbprint -replace "\s", "").ToUpperInvariant()
    $stores = @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")

    foreach ($store in $stores) {
        $match = Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Thumbprint -eq $normalizedThumbprint -and
                $_.HasPrivateKey -and
                (
                    $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.3" -or
                    $_.EnhancedKeyUsageList.FriendlyName -contains "Code Signing"
                )
            } |
            Select-Object -First 1

        if ($match) {
            return $match
        }
    }

    throw "Code-signing certificate not found for thumbprint $normalizedThumbprint in Cert:\CurrentUser\My or Cert:\LocalMachine\My."
}

function Get-PureBasicIdeIconPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $iconLine = Get-Content -Path $SourcePath |
        Where-Object { $_ -match "^\s*;\s*UseIcon\s*=\s*(.+?)\s*$" } |
        Select-Object -Last 1

    if (-not $iconLine) {
        return $null
    }

    $iconValue = ($iconLine -replace "^\s*;\s*UseIcon\s*=\s*", "").Trim()
    if ([string]::IsNullOrWhiteSpace($iconValue)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($iconValue)) {
        return $iconValue
    }

    return Join-Path (Split-Path -Parent $SourcePath) $iconValue
}
function Update-PureBasicAppVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $now = Get-Date
    $monthStart = Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 0 -Second 0
    $minutesSinceMonthStart = [int][Math]::Floor(($now - $monthStart).TotalMinutes)
    $appVersion = "1.12.{0}.{1:D5}" -f $now.ToString("yyMM"), $minutesSinceMonthStart

    $content = Get-Content -LiteralPath $Path -Raw
    $versionPattern = '(?m)^#AppVersion\$\s*=\s*"[^"]*"'

    if ($content -notmatch $versionPattern) {
        throw "App version constant not found in $Path."
    }

    $updated = [regex]::Replace($content, $versionPattern, '#AppVersion$     = "' + $appVersion + '"', 1)
    Set-Content -LiteralPath $Path -Value $updated -NoNewline

    return $appVersion
}

function Get-VersionedExeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$AppVersion
    )

    $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $projectName = $sourceBaseName -replace '_V\d+(\.\d+)*$', ''

    return "{0}_V{1}.exe" -f $projectName, $AppVersion
}

function Remove-StaleAppArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,
        [Parameter(Mandatory = $true)]
        [string]$ExeName
    )

    $artifactPrefix = $ExeName -replace '_V.+\.exe$', ''
    $staleArtifacts = @()
    $staleArtifacts += Get-ChildItem -Path $OutputRoot -Filter "${artifactPrefix}_V*.exe" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*_Setup.exe" -and $_.Name -ne $ExeName }
    $staleArtifacts += Get-ChildItem -Path $OutputRoot -Filter "${artifactPrefix}_V*.exe.sha256" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*_Setup.exe.sha256" -and $_.Name -ne "$ExeName.sha256" }

    $staleArtifacts | Remove-Item -Force
}

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
$appVersion = Update-PureBasicAppVersion -Path $resolvedSource
$outputRoot = Join-Path $repoRoot $OutputDir
$outputRoot = (New-Item -ItemType Directory -Path $outputRoot -Force).FullName

$exeName = Get-VersionedExeName -SourcePath $resolvedSource -AppVersion $appVersion
$outputPath = Join-Path $outputRoot $exeName
Remove-StaleAppArtifacts -OutputRoot $outputRoot -ExeName $exeName

Write-Host ""
Write-Host "Coinflip application build"
Write-BuildInfo "Source" $resolvedSource
Write-BuildInfo "Output" $outputPath
Write-BuildInfo "Version" $appVersion

$compileArgs = @($resolvedSource, "/THREAD", "/OPTIMIZER", "/DPIAWARE", "/OUTPUT", $outputPath)
$iconPath = Get-PureBasicIdeIconPath -SourcePath $resolvedSource
if ($iconPath) {
    if (Test-Path $iconPath) {
        $compileArgs += @("/ICON", $iconPath)
        Write-BuildInfo "Icon" $iconPath
    }
    else {
        Write-Warning "PureBasic IDE icon was referenced but not found: $iconPath"
    }
}

& $compiler.Source @compileArgs

if ($LASTEXITCODE -ne 0) {
    throw "PureBasic compilation failed."
}

Write-BuildInfo "Built" $outputPath

if ($CertificateThumbprint) {
    $certificate = Get-CodeSigningCertificate -Thumbprint $CertificateThumbprint

    $signingParams = @{
        FilePath = $outputPath
        Certificate = $certificate
        HashAlgorithm = "SHA256"
    }

    if ($TimestampUrl) {
        $signingParams.TimestampServer = $TimestampUrl
    }

    $signature = Set-AuthenticodeSignature @signingParams

    if ($signature.Status -ne "Valid") {
        throw "Signing failed: $($signature.Status) - $($signature.StatusMessage)"
    }

    Write-BuildInfo "Signed" $outputPath
    Write-BuildInfo "Signer" $certificate.Subject
}
