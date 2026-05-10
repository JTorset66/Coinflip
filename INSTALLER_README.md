# Coinflip User README

Coinflip is a Windows x64 desktop application for high-volume fair-coin simulation and deviation analysis.

It runs repeated fair-coin experiments, measures how far each sample moves away from the expected 50/50 result, and shows the results in a live distribution plot.

For full operating instructions, see `USER_MANUAL.txt` installed with Coinflip. The installer places readable `.txt` copies of the README, user manual, license, and third-party notices beside the app.

## What Coinflip Measures

For each sample, Coinflip counts heads and compares that count with the expected number of heads:

```text
absolute deviation = |Heads - ExpectedHeads|
```

Example: if a sample contains 1,000 flips, the expected number of heads is 500. If the sample produces 527 heads, the deviation is 27.

## Main Functions

- Run large fair-coin simulation batches.
- Choose how many flips are included in each sample.
- Run multiple worker threads for high-throughput testing.
- Compare strict bit-level simulation with direct binomial sampling.
- Watch progress, throughput, estimated time remaining, and largest deviation seen.
- View a live bell-curve style plot of the deviation distribution.
- Mark and count rare high-deviation events above a chosen threshold.
- Save deviation results to a `.data` file.
- Load saved `.data` files later and inspect them in the plot view.
- Use a DPI-aware Windows layout that follows the active display scaling setting.
- Use a fixed 9/8 UI boost so a 200% Windows display renders controls and text closer to a 225% scale.
- Open the main window directly maximized to the current Windows monitor work area.
- Fit controls and the graph inside the opening window without scrollbars.
- Change View scale without moving or resizing the current window.
- Resize the main window with fixed-size controls while the graph, run log, and status areas use extra space.
- Maximize to the current Windows monitor work area at any Windows DPI or View scale.
- Press Enter in numeric input boxes to update the related totals/settings without clicking another field.
- Use stable child-window clipping, buffered helper/status/progress/plot surfaces, and redraw-suppressed log appends to reduce flicker.
- Read the progress percentage as high-contrast white text with a black outline.
- Read compact run log entries that keep planned setup separate from final results, with `cf/ms` speed text and named total-cf summaries.
- Save, load, copy, and analyse the current visible Run Log.
- Save or copy Analyse summaries, including repeated-run stability, graph selected/not-selected comparison, and bit-exact vs binomial speed/fit checks.
- Open the installed user manual, README, license, and third-party notices from the Help menu.

## Simulation Modes

### Bit-Exact

Bit-exact mode generates random bits and counts them directly:

- `1 bit = 1 coin flip`
- `1 = heads`
- `0 = tails`

Strictest simulation path. Coinflip can use optimized CPU counting paths when available.

### Binomial

Binomial mode samples the number of heads directly from `Binomial(n, 0.5)`, where `n` is the number of flips per sample.

Produces the same deviation metric and is useful for fast statistical analysis. Several binomial engines are available in the program.

## Output Files

If `Save output file` is enabled, Coinflip writes one 16-bit value per sample:

```text
deviation_clamped = Clamp(|Heads - n/2|, 0..65535)
```

The output file is a raw little-endian binary `.data` file. Each sample uses 2 bytes.

Saved files can be loaded back into Coinflip for plotting and review.

## Basic Use

1. Choose the number of flips per sample.
2. Choose the number of samples and worker-thread behavior.
3. Select bit-exact or binomial sampling.
4. Optionally enable output file saving.
5. Click `Start`.
6. Watch the compact log, high-contrast progress display, `cf/ms` throughput, total coin flips, final text speed summary, maximum deviation, and live plot.
7. Click `Stop` if you want to end the run early.
8. Use `Load data...` to inspect a saved `.data` file later.

## Notes

- Coinflip is intended for statistical deviation experiments, performance testing, and comparison of sampling methods.
- The main window follows Windows DPI/display scaling, applies a fixed 9/8 UI boost, and opens directly maximized to the current monitor work area.
- Main-window layout changes use stable child-window clipping, and custom canvases use off-screen buffers to reduce flicker.
- The program does not add startup entries and does not run in the background as a tray application.
- Coinflip does not transfer information to networked systems unless specifically requested by the user or the person operating it.
