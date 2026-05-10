# Coinflip v1.10.2605.13930

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13930`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Fixed the startup layout pass after hidden maximize so the scroll host expands to the real maximized client area.
- Suspended redraw while revealing, maximizing, and applying the first visible layout.
- Redrew the progress canvas and plot after the corrected maximized layout.
- Preserved the no-intermediate-window startup behavior and Windows work-area maximize placement.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13930.exe`
  - SHA256: `FA5E0895D9000E182543EDC22064342F08F4A35835E051F3E0665A4E725B359E`
- `Coinflip_V1.10.2605.13930_Setup.exe`
  - SHA256: `A39E5A89CB2410C907CACCE45862E72A1A0927D00B36427D8EBF0317DB73FBA2`

## Verification focus

- Confirm startup opens maximized without the visible normal-window step.
- Confirm the GUI fills the maximized window on first reveal.
- Confirm no top-left-only scroll host remains after startup.
- Confirm graph, run log, live status row, and progress bar fit after startup.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13930.exe`.
