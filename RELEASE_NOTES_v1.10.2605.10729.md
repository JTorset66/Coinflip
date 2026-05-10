# Coinflip v1.10.2605.10729

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.10729`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Changed startup sizing so the main window opens centered at half of the available Windows work-area frame.
- The centered half-size startup window is now the 100% UI scale baseline and the minimum usable window size.
- Removed the startup-scale clamp that was incorrectly forcing the half-size startup request up to full work-area size.
- Removed the need for visible horizontal or vertical scrollbars by fitting the controls and graph inside the startup window.
- Corrected the minimum-window bounds calculation so the half-size startup frame is not doubled on 200% DPI displays.
- Tightened vertical spacing, column widths, log minimum height, and plot minimum height so the UI fits without shrinking the startup font.
- Maximum window bounds are capped to the available Windows work-area maximum, with UI scaling allowed up to 200% from the half-size baseline.
- Fonts, text boxes, buttons, columns, plot controls, and status areas scale with the window between the startup/minimum size and maximized work-area view.
- Retained the DPI-aware Windows layout path that follows the active Windows display scaling setting, including high-DPI settings such as 200%.
- Kept the progress bar percentage label as white text with a black outline for clearer contrast.
- Preserved full-version build and installer artifact naming.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Notes

- Current repository changelog entry for the local build state.
- Release binaries may be unsigned until the project finishes trusted code-signing onboarding.
- Artifact names use the full stamped version number.

## Included assets

- `Coinflip_V1.10.2605.10729.exe`
- `Coinflip_V1.10.2605.10729_Setup.exe`

The local build prints SHA256 hashes for both artifacts.

## Verification focus

- Launch and confirm startup is centered at half of the available Windows work-area frame.
- Confirm startup text and controls render at the 100% UI scale baseline.
- Confirm no horizontal or vertical scrollbars are visible at startup.
- Confirm the maximum window size is capped to the Windows work-area maximum.
- Confirm graph and GUI controls fit without clipping.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.10729.exe`.
