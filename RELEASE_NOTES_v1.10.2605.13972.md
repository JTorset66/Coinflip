# Coinflip v1.10.2605.13972

Repository changelog for the current Coinflip V1.10 build.

Release number: `1.10.2605.13972`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Cleaned up run log wording so planned setup appears at the start and final results do not repeat the same totals.
- Changed setup log labels to `Plan` and `Plan cf` so planned work is clearly separate from actual completed work.
- Kept actual completed samples and actual completed `cf` in the final log only for stopped-early runs, where those values differ from the plan.
- Removed duplicate final `Output: not saved`, duplicate expected-max, and separate elapsed lines for complete runs.
- Kept compact final result lines for completion state, max deviation, and speed.
- Updated README, installer README, release checklist, and in-app help text for the quieter log behavior.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13972.exe`
  - SHA256: `D9F974F49E47FC3184FC80AD93A49C06DE36E90D89862DB288DECFE5BC2CB5BC`
- `Coinflip_V1.10.2605.13972_Setup.exe`
  - SHA256: `072D1305F54ECD7665B6AB12AFE1C28FB50D4A45371BDD1FB1FCF832BC2F2D06`

## Verification focus

- Confirm a complete run logs planned samples and planned `cf` at the start only.
- Confirm a complete run finishes with completion state, max result, speed, and no repeated total/output/expected-max lines.
- Confirm a stopped-early run logs actual completed samples and actual completed `cf`.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13972.exe`.
