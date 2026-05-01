param(
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

    Write-Host ("  {0,-16} {1}" -f ($Label + ":"), $Value)
}

function Resolve-IsccPath {
    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $fallbacks = @(
            "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
            "C:\Program Files\Inno Setup 6\ISCC.exe",
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
        )

        foreach ($fallback in $fallbacks) {
            if (Test-Path $fallback) {
                $iscc = Get-Item $fallback
                break
            }
        }
    }

    if (-not $iscc) {
        throw "ISCC.exe was not found. Install Inno Setup 6 and try again."
    }

    if ($iscc.Source) {
        return $iscc.Source
    }
    if ($iscc.Path) {
        return $iscc.Path
    }

    return $iscc.FullName
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

function Sign-ProjectArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Certificate,
        [string]$TimestampServer
    )

    $signingParams = @{
        FilePath = $Path
        Certificate = $Certificate
        HashAlgorithm = "SHA256"
    }

    if ($TimestampServer) {
        $signingParams.TimestampServer = $TimestampServer
    }

    $signature = Set-AuthenticodeSignature @signingParams

    if ($signature.Status -ne "Valid") {
        throw "Signing failed for $Path`: $($signature.Status) - $($signature.StatusMessage)"
    }

    Write-BuildInfo "Signed" $Path
}

function Get-ArtifactInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Artifact not found: $Path"
    }

    $item = Get-Item $Path
    $hash = (Get-FileHash $Path -Algorithm SHA256).Hash

    return [PSCustomObject]@{
        Name = $item.Name
        FullName = $item.FullName
        Length = $item.Length
        Sha256 = $hash
    }
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Sync-InnoAppVersion {
    $sourcePath = Join-Path $repoRoot "Coinflip_V1.10.pb"
    $installerPath = Join-Path $repoRoot "coinflip.iss"
    $sourceText = Get-Content -LiteralPath $sourcePath -Raw

    if ($sourceText -notmatch '(?m)^#AppVersion\$\s*=\s*"([^"]+)"') {
        throw "Could not read #AppVersion$ from $sourcePath."
    }

    $appVersion = $Matches[1]
    $installerText = Get-Content -LiteralPath $installerPath -Raw
    $updatedInstallerText = [regex]::Replace(
        $installerText,
        '(?m)^#define AppVersion "[^"]+"',
        '#define AppVersion "' + $appVersion + '"',
        1
    )

    Set-Content -LiteralPath $installerPath -Value $updatedInstallerText -NoNewline
    Write-BuildInfo "Installer version" $appVersion
}
Push-Location $repoRoot
try {
    Write-Host ""
    Write-Host "Coinflip installer build"
    Write-BuildInfo "Repository" $repoRoot

    .\build-purebasic.ps1 -CertificateThumbprint $CertificateThumbprint -TimestampUrl $TimestampUrl

    Write-Host ""
    Write-Host "Installer package"
    Sync-InnoAppVersion

    $isccPath = Resolve-IsccPath
    $isccArgs = @("/Q", ".\coinflip.iss")
    Write-BuildInfo "Inno compiler" $isccPath
    Write-BuildInfo "Compiler mode" "Quiet"
    Write-BuildInfo "Script" (Join-Path $repoRoot "coinflip.iss")

    if (Test-Path (Join-Path $repoRoot "Noto_Emoji_Coin.ico")) {
        $isccArgs += "/DHasAppIcon=1"
        Write-BuildInfo "Installer icon" (Join-Path $repoRoot "Noto_Emoji_Coin.ico")
    }
    else {
        Write-Warning "Installer icon was referenced but not found: Noto_Emoji_Coin.ico"
    }

    & $isccPath @isccArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed."
    }

    $setupPath = Join-Path $repoRoot "build\Coinflip_V1.10_Setup.exe"
    if ($CertificateThumbprint) {
        $certificate = Get-CodeSigningCertificate -Thumbprint $CertificateThumbprint
        Sign-ProjectArtifact -Path $setupPath -Certificate $certificate -TimestampServer $TimestampUrl
        Write-BuildInfo "Installer signer" $certificate.Subject
    }

    Write-Host ""
    Write-Host "Build artifacts"
    foreach ($artifactPath in @(
        (Join-Path $repoRoot "build\Coinflip_V1.10.exe"),
        $setupPath
    )) {
        $info = Get-ArtifactInfo -Path $artifactPath
        Write-Host ("  {0}" -f $info.Name)
        Write-Host ("    Path:   {0}" -f $info.FullName)
        Write-Host ("    Size:   {0:N0} bytes" -f $info.Length)
        Write-Host ("    SHA256: {0}" -f $info.Sha256)
    }

    Write-Host ""
    Write-Host "Installer build complete."
    Write-BuildInfo "Output" $setupPath
}
finally {
    Pop-Location
}
