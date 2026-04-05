param(
    [string]$Source = ".\Coinflip_V1.10.pb",
    [string]$OutputDir = ".\build",
    [string]$CertificateThumbprint,
    [string]$TimestampUrl
)

$ErrorActionPreference = "Stop"

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

    Write-Host "Signed:" $outputPath
    Write-Host "Signer:" $certificate.Subject
}
