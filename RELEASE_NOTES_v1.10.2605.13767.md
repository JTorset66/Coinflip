# Coinflip v1.10.2605.13767

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13767`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Rolled the main window back to the fixed-control DPI-aware layout used before adaptive window-size scaling was introduced.
- Restored the centered `1200x760` opening frame behavior, with the frame clamped to the available Windows work area when needed.
- Removed adaptive enlargement of fonts, text boxes, buttons, columns, and plot controls during resize.
- Kept the DPI-aware Windows layout path that follows the active Windows display scaling setting, including high-DPI settings such as 200%.
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

- `Coinflip_V1.10.2605.13767.exe`
  - SHA256: `7422B97DDD884E0A8A6D162646AA01808746855E707AFCC5530828DC8024F7B1`
- `Coinflip_V1.10.2605.13767_Setup.exe`
  - SHA256: `B30856AB92DB0E525FA139FB37522007F671D79A9CFECAB40AE553677FAE1ADB`

## Verification focus

- Launch at Windows display scaling 200%.
- Confirm the opening window is centered and uses the fixed DPI-aware `1200x760` layout.
- Confirm controls keep the same size when the window is maximized.
- Confirm graph and GUI controls fit in the visible window.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13767.exe`.
