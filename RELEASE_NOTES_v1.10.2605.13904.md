# Coinflip v1.10.2605.13904

Repository changelog for a Coinflip V1.10 build.

Release number: `1.10.2605.13904`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Replaced full-window composited redraw with stable child-window clipping to avoid rapid child-control repaint flicker.
- Kept off-screen image buffers for the custom progress bar canvas and live/loaded plot canvas.
- Cached progress-bar canvas frames so the bar is redrawn only when the percent or canvas size changes.
- Throttled live status text updates during active runs to reduce yellow status-field flicker.
- Preserved maximized startup, Windows-DPI-aware layout, View scale behavior, and graph title spacing fixes from prior builds.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13904.exe`
  - SHA256: `C40872DE314C8682A11508B0CF8CF03D2FC48227A3E1CBB3F6BFA0D5D007A7FA`
- `Coinflip_V1.10.2605.13904_Setup.exe`
  - SHA256: `C8BD7C06767734D536190AAAE8064DC973CB36E35128D74962FB26CC40BD7051`

## Verification focus

- Confirm startup opens maximized to the Windows work area.
- Confirm no visible scrollbars appear at startup.
- Confirm progress percentage text updates without rapid flicker.
- Confirm live status text updates stay readable during active runs.
- Confirm plot redraw remains stable during live graph updates.
- Confirm resizing and View scale changes do not visibly flicker.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13904.exe`.
