# Coinflip v1.10.2605.13794

Repository changelog for the current Coinflip V1.10 build.

Release number: `1.10.2605.13794`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Added a `View` menu between `Run` and `Help`.
- Added fixed content scale choices: `50%`, `75%`, `100%`, `125%`, and `150%`.
- Made View scale independent of Windows display scaling while keeping the app DPI-aware.
- Kept the current boosted layout as View `100%`; other View settings scale relative to that baseline.
- Persisted the selected View scale in the user profile so the preference survives restarts.
- Kept fixed-control resize behavior: maximized space goes to the graph, run log, and status areas instead of adaptive control growth.
- Kept the progress bar percentage label as white text with a black outline for clearer contrast.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13794.exe`
  - SHA256: `4A50BAF818709B2E27CEBA9551F8D72386ADE4D6F744071264ACC6F20BEDC9E8`
- `Coinflip_V1.10.2605.13794_Setup.exe`
  - SHA256: `CF329A45BA8919F90760B0E72A5A6B8CF382AA04637BD0F021DBD39A25669726`

## Verification focus

- Launch at Windows display scaling 200%.
- Confirm `View` appears between `Run` and `Help`.
- Confirm each View scale changes the content/window size independently of Windows DPI.
- Confirm controls keep the same size when the window is maximized.
- Confirm graph and GUI controls fit in the visible window.
- Confirm progress percentage text is white with a black outline.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13794.exe`.
