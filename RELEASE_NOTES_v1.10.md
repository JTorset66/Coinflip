# Coinflip v1.10

Initial public release of Coinflip, a PureBasic x64 desktop application for large-scale fair-coin simulation and deviation analysis on Windows.

## Highlights

- Multithreaded Windows x64 GUI application built with PureBasic
- Two simulation paths:
  - BIT-EXACT random-bit simulation
  - BINOMIAL sampling for the same deviation metric
- Multiple binomial engines, including exact and approximation-based paths
- Live plot view with threshold markers
- Optional raw `.data` output for later analysis
- Support for loading saved `.data` files back into the application
- Optimized CPU execution paths including scalar, POPCNT, AVX2, and AVX-512 VPOPCNTQ where supported

## Build and platform

- Platform: Windows x64
- Source: PureBasic 6.30 project
- Build helper included: `build-purebasic.ps1`

## Notes

- This is the first public release of the project.
- Release binaries may be unsigned until the project finishes trusted code-signing onboarding.
- The optional ONNX Runtime self-test is diagnostic only and is not required for the simulator's core functionality.

## Included assets

- `Coinflip_V1.10.exe`
- `Coinflip_V1.10.exe.sha256`

## Checksums

Use the published `.sha256` file to verify the release artifact after download.

