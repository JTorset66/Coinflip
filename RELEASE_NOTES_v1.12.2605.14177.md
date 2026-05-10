# Coinflip v1.12.2605.14177

Public V1.12 release of Coinflip, a PureBasic x64 desktop application for large-scale fair-coin simulation, deviation analysis, method comparison, and throughput benchmarking on Windows.

Release number: `1.12.2605.14177`. Generated executable and installer names use the full stamped `Coinflip_V1.12...` naming family.

## Highlights

- Renamed the main source file to `Coinflip_V1.12.pb` and updated build/installer scripts to use the V1.12 naming family.
- Added a detailed `USER_MANUAL.txt` covering workload settings, sampler modes, graph behaviour, log tools, analysis reports, file saving, and troubleshooting.
- Updated the Help menu to open installed `.txt` documentation files with the user's default text editor: user manual, README, license, and third-party notices.
- Added Run Log save/load controls, separate persistent append behaviour for log and analysis saves, and readable save/append separators with time and version.
- Added and refined the Analyse window with compact model summaries, speed and accuracy comparison, repeated-run stability, bit-exact vs binomial comparison, and graph selected/not-selected analysis.
- Added copy/save controls to the Analyse window and right-click copy behaviour for selected analysis lines.
- Cleaned stale and redundant PureBasic source code after the V1.12 help/documentation changes.
- Updated installer behaviour so bundled README, user manual, license, and third-party notices are installed as readable `.txt` files.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Source file: `Coinflip_V1.12.pb`
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.12.2605.14177.exe`
  - SHA256: `87696AF2A685B85E41811EDCCC948E7A2404F46A3FFB4EA4F75C97C23624E5E9`
- `Coinflip_V1.12.2605.14177_Setup.exe`
  - SHA256: `35A8023A3773865E3431FB39FA69D4D89BC4344486042D9803449FD1A32594B6`

## Verification

- Built the application with `.\build-purebasic.ps1`.
- Built the installer with `.\build-installer.ps1`.
- Confirmed the installer output was generated as `Coinflip_V1.12.2605.14177_Setup.exe`.
- Launched the installer visibly for manual installation.
