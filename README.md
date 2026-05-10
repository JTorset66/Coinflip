# Coinflip

Coinflip is a Windows x64 PureBasic desktop application for high-volume fair-coin simulation, deviation analysis, and throughput benchmarking.

For detailed operating instructions, controls, file behaviours, analysis reports, graph benchmarking, and troubleshooting, see [`USER_MANUAL.txt`](USER_MANUAL.txt).

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
- Run Log save/load/copy tools with separate persistent append setting
- Analyse window for visible-log summaries, model comparison, speed/fit checks, and graph selected/not-selected comparisons
- Analysis save/copy tools with a separate persistent append setting
- Help menu entries that open the installed user manual, README, license, and third-party notices as readable `.txt` files
- DPI-aware Windows layout that follows the active Windows display scaling setting
- Fixed 9/8 UI boost so a 200% Windows display renders controls and text closer to a 225% scale
- Startup opens directly maximized to the current Windows monitor work area
- Normal-window layout is based on the boosted DPI-aware `1200x760` layout, clamped to the available work area
- Fixed-size controls while resizing, with extra window space given to the graph, run log, and status areas
- Windows-controlled maximize behavior: the maximum window size follows the current monitor work area at any Windows DPI or View scale
- Numeric input boxes update when the user presses Enter or leaves the field
- Stable child-window clipping, redraw-batched control state changes, buffered helper text fields, buffered live-status/progress/plot canvases, and redraw-suppressed log appends to reduce flicker
- High-contrast progress percentage text drawn in white with a black outline
- Compact run log entries that keep planned setup separate from final results, with `cf/ms` speed text and named total-cf summaries

## Named Number Scale

The derived-values panel and run log keep exact counts, then add a readable short-scale summary for the total coin flips in the simulation. The run log writes planned total `cf` at the start, writes actual `cf` only when a run stops early, and writes exact throughput as `cf/ms` with a readable speed summary such as `about 102 million coin flips per millisecond`. These summaries use this short-scale table:

| Power of 10 | Zeros | Name |
| ----------: | ----: | ---- |
| `10^3` | 3 | thousand |
| `10^6` | 6 | million |
| `10^9` | 9 | billion |
| `10^12` | 12 | trillion |
| `10^15` | 15 | quadrillion |
| `10^18` | 18 | quintillion |
| `10^21` | 21 | sextillion |
| `10^24` | 24 | septillion |
| `10^27` | 27 | octillion |
| `10^30` | 30 | nonillion |
| `10^33` | 33 | decillion |
| `10^36` | 36 | undecillion |
| `10^39` | 39 | duodecillion |
| `10^42` | 42 | tredecillion |
| `10^45` | 45 | quattuordecillion |
| `10^48` | 48 | quindecillion |
| `10^51` | 51 | sexdecillion |
| `10^54` | 54 | septendecillion |
| `10^57` | 57 | octodecillion |
| `10^60` | 60 | novemdecillion |
| `10^63` | 63 | vigintillion |

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
Coinflip_V1.12.YYMM.minute-of-month.data
```

That means:

- 2 bytes per sample
- total file size = `number_of_samples x 2`

## Versioning

The public source file is `Coinflip_V1.12.pb`, while build scripts stamp a full build version into metadata and generated artifact filenames:

```text
1.12.YYMM.minute-of-month
```

For example, a May 2026 build may produce artifacts such as `Coinflip_V1.12.2605.01042.exe` and `Coinflip_V1.12.2605.01042_Setup.exe`.

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

Output executable:

```text
build\Coinflip_V1.12.YYMM.minute-of-month.exe
```

Build the installer:

```powershell
.\build-installer.ps1
```

The installer build creates:

```text
build\Coinflip_V1.12.YYMM.minute-of-month_Setup.exe
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
- includes readable `.txt` copies of the README, user manual, license, and third-party notices
- provides installer buttons to read those included files before installation in the user's chosen text editor
- provides Help menu entries for the installed user manual, README, license, and third-party notices
- closes a running Coinflip process before install, repair, reinstall, or uninstall file operations
- offers to launch Coinflip after installation
- supports repair and uninstall from Windows Apps/Programs maintenance
- does not add startup entries
- does not use tray behavior
- removes installed files and the desktop shortcut during uninstall

## Smart App Control

Windows Smart App Control requires an RSA-based code-signing certificate from a trusted provider, or Microsoft Trusted Signing. A self-signed or internal test certificate can produce a digital signature, but Smart App Control will not trust it.

## Releases

Tagged releases and release artifact filenames should use the full stamped version number, for example `v1.12.2605.01042`.

Current changelog and release notes:

