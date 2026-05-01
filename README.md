# Coinflip

Coinflip is a Windows x64 PureBasic desktop application for high-volume fair-coin simulation, deviation analysis, and throughput benchmarking.

For each sample, Coinflip runs a fair-coin experiment and records the absolute deviation from the expected 50/50 result:

```text
|Heads - ExpectedHeads|
```

It can run strict bit-level simulations, sample directly from a binomial distribution, save raw deviation data, and plot live or loaded results against a bell curve.

## What It Does

For each sample:

- `1 bit = 1 coin flip`
- `1 = heads`, `0 = tails`
- Coinflip computes the absolute deviation from the expected number of heads

The default workload is **350,757 flips per sample**, and the value can be changed in the GUI.

## Features

- Windows x64 PureBasic GUI
- Multithreaded worker model for large simulation runs
- Bit-exact mode: generate random bits and count heads directly
- Binomial mode: sample heads from `Binomial(n, 0.5)` and compute the same deviation metric
- Multiple binomial engines:
  - BTPE exact
  - BTRD exact
  - CLT K approximation
  - CPython-style exact path
- Automatic or forced CPU kernel selection for bit-exact mode
- Optional buffered output to raw `.data` files
- Live bell-curve plot with threshold markers
- Loading of saved `.data` files back into the plot view

## CPU Paths

In bit-exact mode, Coinflip chooses the fastest supported counting path:

- portable scalar popcount fallback
- scalar POPCNT
- AVX2 popcount emulation
- AVX-512 VPOPCNTQ when supported by both CPU and OS

The source uses inline x86-64 assembly for CPU feature detection and optimized paths, so it is not intended for non-x86-64 targets.

## Output Format

When file output is enabled, Coinflip writes one 16-bit value per sample:

```text
deviation_clamped = Clamp(|Heads - n/2|, 0..65535)
```

Output files are raw little-endian binary streams, typically named like:

```text
Coinflip_V1.10.data
```

That means:

- 2 bytes per sample
- total file size = `number_of_samples x 2`

## Versioning

The public source and artifact names stay at `V1.10`, while build scripts stamp a full build version:

```text
1.10.YYMM.minute-of-month
```

For example, a May 2026 build may report a version such as `V1.10.2605.01042` in the app and installer metadata.

## Build Requirements

- Windows x64 target
- PureBasic x64
- PureBasic Thread Safe runtime enabled
- Inno Setup 6 for installer builds
- Recommended: compile without the debugger for performance testing

## Build Commands

Build the app:

```powershell
.\build-purebasic.ps1
```

This compiles `Coinflip_V1.10.pb` into:

```text
build\Coinflip_V1.10.exe
```

Build the installer:

```powershell
.\build-installer.ps1
```

This builds the app first, then creates:

```text
build\Coinflip_V1.10_Setup.exe
```

To sign the EXE and installer with a code-signing certificate already installed in the Windows certificate store:

```powershell
.\build-installer.ps1 -CertificateThumbprint "<YOUR_CERT_THUMBPRINT>"
```

To add RFC 3161 timestamping:

```powershell
.\build-installer.ps1 -CertificateThumbprint "<YOUR_CERT_THUMBPRINT>" -TimestampUrl "<YOUR_TIMESTAMP_URL>"
```

## Installer Behavior

The installer:

- installs into `Program Files\Coinflip`
- creates a desktop shortcut automatically
- does not create Start Menu shortcuts
- includes a user-focused README, license, and third-party notices
- provides installer buttons to read those included files before installation
- closes a running Coinflip process before install, repair, reinstall, or uninstall file operations
- offers to launch Coinflip after installation
- supports repair and uninstall from Windows Apps/Programs maintenance
- does not add startup entries
- does not use tray behavior
- removes installed files and the desktop shortcut during uninstall

## Smart App Control

For Windows Smart App Control compatibility, Microsoft currently requires an RSA-based code-signing certificate from a trusted provider, or Microsoft Trusted Signing. A self-signed or internal test certificate can produce a digital signature, but it will not make Smart App Control trust the app.

## Releases

Tagged releases are intended to use the format `v*`.

The repository includes a self-hosted GitHub Actions workflow at [`.github/workflows/release-self-hosted.yml`](.github/workflows/release-self-hosted.yml) for controlled Windows builds with PureBasic and Inno Setup installed. The workflow can optionally sign artifacts when a trusted certificate thumbprint is provided through repository secrets.

Release steps are summarized in [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md).

## Code Signing Policy

The code-signing and release-signing rules are documented in [`CODE_SIGNING_POLICY.md`](CODE_SIGNING_POLICY.md).

For SignPath Foundation onboarding preparation, see [`SIGNPATH_APPLICATION.md`](SIGNPATH_APPLICATION.md).

## Privacy

Coinflip does not transfer information to other networked systems unless specifically requested by the user or the person installing or operating it.

## How To Use

1. Run Coinflip.
2. Choose the flips per sample, instances per run-block, run-blocks per thread, sampler mode, and thread policy.
3. If using binomial mode, choose the binomial method.
4. Optionally enable `.data` output.
5. Start the run.
6. Watch progress, throughput, sigma-scaled maxima, and the live plot.
7. Load saved `.data` files later for plot analysis if needed.

## Repository Contents

```text
Coinflip_V1.10.pb
Coinflip.code-workspace
coinflip.iss
build-purebasic.ps1
build-installer.ps1
installer-wizard-image.bmp
installer-wizard-small.bmp
Noto_Emoji_Coin.ico
Noto_Emoji_Coin.png
README.md
INSTALLER_README.md
THIRD_PARTY_NOTICES.md
CODE_SIGNING_POLICY.md
RELEASE_CHECKLIST.md
SIGNPATH_APPLICATION.md
SIGNPATH_EMAIL_DRAFT.md
LICENSE
```

## Intended Use

Coinflip is intended for:

- statistical deviation experiments
- throughput and kernel benchmarking
- large-run randomness studies at the deviation level
- comparing exact bit simulation with direct binomial sampling

## Third-Party Credits

The Coinflip application icon uses the Noto Emoji coin image by Google, distributed under the Apache License 2.0. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for source and license details.

## License

Coinflip is licensed under the MIT License. See [LICENSE](LICENSE) for the full license text.

## Author

John Torset
