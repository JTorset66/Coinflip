# Coinflip v1.10.2605.13824

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13824`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Open the main window maximized on startup, using the current Windows monitor work area.
- Keep View menu scaling independent of the window frame: changing `50%`, `75%`, `100%`, `125%`, or `150%` now preserves the current restored window size and position.
- Leave maximized sizing to Windows so the app can maximize correctly at any Windows DPI setting.
- Keep the selected View scale as a content preference on top of Windows DPI scaling.
- Move the graph frame below a measured title band so the plot border no longer overlaps the graph title or loaded-data text at large DPI/View scales.
- Keep the progress bar percentage label as white text with a black outline for clearer contrast.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13824.exe`
  - SHA256: `C4AB4EBBFD1755C04A1A9F893BC2EFEABFBC8D61494C1DE40D5A79D7F775D603`
- `Coinflip_V1.10.2605.13824_Setup.exe`
  - SHA256: `0AF7F5B5B31E9AF95B9F46FC1E68560D04CDF610FA33E9B32D74D165F42E1FAE`

## Verification focus

- Confirm startup opens maximized to the Windows work area.
- Confirm View scale changes keep the current restored window size and position.
- Confirm controls visually scale at View `50%`, `100%`, and `150%`.
- Confirm graph and GUI controls fit in the visible maximized window without scrollbars.
- Confirm graph title/status text sits above the plot frame without border overlap.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13824.exe`.
