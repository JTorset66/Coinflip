# Coinflip v1.10.2605.13802

Repository changelog for the current Coinflip V1.10 build.

Release number: `1.10.2605.13802`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Removed the fixed maximum window bound from the main window.
- Left maximized sizing to Windows so the app maximizes to the current monitor work area at any Windows DPI setting.
- Kept the View menu scale options independent of Windows DPI.
- Clamped the scaled minimum window size to the available work area so large View scales cannot force the window larger than the monitor.
- Kept fixed-control resize behavior: maximized space goes to the graph, run log, and status areas instead of adaptive control growth.
- Kept the progress bar percentage label as white text with a black outline for clearer contrast.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13802.exe`
  - SHA256: `772B01F2C1249EDCA6890DD2D387E1D68F9A102B12A4C452C96AFC95F543AED9`
- `Coinflip_V1.10.2605.13802_Setup.exe`
  - SHA256: `020645F6934ADDEEA0790D915A7A3CB009941244E1533F6597AE5D7858AF3756`

## Verification focus

- Confirm maximize uses the Windows work area at each tested Windows DPI.
- Confirm maximize still works at View `50%`, `100%`, and `150%`.
- Confirm controls keep the selected View scale when the window is maximized.
- Confirm graph and GUI controls fit in the visible window.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13802.exe`.
