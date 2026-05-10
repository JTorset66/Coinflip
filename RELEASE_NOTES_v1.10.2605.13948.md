# Coinflip v1.10.2605.13948

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13948`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Added a short-scale power-of-10 name table in the source code, covering thousand through vigintillion.
- Added named-number formatting for final speed summaries.
- Updated the final run log speed line to keep exact `cf/ms` and add readable text, such as `about 102 million coin flips per millisecond`.
- Kept periodic progress and live status compact so the run log stays readable.
- Updated README, installer README, and release checklist for the new speed summary behavior.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13948.exe`
  - SHA256: `AD2802C380EA35DE94D9E73F60EB2126D9FC3263CB5490C323A4E5B90932F2E0`
- `Coinflip_V1.10.2605.13948_Setup.exe`
  - SHA256: `58D86B936E14FA1641E784A1E0E6D533714B438C1B5382C71ABBC88A784F01A7`

## Verification focus

- Confirm a finished run logs exact speed in `cf/ms`.
- Confirm the same final speed line includes a named text summary.
- Confirm the named text uses the short-scale table from the source code.
- Confirm periodic progress log entries stay compact.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13948.exe`.
