# Coinflip v1.10.2605.13926

Repository changelog for the current Coinflip V1.10 build.

Release number: `1.10.2605.13926`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Fixed maximized startup placement so the window uses the Windows work-area maximize position instead of opening off-center.
- Create the main window hidden in normal state, set the restored rectangle while hidden, then maximize while hidden before the first layout.
- Keep the no-intermediate-window startup behavior from the prior build.
- Preserve Windows DPI behavior, View scale behavior, fixed-control resize behavior, and compact run log changes from prior builds.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13926.exe`
  - SHA256: `580DAA19DFA752CAAA8FA89005F3C069F2A1A058D71A738E90A4482E93B2C909`
- `Coinflip_V1.10.2605.13926_Setup.exe`
  - SHA256: `E6CD4E47FD067F08467B36080398C3012383391E41A305666ADB46D76B3A1C51`

## Verification focus

- Confirm startup opens directly maximized without a visible normal-size window step.
- Confirm the maximized window is aligned to the current Windows work area.
- Confirm the window does not open off-center.
- Confirm graph, run log, live status row, and progress bar fit after the first reveal.
- Confirm View scale changes still preserve the current window size and position.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13926.exe`.
