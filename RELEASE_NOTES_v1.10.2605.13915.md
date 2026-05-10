# Coinflip v1.10.2605.13915

Repository changelog for the current Coinflip V1.10 build.

Release number: `1.10.2605.13915`. Generated executable and installer names use the full stamped version in the existing `Coinflip_V1.10...` naming family.

## Highlights

- Reduced run log noise by changing periodic progress logging from 10-second entries to 30-second entries.
- Shortened startup log entries while preserving version, system, CPU, work size, output, statistical baseline, and sampler/kernel choice.
- Shortened completion logs while preserving completed samples, total coin flips, max deviation, sigma value, expected max band, speed, output, and elapsed time.
- Standardized throughput wording to `cf/ms` in the log and live status line.
- Shortened long CPU and system text in the visible log so the run log stays easier to scan.

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.40 project
- Build helper included: `build-purebasic.ps1`
- Installer helper included: `build-installer.ps1`
- DPI-aware compiler flag: `/DPIAWARE`

## Build artifacts

- `Coinflip_V1.10.2605.13915.exe`
  - SHA256: `D2FE3B4997B451EA3AEF7BCCF62AC5A75079D5BB83D270D3A104D42FA2FE5920`
- `Coinflip_V1.10.2605.13915_Setup.exe`
  - SHA256: `09EEBE3EA93CF1B2BD66E70182DC81A8036FEB90E281576736317192EEE72D04`

## Verification focus

- Confirm startup opens maximized to the Windows work area.
- Confirm a new run writes a compact setup block to the log.
- Confirm periodic progress entries are shorter and use `cf/ms`.
- Confirm completion summary keeps the important analysis values without long wrapped text.
- Confirm live status throughput uses `cf/ms`.
- Confirm installer installs and launches `Coinflip_V1.10.2605.13915.exe`.
