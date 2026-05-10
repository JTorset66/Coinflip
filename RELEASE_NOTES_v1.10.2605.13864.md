# Coinflip v1.10.2605.13864

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13864`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Added composited redraw for the main window and scroll host to reduce child-control flicker during layout changes.
- Batched layout resize operations with redraw temporarily suspended, then invalidated the full window and child tree once the layout pass is complete.
- Changed the custom progress bar canvas to render into an off-screen image before presenting the finished frame.
- Changed the live/loaded plot canvas to render into an off-screen image before presenting the finished frame.
- Preserved the existing maximized startup, Windows-DPI-aware layout, View scale behavior, and graph title spacing fixes from the prior build.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13864.exe`
  - SHA256: `4714488F1817C2EB2EBC39836C25D90F9E25CF3A597E9EE1D78E8C19FFB0AE46`
- `Coinflip_V1.10.2605.13864_Setup.exe`
  - SHA256: `20BF81E21BA2D2F8C089E8763688AD4BF13A4E2D83F3F6F6DB9E8D4EEC165AAF`

## Verification focus

- Confirm startup opens maximized to the Windows work area.
- Confirm no visible scrollbars appear at startup.
- Confirm progress redraw and plot redraw remain visible and stable with the new off-screen canvas buffers.
- Confirm resizing and View scale changes do not visibly flicker.
- Confirm graph title/status text sits above the plot frame without border overlap.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13864.exe`.
