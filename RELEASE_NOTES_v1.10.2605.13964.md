# Coinflip v1.10.2605.13964

Repository changelog for the current Coinflip V1.10 build.

Release number: `1.10.2605.13964`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Added the named short-scale total coin-flip summary to the derived-values panel and run log.
- Replaced the old blank separator below the derived-values panel with a compact explanation of how total `cf` is calculated.
- Changed the yellow live-status line from native text repainting to buffered canvas drawing to reduce visible flicker during fast updates.
- Kept the run log compact with exact `cf/ms`, exact total `cf`, and readable named summaries.
- Updated README, installer README, release checklist, and in-app help text for the total-cf and live-status changes.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13964.exe`
  - SHA256: `1C8EF6BEA4BEBF369FE4A1C99F8BDF1B1A2EAABA3BCC3242A8E0B140C52F3AFF`
- `Coinflip_V1.10.2605.13964_Setup.exe`
  - SHA256: `D2F4F6714130A95DA29C872769C2481314CD5361748A76F4D26784A7FFD047C1`

## Verification focus

- Confirm the derived-values panel shows exact samples, exact total `cf`, the named total, and estimated file size.
- Confirm the note below the derived-values panel explains the total `cf` formula.
- Confirm the yellow live-status line updates without visible flicker.
- Confirm a finished run logs exact total `cf`, named total `cf`, exact speed in `cf/ms`, and named speed text.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13964.exe`.
