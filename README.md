# Coin-Flip Deviation Simulator

PureBasic x64 desktop application for large-scale fair-coin simulation, deviation analysis, and high-throughput benchmarking.

The program runs repeated coin-flip samples and records the absolute deviation

```text
|Heads - ExpectedHeads|
```

for each sample. It supports both strict bit-level simulation and direct binomial sampling, with multithreaded execution, optional binary output, and a live distribution plot.

## What it does

For each sample:

- `1 bit = 1 coin flip`
- `1 = heads`, `0 = tails`
- the simulator computes the absolute deviation from the expected 50/50 result

The default workload is **350,757 flips per sample**, but the value can be changed in the GUI.

## Main features

- Windows **x64** PureBasic GUI application
- Multithreaded worker model for large simulation runs
- Two simulation paths:
  - **BIT-EXACT**: generates random bits and counts heads directly
  - **BINOMIAL**: samples heads from `Binomial(n, 0.5)` and computes the same deviation metric
- Multiple binomial engines:
  - **BTPE exact**
  - **BTRD exact**
  - **CLT K approximation**
  - **CPython-style exact** sampler path
- Automatic or forced kernel selection for bit-exact mode
- Optional buffered output to raw `.data` files
- Live bell-curve style plot and threshold markers
- Ability to load saved `.data` files back into the plot view
- Optional embedded ONNX Runtime self-test for diagnostics only

## CPU paths used in BIT-EXACT mode

The source includes several execution paths and selects the fastest supported route:

- portable scalar popcount fallback
- scalar **POPCNT**
- **AVX2** popcount emulation
- **AVX-512 VPOPCNTQ** when supported by both CPU and OS

Because the source uses inline x86-64 assembly for feature detection and optimized paths, it is **not intended for non-x86-64 targets**.

## Output format

When file output is enabled, the program writes one 16-bit value per sample:

```text
deviation_clamped = Clamp(|Heads - n/2|, 0..65535)
```

Output files are raw little-endian binary streams, typically named like:

```text
Coinflip_V1.10.data
```

That means:

- **2 bytes per sample**
- total file size = `number_of_samples × 2`

## Build requirements

- **PureBasic x64**
- **Windows** target
- **Thread Safe** runtime enabled in compiler options
- **Inno Setup 6** for installer builds
- Recommended: compile **without the debugger** for performance testing

## Command-line build

`pbcompiler` is available on this machine, and the repo now includes a build helper.

Build the default app with:

```powershell
.\build-purebasic.ps1
```

The script compiles:

- `Coinflip_V1.10.pb`
- with `Thread Safe` enabled
- with optimizer enabled
- into `build/Coinflip_V1.10.exe`
- with the Noto Emoji coin icon referenced by the PureBasic IDE `UseIcon` setting

Build the installer with:

```powershell
.\build-installer.ps1
```

The installer script builds the app first, then creates:

- `build/Coinflip_V1.10.exe`
- `build/Coinflip_V1.10_Setup.exe`

To sign the compiled EXE and installer with a certificate already installed in the Windows certificate store:

```powershell
.\build-installer.ps1 -CertificateThumbprint "<YOUR_CERT_THUMBPRINT>"
```

To add RFC 3161 timestamping during signing:

```powershell
.\build-installer.ps1 -CertificateThumbprint "<YOUR_CERT_THUMBPRINT>" -TimestampUrl "<YOUR_TIMESTAMP_URL>"
```

You can inspect local code-signing certificates with:

```powershell
Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My |
  Where-Object {
    $_.HasPrivateKey -and (
      $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.3' -or
      $_.EnhancedKeyUsageList.FriendlyName -contains 'Code Signing'
    )
  } |
  Select-Object Subject, Thumbprint, NotAfter
```

## Smart App Control note

For Windows Smart App Control compatibility, Microsoft currently requires the app to be signed with an RSA-based code-signing certificate from a trusted provider, or through Microsoft Trusted Signing. A self-signed certificate or an internal test certificate may produce a digital signature, but it will not make Smart App Control trust the app.

## Releases

Tagged releases are intended to use the format `v*`.

The repository includes a self-hosted GitHub Actions workflow at [`.github/workflows/release-self-hosted.yml`](.github/workflows/release-self-hosted.yml) for Windows builds. It is designed for a controlled Windows runner with PureBasic and Inno Setup installed and can optionally sign the build if a trusted certificate thumbprint is provided through repository secrets.

Until the project completes SignPath Foundation onboarding or another trusted signing setup, release binaries may be unsigned.

Release steps are summarized in [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md).

## Code signing policy

The project code-signing and release-signing rules are documented in [`CODE_SIGNING_POLICY.md`](CODE_SIGNING_POLICY.md).

For SignPath Foundation onboarding preparation, see [`SIGNPATH_APPLICATION.md`](SIGNPATH_APPLICATION.md).

## Privacy

This program does not transfer information to other networked systems unless specifically requested by the user or the person installing or operating it.

## Optional runtime dependency

The program can perform a one-time embedded ONNX Runtime self-test if `onnxruntime.dll` is available.

This is **diagnostic only**. The simulator itself does not depend on ONNX Runtime for its core sampling logic.

## Installer behavior

The installer:

- installs into `Program Files\Coinflip`
- creates a Start menu shortcut
- can create a desktop shortcut if selected during setup
- offers to launch Coinflip after installation
- supports repair install from Windows Apps/Programs maintenance
- supports uninstall from Windows Apps/Programs maintenance
- does not add startup entries
- does not use tray behavior
- removes installed files and shortcuts during uninstall

## Third-party credits

The Coinflip application icon uses the Noto Emoji coin image by Google, distributed under the Apache License 2.0. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for source and license details.

## How to use

1. Open the source in PureBasic.
2. Compile for **Windows x64** with **Thread Safe** enabled.
3. Run the program.
4. Choose:
   - flips per sample
   - instances per run-block
   - run-blocks per thread
   - sampler mode
   - binomial method if BINOMIAL mode is selected
5. Start the run.
6. Watch progress, throughput, sigma-scaled maxima, and the live plot.
7. Optionally save output to a `.data` file for later analysis.

## Repository contents

```text
Coinflip_V1.10.pb
coinflip.iss
build-purebasic.ps1
build-installer.ps1
Noto_Emoji_Coin.ico
Noto_Emoji_Coin.png
README.md
THIRD_PARTY_NOTICES.md
CODE_SIGNING_POLICY.md
RELEASE_CHECKLIST.md
SIGNPATH_APPLICATION.md
SIGNPATH_EMAIL_DRAFT.md
LICENSE
```

## Intended use

This project is aimed at:

- statistical deviation experiments
- throughput and kernel benchmarking
- large-run randomness studies at the deviation level
- comparing exact bit simulation with direct binomial sampling

## License

This project is licensed under the **GNU General Public License v3.0** (**GPL-3.0**).

See the [LICENSE](LICENSE) file for the full license text.

## Author

John Torset
