# Coinflip v1.10.2605.13782

Repository changelog for the current Coinflip V1.10 build.

Release number: `1.10.2605.13782`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Added a fixed 9/8 UI boost so a 200% Windows display renders Coinflip controls and text closer to a 225% DPI scale.
- Kept the fixed-control DPI-aware layout: controls do not grow adaptively when the window is resized.
- Scaled the startup frame, minimum bounds, layout constants, Start/Stop/Reset buttons, text boxes, plot controls, and canvas font together.
- Kept the opening window centered and clamped to the available Windows work area when needed.
- Kept extra resized or maximized space assigned to the graph, run log, and status areas instead of enlarging controls.
- Kept the progress bar percentage label as white text with a black outline for clearer contrast.
- Preserved full-version build and installer artifact naming.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13782.exe`
  - SHA256: `C5AD61E9883527B9675308AF02EE0A744362C1C1B1EAB6FDD547113E9F5FADF3`
- `Coinflip_V1.10.2605.13782_Setup.exe`
  - SHA256: `AABC39586A91632AFB631F02ABCFEE64C7AC4D986F5B067D7B4AD4E4B6EEBF9F`

## Verification focus

- Launch at Windows display scaling 200%.
- Confirm the opening window is centered and uses the boosted fixed DPI-aware layout.
- Confirm controls keep the same size when the window is maximized.
- Confirm graph and GUI controls fit in the visible window.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13782.exe`.
