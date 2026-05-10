# Coinflip v1.10.2605.10672

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.10672`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Updated the main window to follow Windows DPI/display scaling consistently, matching the PowerPilot-style PureBasic DPI-aware window behavior.
- Removed the custom desktop-resolution scaling path from the main GUI sizing flow.
- Kept PureBasic window and gadget layout in logical DPI-aware units, using `DesktopScaledX/Y` and `DesktopUnscaledX/Y` only when crossing Win32 physical-pixel API boundaries.
- Improved high-DPI layout behavior so the graph, right-side controls, live status row, and progress bar fit cleanly at 200% Windows display scaling.
- Changed the progress bar percentage label to white text with a black outline for clearer contrast.
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

- `Coinflip_V1.10.2605.10672.exe`
- `Coinflip_V1.10.2605.10672.exe.sha256`
- `Coinflip_V1.10.2605.10672_Setup.exe`
- `Coinflip_V1.10.2605.10672_Setup.exe.sha256`

## Verification focus

- Launch at Windows display scaling 200%.
- Confirm graph and GUI controls fit in the visible window.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.10672.exe`.
