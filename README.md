# Coin-Flip Deviation Simulator

PureBasic x64 desktop application for large-scale fair-coin simulation, deviation analysis, and high-throughput benchmarking.

The program runs repeated coin-flip samples and records the absolute deviation

```text
|Heads - ExpectedHeads|
```

for each sample. It supports both strict bit-level simulation and direct binomial sampling, with multithreaded execution, optional binary output, and a live distribution plot.

## What it does

For each sample:

- `1 bit = 1 coin flip`
- `1 = heads`, `0 = tails`
- the simulator computes the absolute deviation from the expected 50/50 result

The default workload is **350,757 flips per sample**, but the value can be changed in the GUI.

## Main features

- Windows **x64** PureBasic GUI application
- Multithreaded worker model for large simulation runs
- Two simulation paths:
  - **BIT-EXACT**: generates random bits and counts heads directly
  - **BINOMIAL**: samples heads from `Binomial(n, 0.5)` and computes the same deviation metric
- Multiple binomial engines:
  - **BTPE exact**
  - **BTRD exact**
  - **CLT K approximation**
  - **CPython-style exact** sampler path
- Automatic or forced kernel selection for bit-exact mode
- Optional buffered output to raw `.data` files
- Live bell-curve style plot and threshold markers
- Ability to load saved `.data` files back into the plot view
- Optional embedded ONNX Runtime self-test for diagnostics only

## CPU paths used in BIT-EXACT mode

The source includes several execution paths and selects the fastest supported route:

- portable scalar popcount fallback
- scalar **POPCNT**
- **AVX2** popcount emulation
- **AVX-512 VPOPCNTQ** when supported by both CPU and OS

Because the source uses inline x86-64 assembly for feature detection and optimized paths, it is **not intended for non-x86-64 targets**.

## Output format

When file output is enabled, the program writes one 16-bit value per sample:

```text
deviation_clamped = Clamp(|Heads - n/2|, 0..65535)
```

Output files are raw little-endian binary streams, typically named like:

```text
Coinflip_V1.10.data
```

That means:

- **2 bytes per sample**
- total file size = `number_of_samples × 2`

## Build requirements

- **PureBasic x64**
- **Windows** target
- **Thread Safe** runtime enabled in compiler options
- Recommended: compile **without the debugger** for performance testing

## Command-line build

`pbcompiler` is available on this machine, and the repo now includes a build helper.

Build the default app with:

```powershell
.\build-purebasic.ps1
```

The script compiles:

- `Coinflip_V1.10.pb`
- with `Thread Safe` enabled
- with optimizer enabled
- into `build/Coinflip_V1.10.exe`

## Optional runtime dependency

The program can perform a one-time embedded ONNX Runtime self-test if `onnxruntime.dll` is available.

This is **diagnostic only**. The simulator itself does not depend on ONNX Runtime for its core sampling logic.

## How to use

1. Open the source in PureBasic.
2. Compile for **Windows x64** with **Thread Safe** enabled.
3. Run the program.
4. Choose:
   - flips per sample
   - instances per run-block
   - run-blocks per thread
   - sampler mode
   - binomial method if BINOMIAL mode is selected
5. Start the run.
6. Watch progress, throughput, sigma-scaled maxima, and the live plot.
7. Optionally save output to a `.data` file for later analysis.

## Repository contents

```text
Coinflip_V1.10.pb
README.md
LICENSE
```

## Intended use

This project is aimed at:

- statistical deviation experiments
- throughput and kernel benchmarking
- large-run randomness studies at the deviation level
- comparing exact bit simulation with direct binomial sampling

## License

This project is licensed under the **GNU General Public License v3.0** (**GPL-3.0**).

See the [LICENSE](LICENSE) file for the full license text.

## Author

John Torset
