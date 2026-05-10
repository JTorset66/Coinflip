# Coinflip v1.10.2605.10737

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.10737`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Changed maximized-window control growth so fonts, text boxes, buttons, columns, plot controls, and status areas cap at 1.5x from the centered half-size startup baseline.
- Kept the maximized window itself capped to the available Windows work-area maximum, leaving the extra space for the graph, run log, and status areas instead of oversized controls.
- Preserved the centered half-work-area startup window as the 100% UI scale baseline and minimum usable window size.
- Kept the no-scrollbar layout target: controls, graph, right-side log, live status row, and progress bar should fit inside the visible window at startup and maximized size.
- Retained the DPI-aware Windows layout path that follows the active Windows display scaling setting, including high-DPI settings such as 200%.
- Kept the progress bar percentage label as white text with a black outline for clearer contrast.
- Preserved full-version build and installer artifact naming.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.10737.exe`
  - SHA256: `C92B834D13645740678106DA278E2979E580EEBB4086A125B626C1E80DCD55AF`
- `Coinflip_V1.10.2605.10737_Setup.exe`
  - SHA256: `B57E34A47F6C0B6FF8AFCED151D908AEA4502AE1DC55B123AF38CC47E9299FB1`

## Verification focus

- Launch and confirm startup is centered at half of the available Windows work-area frame.
- Confirm startup text and controls render at the 100% UI scale baseline.
- Confirm no horizontal or vertical scrollbars are visible at startup.
- Confirm maximized controls are about 1.5x the startup size and close to the original DPI-aware proportions.
- Confirm the maximum window size is capped to the Windows work-area maximum.
- Confirm graph and GUI controls fit without clipping.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.10737.exe`.
