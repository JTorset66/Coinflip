# Coinflip v1.10.2605.13920

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13920`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Open the main window in maximized state during window creation instead of showing a normal window first.
- Keep the main window hidden until the first layout, status line, and plot redraw are ready.
- Remove the explicit post-creation maximize step that caused a visible intermediate normal-size frame.
- Preserve Windows work-area maximize behavior, View scale behavior, fixed-control resize behavior, and compact run log changes from prior builds.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13920.exe`
  - SHA256: `7AE5133825994A4A66356A89C60D4D131A8092E296809CE0B83240287E79C142`
- `Coinflip_V1.10.2605.13920_Setup.exe`
  - SHA256: `7F10ECF186A209B5591F70CF944799E24180D9D279C0A3AD468A8A5F0131FE83`

## Verification focus

- Confirm startup opens directly maximized without a visible normal-size window step.
- Confirm startup still uses the current Windows work area.
- Confirm no visible scrollbars appear at startup.
- Confirm graph, run log, live status row, and progress bar fit after the first reveal.
- Confirm View scale changes still preserve the current window size and position.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13920.exe`.
