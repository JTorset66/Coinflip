# Coinflip v1.10.2605.14030

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.14030`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Converted the derived-values and simulation-explanation fields from native text controls to buffered canvas text surfaces.
- Suppressed redraw while appending, trimming, and scrolling the run log to reduce RichEdit flicker.
- Batched run-control state changes during start, stop, and reset so related controls repaint together.
- Kept the existing buffered progress, live-status, and plot drawing paths.
- Updated README, installer README, and release checklist with the broader flicker-reduction behavior.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.14030.exe`
  - SHA256: `3AF86A77FA6C9C3DFA8DD30A55AC2BB38455E839ABF39830C4A1A057583A08DC`
- `Coinflip_V1.10.2605.14030_Setup.exe`
  - SHA256: `27BF798956C518472D5DD8F260905550CBC9426B238D2A0D54E2E4050F82D13F`

## Verification focus

- Confirm run log appends do not visibly flicker during run start, progress logging, stop, and finish.
- Confirm derived-values and simulation-explanation text redraw without flicker.
- Confirm progress, live-status, and plot canvases still redraw cleanly.
- Confirm start, stop, and reset do not visibly ripple through controls one at a time.
- Confirm installer installs and launches `Coinflip_V1.10.2605.14030.exe`.
