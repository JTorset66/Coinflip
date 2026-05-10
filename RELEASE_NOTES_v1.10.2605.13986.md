# Coinflip v1.10.2605.13986

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13986`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Numeric input boxes now commit when the user presses Enter, without requiring a click into another field.
- Leaving a numeric input field still commits the value, so the older focus-loss behavior remains.
- Enter on custom thread count rebuilds the worker pool when Custom thread policy is active.
- Enter on plot threshold applies the threshold and redraws the plot while stopped.
- Tooltips, README, installer README, release checklist, and in-app help now mention Enter-to-commit behavior.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13986.exe`
  - SHA256: `446E7EF0514F4EAD7F42A84063672F07BD0DE3AAF163BEBAD55615BBAFC36EB1`
- `Coinflip_V1.10.2605.13986_Setup.exe`
  - SHA256: `B980F21C5F934C2A2D5EACDCF5A77A41E7720A1208A513C802B1FFB3FBEB6E65`

## Verification focus

- Confirm pressing Enter in Instances, Run-blocks, Flips, and Custom threads updates the derived totals.
- Confirm pressing Enter in Plot threshold applies the threshold while stopped.
- Confirm leaving those fields still commits the same updates.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13986.exe`.