- [`RELEASE_NOTES_v1.12.2605.14177.md`](RELEASE_NOTES_v1.12.2605.14177.md)
- [`RELEASE_NOTES_v1.10.2605.14030.md`](RELEASE_NOTES_v1.10.2605.14030.md)
- [`RELEASE_NOTES_v1.10.2605.13986.md`](RELEASE_NOTES_v1.10.2605.13986.md)
- [`RELEASE_NOTES_v1.10.2605.13972.md`](RELEASE_NOTES_v1.10.2605.13972.md)
- [`RELEASE_NOTES_v1.10.2605.13964.md`](RELEASE_NOTES_v1.10.2605.13964.md)
- [`RELEASE_NOTES_v1.10.2605.13948.md`](RELEASE_NOTES_v1.10.2605.13948.md)

Previous public release notes:

- [`RELEASE_NOTES_v1.10.2605.13930.md`](RELEASE_NOTES_v1.10.2605.13930.md)
- [`RELEASE_NOTES_v1.10.2605.13926.md`](RELEASE_NOTES_v1.10.2605.13926.md)
- [`RELEASE_NOTES_v1.10.2605.13920.md`](RELEASE_NOTES_v1.10.2605.13920.md)
- [`RELEASE_NOTES_v1.10.2605.13915.md`](RELEASE_NOTES_v1.10.2605.13915.md)
- [`RELEASE_NOTES_v1.10.2605.13904.md`](RELEASE_NOTES_v1.10.2605.13904.md)
- [`RELEASE_NOTES_v1.10.2605.13864.md`](RELEASE_NOTES_v1.10.2605.13864.md)
- [`RELEASE_NOTES_v1.10.2605.13824.md`](RELEASE_NOTES_v1.10.2605.13824.md)
- [`RELEASE_NOTES_v1.10.2605.13802.md`](RELEASE_NOTES_v1.10.2605.13802.md)
- [`RELEASE_NOTES_v1.10.2605.13794.md`](RELEASE_NOTES_v1.10.2605.13794.md)
- [`RELEASE_NOTES_v1.10.2605.13782.md`](RELEASE_NOTES_v1.10.2605.13782.md)
- [`RELEASE_NOTES_v1.10.2605.13767.md`](RELEASE_NOTES_v1.10.2605.13767.md)
- [`RELEASE_NOTES_v1.10.2605.10737.md`](RELEASE_NOTES_v1.10.2605.10737.md)
- [`RELEASE_NOTES_v1.10.2605.10729.md`](RELEASE_NOTES_v1.10.2605.10729.md)
- [`RELEASE_NOTES_v1.10.2605.10672.md`](RELEASE_NOTES_v1.10.2605.10672.md)
- [`RELEASE_NOTES_v1.10.2605.01368.md`](RELEASE_NOTES_v1.10.2605.01368.md)
- [`RELEASE_NOTES_v1.10.md`](RELEASE_NOTES_v1.10.md)

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
6. Watch progress, throughput in `cf/ms`, total coin flips, sigma-scaled maxima, and the live plot. The window follows Windows display scaling, applies a fixed 9/8 UI boost, opens directly maximized to the current Windows work area, and keeps controls at their selected View scale while the graph, run log, and status areas use extra window space.
7. Load saved `.data` files later for plot analysis if needed.

## Repository Contents

```text
Coinflip_V1.12.pb
Coinflip.code-workspace
coinflip.iss
.github/workflows/release-self-hosted.yml
build-purebasic.ps1
build-installer.ps1
installer-wizard-image.bmp
installer-wizard-small.bmp
Noto_Emoji_Coin.ico
Noto_Emoji_Coin.png
README.md
INSTALLER_README.md
USER_MANUAL.txt
THIRD_PARTY_NOTICES.md
CODE_SIGNING_POLICY.md
RELEASE_CHECKLIST.md
RELEASE_NOTES_v1.10.2605.14030.md
RELEASE_NOTES_v1.10.2605.13986.md
RELEASE_NOTES_v1.10.2605.13972.md
RELEASE_NOTES_v1.10.2605.13964.md
RELEASE_NOTES_v1.10.2605.13948.md
RELEASE_NOTES_v1.10.2605.13930.md
RELEASE_NOTES_v1.10.2605.13926.md
RELEASE_NOTES_v1.10.2605.13920.md
RELEASE_NOTES_v1.10.2605.13915.md
RELEASE_NOTES_v1.10.2605.13904.md
RELEASE_NOTES_v1.10.2605.13864.md
RELEASE_NOTES_v1.10.2605.13824.md
RELEASE_NOTES_v1.10.2605.13802.md
RELEASE_NOTES_v1.10.2605.13794.md
RELEASE_NOTES_v1.10.2605.13782.md
RELEASE_NOTES_v1.10.2605.13767.md
RELEASE_NOTES_v1.10.2605.10737.md
RELEASE_NOTES_v1.10.2605.10729.md
RELEASE_NOTES_v1.10.2605.10672.md
RELEASE_NOTES_v1.10.2605.01368.md
RELEASE_NOTES_v1.10.md
SIGNPATH_APPLICATION.md
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
