; ================================================================================
; Coin-Flip Deviation Simulator (PureBasic x64, multi-threaded, file-backed)
; ================================================================================
; Author: John Torset
; License: MIT License. See LICENSE for the full license text.
;
; WARNING (platform/target):
; - This source uses x86-64 inline assembly (CPUID/XGETBV + optional AVX-512).
;   It will not compile for non-x86-64 targets.
;
; Purpose (simple summary)
; ------------------------
; This program simulates coin flips using random bits:
;   - 1 bit  = 1 flip (1 = heads, 0 = tails)
;   - 64 flips are stored in one 64-bit integer (Quad)
;
; One "sample" (one data point) is:
;   flipsNeeded = 350,757 flips
; For each sample:
;   absoluteDeviation = |Heads - ExpectedHeads|
; where ExpectedHeads is the fair-coin expectation (50/50) expressed in the same
; integer convention used by the kernels:
;   coinFlipResult = Heads - ExpectedHeads
;   absoluteDeviation = |coinFlipResult|
;
; Practical sanity check (what to expect in results)
; --------------------------------------------------
; - Total flips = samples * 350,757
; - File size  = samples * 2 bytes
; - For 350,757 flips, 1-sigma is about sqrt(n*0.25) ~= 296 flips.
;   With ~115 million samples, maximum often lands around ~6-sigma (~1800).
;
; Output file format (Coinflip_<version>.data)
; ---------------------------------
; Raw binary (little-endian):
;   - 1 WORD (16-bit) per sample = 2 bytes per sample
;   - The deviation is clamped to 0..65535 before writing
; File size sanity check:
;   samples * 2 bytes  (shown as MiB when dividing by 1024*1024)
;

; ================================================================================
; Developer layout and code guide (quick orientation)
; ================================================================================
; This source is intentionally verbose with comments so it is easy to maintain.
;
; Major subsystems:
;   (A) Simulation core (worker threads)
;       - Generates many "samples" of coin flips and computes absolute deviation.
;       - Supports BIT-EXACT mode (real bits -> heads count) and BINOMIAL sampling.
;
;   (B) File output (optional)
;       - Writes 1 WORD (2 bytes) per sample to Coinflip_<version>.data
;       - Buffered writer to reduce overhead.
;
;   (C) GUI
;       - Left panel: configuration + buttons + progress readout
;       - Right panel: log output
;       - Bottom: plot (bell curve + markers) and optional offline file loader
;
;   (D) Plot (Canvas)
;       - Bell curve based on running mean/stddev from the deviation stream.
;       - Uses DPI-safe drawing: OutputWidth()/OutputHeight() after StartDrawing().
;       - Uses thick-line helpers so the curve/markers stay readable at high DPI.
;
; Notes on threading:
;   - Worker threads update shared progress counters under ioMutex.
;   - Plot statistics are updated under ioMutex (fast, low contention).
;   - File writing is separated and guarded by fileMutex (prevents UI stalls).
;
; ================================================================================
; Kernel selection (fastest available is used)  [BIT-EXACT mode only]
; -------------------------------------------------------------------
; IsAVXSupported() returns:
;   4 = AVX-512 VPOPCNTQ allowed (fastest)
;   3 = AVX2 popcount emulation (PSHUFB nibble-LUT + VPSADBW)
;   2 = POPCNT allowed (fast scalar)
;   1 = AVX present (informational only)
;   0 = none of the above -> use portable scalar popcount
;
; Important note about AVX / AVX2 / AVX-512
; -----------------------------------------
; AVX and AVX2 do not provide a native vector popcount instruction.
; POPCNT is scalar-only.
; This program can emulate vector popcount on AVX2 using a PSHUFB nibble lookup,
; and uses native vector popcount only on AVX-512VPOPCNTDQ (VPOPCNTQ).
; WARNING (AVX-512): CPU feature bits are not sufficient by themselves.
; The OS must also enable ZMM/opmask state via XCR0 (XGETBV). If not enabled,
; executing AVX-512 instructions will crash. IsAVXSupported() checks this.
;
; Multi-threading notes
; ---------------------
; - workerThreadCount = CountCPUs()^2 (capped at #POOL_MAX_THREADS)
; - Each thread executes workBlocksPerThread run-blocks
; - Each run-block processes instancesToSimulate samples
; - completedWorkBlockCount counts completed run-blocks:
;     completedWorkBlockCount = workerThreadCount * workBlocksPerThread (when done)
;
; WARNING (Threading): This program relies on PureBasic's thread-safe runtime.
; Enable "Thread Safe" in compiler options.
; RandomData() is called concurrently from multiple threads (BIT-EXACT mode).
;
; Buffered output note
; --------------------
; Output is buffered. If the program is terminated early, the last buffer chunk
; may not be written until FlushBuffer()/CloseFile() runs.
;
; ================================================================================
; ADDITION: BINOMIAL APPROX "VERY FAST" SAMPLER (optional)
; ================================================================================
; Why this exists:
; - BIT-EXACT mode literally generates random bits and popcounts them. That is correct
;   but expensive: it must generate quadsNeeded*8 bytes of randomness per sample.
; - You may instead sample the number of heads from an approximate Binomial(n, 0.5)
;   distribution And compute |Heads - Expected|.
;
; What the approximation does (fast + stable):
; - Generate a "normal-like" Z using the CLT trick: sum of K uniforms.
;     Z ~= ( (U1+...+UK) - K/2 ) * sqrt(12/K)
; - If K=12, sqrt(12/K)=1, and Z is bounded to [-6,+6] (because each Ui in [0,1)).
; - Then generate Heads ~= n/2 + Z * sqrt(n/4) and round to nearest integer.
;
; Consequences (important):
; - This is NOT bit-level randomness. It approximates the *binomial* distribution.
; - With K=12, far tails beyond ~6 sigma are truncated by construction.
;   That's actually useful here: with 115M samples you typically see maxima near ~6 sigma.

; =============================================================================
; Constants
; =============================================================================
#AppVersion$     = "1.12.2605.14177"
#ProgramVersion$ = "V" + #AppVersion$
#PI_D                 = 3.1415926535897931

#INSTANCES_TO_SIMULATE = 10000                     ; samples per run-block per thread
#SIMULATION_RUNS       = 20                        ; run-blocks per thread

#BUFFER_SIZE           = 100 * 1024 * 1024         ; 100 MiB output buffer
#BUFFER_WORDS          = #BUFFER_SIZE / 2          ; number of WORD entries in buffer (2 bytes each)

#FLIPS_NEEDED          = 350757                    ; flips per sample (fixed workload)
; =============================================================================
; Worker pool / per-thread array sizing
; - This is the maximum number of physical worker threads created in the persistent pool.
; - GUI thread count is clamped to [1..#POOL_MAX_THREADS].
; - Per-thread arrays are dimensioned as (#POOL_MAX_THREADS - 1).
; - Power of two recommended.
#POOL_MAX_THREADS = 4096

; =============================================================================
; Live plot settings (distribution chart)
; =============================================================================
#PLOT_THRESHOLD            = 2658   ; Same threshold used in DesktopCoinFlip.py (>= 2658)
#PLOT_ABOVE_TICKS_MAX     = 200000 ; Max stored values for tick marks >= threshold (rare events)
#PLOT_ABOVE_TICK_HALF_H    = 4      ; Half-height of blue tick marks on the midline (pixels)

; Embedded demo/initial plot data (WORD deviations, same format as .data output files).
; Used on startup and when Reset is clicked (no disk I/O).
#EMBEDDED_PLOT_WORDS       = 24

Structure POWER_NAME_ROW
  zeros.i
  name.s
  scale.d
EndStructure

#POWER_NAME_COUNT = 21
Global Dim powerNameTable.POWER_NAME_ROW(#POWER_NAME_COUNT - 1)
Global powerNameTableReady.i

; Plot update behavior:
; - The plot is only refreshed every #PLOT_UPDATE_INTERVAL_MS while running.
; - You can disable live updates for maximum simulation speed (plot stays visible but frozen).
#PLOT_UPDATE_INTERVAL_MS   = 2000

; Stats box placement: 0.5 = centered, 0.333... = one-third from the left
#PLOT_STATS_CENTER_X_FRAC = 0.3333333

#PLOT_STATS_OFFSET_X      = 100      ; shift the stats box 100 px to the right
; Plot styling:
; - Line thickness applies to curve, frame, reference line, dashed markers, and tick marks.
#PLOT_LINE_THICKNESS       = 3       ; 1=thin, 3=triple thickness
#PLOT_TICK_STEP            = 100     ; X-axis tick step (deviation units)
#PLOT_TICK_HEIGHT          = 10      ; Tick height in pixels (inside plot frame)
; Curve padding inside the plot frame (prevents the bell curve touching borders)
; Use a mix of absolute minimum pixels and a small fraction of plot height.
#PLOT_CURVE_PAD_TOP_MIN    = 14      ; minimum top padding in pixels
#PLOT_CURVE_PAD_BOTTOM_MIN = 12      ; minimum bottom padding in pixels
#PLOT_CURVE_PAD_FRAC       = 0.08    ; 4% of plot height (added on top of the min)

; Plot size:
; - Height is calculated as: baseHeight * multiplier, then clamped to the available space.
#PLOT_BASE_HEIGHT          = 280
#PLOT_HEIGHT_MULTIPLIER    = 1.0
#PLOT_MIN_HEIGHT           = 240

; -----------------------------------------------------------------------------
; Embedded deviation data used for the initial plot (and on Reset).
; Source: embedded demo distribution from an older Coinflip data file (WORDs, little-endian)
; Values are deviations (|heads - n/2|) in "heads" units.
; -----------------------------------------------------------------------------
DataSection
  EmbeddedDeviationData:
    Data.w 192, 80, 66, 114, 146, 454, 44, 18, 143, 585, 35, 268
    Data.w 63, 166, 96, 156, 44, 88, 106, 528, 104, 515, 367, 167

  ; Short-scale power-of-10 names used for human-readable speed summaries.
  ; Power | Zeros | Name
  ; 10^3  | 3     | thousand
  ; 10^6  | 6     | million
  ; 10^9  | 9     | billion
  ; 10^12 | 12    | trillion
  ; 10^15 | 15    | quadrillion
  ; 10^18 | 18    | quintillion
  ; 10^21 | 21    | sextillion
  ; 10^24 | 24    | septillion
  ; 10^27 | 27    | octillion
  ; 10^30 | 30    | nonillion
  ; 10^33 | 33    | decillion
  ; 10^36 | 36    | undecillion
  ; 10^39 | 39    | duodecillion
  ; 10^42 | 42    | tredecillion
  ; 10^45 | 45    | quattuordecillion
  ; 10^48 | 48    | quindecillion
  ; 10^51 | 51    | sexdecillion
  ; 10^54 | 54    | septendecillion
  ; 10^57 | 57    | octodecillion
  ; 10^60 | 60    | novemdecillion
  ; 10^63 | 63    | vigintillion
  PowerOfTenNameTable:
    Data.i 3  : Data.s "thousand"
    Data.i 6  : Data.s "million"
    Data.i 9  : Data.s "billion"
    Data.i 12 : Data.s "trillion"
    Data.i 15 : Data.s "quadrillion"
    Data.i 18 : Data.s "quintillion"
    Data.i 21 : Data.s "sextillion"
    Data.i 24 : Data.s "septillion"
    Data.i 27 : Data.s "octillion"
    Data.i 30 : Data.s "nonillion"
    Data.i 33 : Data.s "decillion"
    Data.i 36 : Data.s "undecillion"
    Data.i 39 : Data.s "duodecillion"
    Data.i 42 : Data.s "tredecillion"
    Data.i 45 : Data.s "quattuordecillion"
    Data.i 48 : Data.s "quindecillion"
    Data.i 51 : Data.s "sexdecillion"
    Data.i 54 : Data.s "septendecillion"
    Data.i 57 : Data.s "octodecillion"
    Data.i 60 : Data.s "novemdecillion"
    Data.i 63 : Data.s "vigintillion"
EndDataSection

; =============================================================================
; Layout Guide (GUI)
; =============================================================================
; Change UI sizing/spacing from ONE place by editing the constants in this section.
; Common tweaks:
;   - Main window bootstrap: #WIN_W, #WIN_H, #WIN_MIN_W, #WIN_MIN_H
;   - Column widths:        #COL1_W, #COL2_W, #COL3_W
;   - Global spacing:       #MARGIN, #GAP_X, #GAP_Y
;   - Row/button sizes:     #ROW_H, #BTN_H, #SMALLBTN_H
;   - Plot sizing:          #PLOT_BASE_HEIGHT, #PLOT_HEIGHT_MULTIPLIER, #PLOT_MIN_HEIGHT
; =============================================================================
#WIN_W         = 1200
#WIN_H         = 760
#WIN_MIN_W     = 900
#WIN_MIN_H     = 700
#WIN_SCREEN_MARGIN = 24
#SCROLLAREA_EDGE_PAD = 4
#UI_DPI_BOOST_NUM = 9      ; 9/8 = render like 225% DPI on a 200% display
#UI_DPI_BOOST_DEN = 8
#UI_FONT_SIZE     = 10     ; slightly larger than the default 200% Segoe UI look
#VIEW_SCALE_DEFAULT = 100

#MARGIN         = 14     ; outer margin to window client area
#GAP_X          = 10     ; horizontal spacing between gadgets
#GAP_Y          = 8      ; vertical spacing between rows

#TITLE_H        = 20     ; section/header text height
#ROW_H          = 24     ; typical input row height (String/Combo/CheckBox)
#BTN_H          = 30     ; Start/Stop/Reset button height
#SMALLBTN_H     = 24     ; small button height (Clear/Copy/Load)

#INPUT_W       = 120    ; width of left-side numeric input fields
#BROWSE_W      = 38     ; width of the "..." browse button

#RIGHT_MIN_W    = 320

#COL3_W        = 340    ; desired width of rightmost column (buttons+log)
#LOG_BTN_W     = 66     ; width of compact log action buttons
#PLOTINFO_LABEL_H = 18     ; label above the ETA/Throughput line
#PLOT_BAR_H     = (#PLOTINFO_LABEL_H + 2 + #ROW_H) ; label + gap + status line

#COL1_W        = 330    ; left settings column width
#COL2_W        = 320    ; middle policy column width
#COL1_MIN_W    = 300
#COL2_MIN_W    = 220
#DERIVED_ROWS   = 5      ; rows used for the derived-values text box
#PROG_H         = 20     ; progress bar height
#PROG_LINE_H    = 18     ; per-line progress text height
#PROG_LINE_GAP  = 2      ; gap between progress text lines
#PLOT_CHECK_W  = 170    ; width of the "Live graph" checkbox
#PLOT_LOAD_W   = 120    ; width of the "Load data..." button
#PLOT_THR_LABEL_W = 76     ; width of the "Threshold:" label
#PLOT_THR_INPUT_W = 96     ; width of the threshold input
#PLOT_STATUS_MIN_W = 240   ; minimum width for status text in the plot bar
#MIN_LABEL_W    = 40     ; clamp for header label width
#LOG_MIN_H      = 240    ; minimum log editor height

; Document/About text dialog sizing
#TEXTDLG_W      = 760
#TEXTDLG_H      = 700
#ANALYSISDLG_W  = 720
#ANALYSISDLG_H  = 420
#TEXTDLG_MARGIN = 10
#TEXTDLG_BTN_W  = 80
#TEXTDLG_COPY_W = 80
#TEXTDLG_SAVE_W = 80
#TEXTDLG_APPEND_W = 86
#TEXTDLG_BTN_H  = 24

#LOG_MAX_CHARS         = 1200000
#LOG_TRIM_TARGET_CHARS = 900000
#LOG_THROUGHPUT_INTERVAL_MS = 30000
#THROUGHPUT_MIN_ELAPSED_MS = 500      ; hide ETA/throughput during startup transients
#THROUGHPUT_EWMA_ALPHA_D  = 0.20     ; short-window live speed smoothing

#KEEP_CONSOLE_MS       = 36000000                  ; keep console open for 10 hours on exit paths

#FORCE_KERNEL          = 5                         ; Kernel forcing policy:
;                                                  ; 0 = force SWAR   (portable scalar bit counting)
;                                                  ; 1 = force POPCNT (scalar popcount)
;                                                  ; 2 = force AVX    (128-bit PSHUFB popcount emulation)
;                                                  ; 3 = force AVX2   (256-bit PSHUFB popcount emulation)
;                                                  ; 4 = force AVX-512 VPOPCNTQ (native vector popcount)
;                                                  ; 5 = auto-detect (use IsAVXSupported())

; -----------------------------------------------------------------------------
; Sampler mode:
;   0 = BIT-EXACT mode (original): RandomData() bits + popcount kernels
;   1 = BINOMIAL-APPROX mode: fast CLT-based binomial approximation (no bits)
; -----------------------------------------------------------------------------
#SAMPLER_MODE          = 1

; CLT parameter for binomial approximation
#BINOMIAL_CLT_K        = 24

; Local batching reduces mutex overhead:
#LOCAL_BATCH_SAMPLES   = 512   ; 512 samples -> 1024 bytes per append

#SAVE_TO_FILE           = 0     ; 1=write versioned Coinflip_<version>.data, 0=do not write output file

; Windows edit-control messages (for fast EditorGadget append)
#EM_SETSEL      = $00B1
#EM_REPLACESEL  = $00C2
#EM_SCROLLCARET = $00B7

; =============================================================================
; Logical right shift masks (constant shifts only)
; =============================================================================
#LSR_MASK_1    = $7FFFFFFFFFFFFFFF  ; keep low 63 bits
#LSR_MASK_2    = $3FFFFFFFFFFFFFFF  ; keep low 62 bits
#LSR_MASK_4    = $0FFFFFFFFFFFFFFF  ; keep low 60 bits

#LSR_MASK_11   = $001FFFFFFFFFFFFF  ; keep low 53 bits (after >> 11)
#LSR_MASK_12   = $000FFFFFFFFFFFFF  ; keep low 52 bits
#LSR_MASK_27   = $0000001FFFFFFFFF  ; keep low 37 bits
#LSR_MASK_33   = $000000007FFFFFFF  ; keep low 31 bits

; =============================================================================
; Custom events used for thread-to-UI signaling
; =============================================================================
Enumeration #PB_Event_FirstCustomValue
  #EventThreadFinished
  #EventFatal
  #EventEditCommit
EndEnumeration

Enumeration Windows
  #WinMain
EndEnumeration

Enumeration MenuItems
  #Menu_RunStart
  #Menu_RunStop
  #Menu_RunReset
  #Menu_ViewScale50
  #Menu_ViewScale75
  #Menu_ViewScale100
  #Menu_ViewScale125
  #Menu_ViewScale150
  #Menu_HelpManual
  #Menu_HelpReadme
  #Menu_HelpLicense
  #Menu_HelpThirdParty
  #Menu_HelpAbout
  #Menu_LogCopy
  #Menu_AnalysisCopy
EndEnumeration

; =============================================================================
; Globals (shared)
; =============================================================================
Global outputFile                 ; File handle for writing binary deviations
Global ioMutex                      ; Mutex for shared statistics (GUI reads these)
Global fileMutex                    ; Mutex for buffered file output (WriteData/FlushBuffer)
Global isFileOutputEnabled.i                   = #SAVE_TO_FILE  ; 1=write versioned Coinflip_<version>.data, 0=no file output
Global completedWorkBlockCount.q         ; Completed run-blocks (threads * workBlocksPerThread)
Global workerThreadCount.q               ; Number of worker threads
Global workBlocksPerThread.q               ; Run-blocks per thread
Global totalSamplesWritten.q              ; Total samples written
Global maxDeviationPercentOverall.d       ; Global max deviation percent

; =============================================================================
; Live distribution statistics (for the bell-curve plot)
; These are computed on-the-fly while the simulation runs (no file read needed).
; Keep a running mean + M2 (Welford) so std-dev stays stable for huge sample counts.
; =============================================================================
Global deviationStatsCount.q
Global deviationStatsMean.d
Global deviationStatsM2.d
Global deviationStatsCountAtOrAboveThreshold.q
Global deviationStatsMaxValue.w

; Plot UI state:
Global liveGraphEnabled.i = 1              ; 1=live updates during run, 0=frozen for speed (plot stays visible)
Global runLiveGraphEnabled.i = 1           ; Frozen graph setting captured at run start for benchmark consistency
Global loadedDataFilePath.s = ""           ; When a .data file is loaded (only when not running), this holds the path
Global lastPlotThresholdText.s = ""
Global loadedDataIsActive.i = 0            ; 1 if plot currently shows loaded file stats (not live run stats)

; Plot tick marks: store each deviation value >= threshold (capped, intended for rare events)
Global Dim plotAboveThresholdValues.w(0)
Global plotAboveThresholdUsed.i
Global plotAboveThresholdTruncated.i

Structure LogAnalysisRun
  mode.s
  family.s
  plan.s
  graphState.s
  elapsed.s
  result.s
  expectedSigma.d
  expectedLow.d
  expectedHigh.d
  hasExpected.i
  sigma.d
  hasSigma.i
  speed.d
EndStructure

Structure LogAnalysisModel
  mode.s
  family.s
  count.i
  sumSpeed.d
  bestSpeed.d
  worstSpeed.d
  sigmaCount.i
  sumSigma.d
  bestSigma.d
  worstSigma.d
  fitCount.i
  sumAbsSigmaError.d
  inExpectedRange.i
  graphOnCount.i
  graphOffCount.i
  graphOnSpeedSum.d
  graphOffSpeedSum.d
  graphOnSigmaSum.d
  graphOffSigmaSum.d
  graphOnSigmaCount.i
  graphOffSigmaCount.i
EndStructure

Global maxDeviationAbsoluteOverall.q            ; Global max absolute deviation
Global simulationStartMillis.q              ; Start timestamp
Global activeKernelSupportLevel.i              ; Selected kernel level (after forcing policy)
Global kernelSelectionSuffix.s             ; e.g. " (auto)" / " (forced POPCNT)" / etc.
Global kernelSelectionWarning.s            ; Printed once if forcing falls back / is informational

; Cached CPU/OS capability flags (set by IsAVXSupported())
Global detectedSupportsAVX.i
Global detectedSupportsAVX2.i
Global detectedSupportsAVX512.i
Global detectedSupportsPOPCNT.i

; BINOMIAL mode seed base and per-thread RNG state (NO POINTERS)
Global baseRandomSeed.q
Global Dim perThreadRngState.q(#POOL_MAX_THREADS - 1)           ; capped by workerThreadCount <= #POOL_MAX_THREADS

; Workload shared across threads; avoids pointer/structure passing.
Global configuredInstancesPerWorkBlock.q

; =============================================================================
; Runtime-config (GUI) variables (defaults come from the constants above)
; =============================================================================
Global configuredWorkBlocksPerThread.q          = #SIMULATION_RUNS
Global configuredFlipsPerSample.q             = #FLIPS_NEEDED
Global configuredSamplerMode.i             = #SAMPLER_MODE           ; 0=BIT-EXACT, 1=BINOMIAL(no bits)
Global configuredBinomialMethod.i          = 0                       ; 0=BTPE exact, 1=BTRD exact, 2=CLT K approx, 3=CPython exact (BG+BTRS)
Global configuredBinomialCltK.i           = #BINOMIAL_CLT_K
Global configuredLocalBatchSamples.i       = #LOCAL_BATCH_SAMPLES

Global configuredPlotThreshold.i         = #PLOT_THRESHOLD
Global configuredKernelPolicy.i             = #FORCE_KERNEL           ; 0..5, see constants block
Global configuredThreadPolicy.i            = 0                       ; 0=CountCPUs()^2 (default), 1=CountCPUs(), 2=custom
Global configuredCustomThreadCount.i           = 0                       ; used if configuredThreadPolicy=2

Global configuredOutputBufferSizeBytes.q         = #BUFFER_SIZE
Global configuredOutputBufferWordCount.q             = #BUFFER_WORDS

; Run control / progress (shared)
Global simulationIsRunning.i
Global stopRequested.i
Global workerThreadsFinished.i
Global workerThreadsTotal.i
Global fatalErrorFlag.i
Global fatalErrorMessage.s

Global resetAfterStop.i
Global quitAfterStop.i
Global flipsPerMillisecond.d             ; cumulative throughput (completed flips / elapsed ms)
Global liveFlipsPerMillisecond.d         ; short-window EWMA throughput (cf/ms)
Global estimatedSecondsRemaining.d
Global sigmaHeads.d
Global expectedMaxSigmaMean.d
Global expectedMaxSigmaP05.d
Global expectedMaxSigmaP95.d
Global expectedMaxDeviationMeanHeads.d
Global expectedMaxDeviationP05Heads.d
Global expectedMaxDeviationP95Heads.d
Global totalSamplesPlanned.q
Global sigmaTailCap.d
Global progressPercent.i
Global nextThroughputLogMillis.q
Global throughputWindowPrevMillis.q
Global throughputWindowPrevSamples.q
Global throughputWindowEWMAFlipsPerMs.d
Global throughputWindowInitialized.i

; =============================================================================
; Persistent worker pool (threads are created once and reused across runs)
; =============================================================================
Global poolRunSemaphore.i
Global poolQuitFlag.i
Global workerPoolCreated.i
Global workerPoolThreadCount.i
Global Dim workerPoolThreadID.i(#POOL_MAX_THREADS - 1)       ; up to #POOL_MAX_THREADS threads
Global poolActiveThreadCount.i          ; active threads for the current run (<= #POOL_MAX_THREADS)
Global poolRunTicket.i                 ; assigns logical [0..poolActiveThreadCount-1] to whichever physical threads wake
Global poolTicketMutex.i              ; protects poolRunTicket assignment (portable, avoids missing Atomic/Interlocked)

Global poolGoSemaphore.i             ; barrier 'GO' semaphore (released after timestamp)
Global poolReadyAllSem.i             ; signaled once when all active workers are armed
Global poolReadyMutex.i              ; protects poolReadyCount
Global poolReadyCount.i              ; number of active workers armed for the current run

; Output buffer stored as WORD array (NO AllocateMemory pointer)
Global Dim outputDeviationWords.w(0)               ; resized at runtime from GUI
Global outputDeviationWordsUsed.q               ; how many WORDs currently in outputDeviationWords()

; =============================================================================
; Fatal error helper: keeps console open even on ERROR exits
; =============================================================================
Procedure FatalError(message.s)
  ; Thread-safe fatal: signal GUI and request stop
  fatalErrorMessage = message
  fatalErrorFlag = 1
  stopRequested = 1
  ; Post custom event to wake the UI loop immediately.
  ; Signature: PostEvent(Event, Window, Object, EventType, EventData)
  PostEvent(#EventFatal, #WinMain, 0, 0, 0)
EndProcedure

; =============================================================================
; Macros
; =============================================================================
; (compat) Avoid Max/IIf macros for widest PureBasic build support.

; SWAR popcount (logical shift emulation by masking after >>)
Macro SWAR_POPCOUNT64(valueVar, outVar)
  valueVar - (((valueVar >> 1) & #LSR_MASK_1) & $5555555555555555)
  valueVar = (valueVar & $3333333333333333) + (((valueVar >> 2) & #LSR_MASK_2) & $3333333333333333)
  valueVar = (valueVar + ((valueVar >> 4) & #LSR_MASK_4)) & $0F0F0F0F0F0F0F0F
  valueVar = valueVar * $0101010101010101
  outVar = ((valueVar >> 56) & $FF)
EndMacro

; =============================================================================
; Feature detection
; =============================================================================
Procedure.i IsAVXSupported()

  ; This function does two things:
  ; (1) Detects CPU + OS support for AVX/AVX2/AVX-512 state (XGETBV).
  ; (2) Publishes capability flags for force-policy decisions.
  ;
  ; Return value is the *best* usable BIT-EXACT kernel level:
  ;   4 = AVX-512 VPOPCNTQ
  ;   3 = AVX2 (256-bit PSHUFB popcount emulation)
  ;   2 = AVX  (128-bit PSHUFB popcount emulation)
  ;   1 = POPCNT
  ;   0 = SWAR fallback

  Shared detectedSupportsAVX.i, detectedSupportsAVX2.i, detectedSupportsAVX512.i, detectedSupportsPOPCNT.i

  Protected supportsAVX.i = #False
  Protected supportsAVX2.i = #False
  Protected supportsAVX512.i = #False
  Protected supportsAVX512State.i = #False
  Protected supportsPOPCNT.i = #False
  Protected supportsSSSE3.i = #False

  Protected eax.q, ebx.q, ecx.q
  Protected xcr0.q
  Protected ecx7.q
  Protected saveRbx.q

  ; Default published flags
  detectedSupportsAVX = 0
  detectedSupportsAVX2 = 0
  detectedSupportsAVX512 = 0
  detectedSupportsPOPCNT = 0

  !MOV [p.v_saveRbx], rbx
  !XOR rax, rax
  !CPUID
  !MOV [p.v_eax], rax
  !MOV rbx, [p.v_saveRbx]

  If eax >= 1

    !MOV [p.v_saveRbx], rbx
    !MOV rax, 1
    !CPUID
    !MOV [p.v_ecx], rcx
    !MOV rbx, [p.v_saveRbx]

    If (ecx & (1 << 23))
      supportsPOPCNT = #True
    EndIf

    If (ecx & (1 << 9))
      supportsSSSE3 = #True
    EndIf

    ; AVX requires both CPU feature bits AND OS state enabled (XCR0[1:2])
    If (ecx & (1 << 27)) And (ecx & (1 << 28))
      !XOR rcx, rcx
      !XGETBV
      !MOV [p.v_xcr0], rax

      If (xcr0 & $6) = $6
        supportsAVX = #True

        ; AVX-512 requires additional state enabled (ZMM/opmask): XCR0[5:7] + [2:1]
        If (xcr0 & $E6) = $E6
          supportsAVX512State = #True
        EndIf
      EndIf
    EndIf

    If eax >= 7
      !MOV [p.v_saveRbx], rbx

      !MOV rax, 7
      !XOR rcx, rcx
      !CPUID
      !MOV [p.v_ebx],  rbx
      !MOV [p.v_ecx7], rcx

      !MOV rbx, [p.v_saveRbx]

      ; AVX2 is only usable if AVX OS state is enabled as well
      If supportsAVX And supportsSSSE3 And (ebx & (1 << 5))
        supportsAVX2 = #True
      EndIf

      If supportsAVX And supportsAVX512State
        ; AVX-512F (EBX bit 16) + AVX-512VPOPCNTDQ (ECX bit 14)
        If (ebx & (1 << 16)) And (ecx7 & (1 << 14))
          supportsAVX512 = #True
        EndIf
      EndIf
    EndIf

  EndIf

  ; Publish capability flags (used by SetKernelModeFromForce())
  detectedSupportsAVX = Bool(supportsAVX And supportsSSSE3)
  detectedSupportsAVX2 = Bool(supportsAVX2)
  detectedSupportsAVX512 = Bool(supportsAVX512)
  detectedSupportsPOPCNT = Bool(supportsPOPCNT)

  If supportsAVX512
    ProcedureReturn 4
  ElseIf supportsAVX2
    ProcedureReturn 3
  ElseIf supportsAVX And supportsSSSE3
    ProcedureReturn 2
  ElseIf supportsPOPCNT
    ProcedureReturn 1
  Else
    ProcedureReturn 0
  EndIf

EndProcedure

; =============================================================================
; System information helpers (CPU / OS)
; =============================================================================

Structure RTL_OSVERSIONINFOW
  dwOSVersionInfoSize.l
  dwMajorVersion.l
  dwMinorVersion.l
  dwBuildNumber.l
  dwPlatformId.l
  szCSDVersion.w[128]
EndStructure

CompilerIf Defined(PB_OS_Windows_NT3_51, #PB_Constant) = 0
  #PB_OS_Windows_NT3_51 = -1001
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_95, #PB_Constant) = 0
  #PB_OS_Windows_95 = -1002
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_98, #PB_Constant) = 0
  #PB_OS_Windows_98 = -1003
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_ME, #PB_Constant) = 0
  #PB_OS_Windows_ME = -1004
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_NT4_0, #PB_Constant) = 0
  #PB_OS_Windows_NT4_0 = -1005
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_2000, #PB_Constant) = 0
  #PB_OS_Windows_2000 = -1006
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_XP, #PB_Constant) = 0
  #PB_OS_Windows_XP = -1007
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2003, #PB_Constant) = 0
  #PB_OS_Windows_Server_2003 = -1008
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Vista, #PB_Constant) = 0
  #PB_OS_Windows_Vista = -1009
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2008, #PB_Constant) = 0
  #PB_OS_Windows_Server_2008 = -1010
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_7, #PB_Constant) = 0
  #PB_OS_Windows_7 = -1011
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2008_R2, #PB_Constant) = 0
  #PB_OS_Windows_Server_2008_R2 = -1012
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_8, #PB_Constant) = 0
  #PB_OS_Windows_8 = -1013
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2012, #PB_Constant) = 0
  #PB_OS_Windows_Server_2012 = -1014
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_8_1, #PB_Constant) = 0
  #PB_OS_Windows_8_1 = -1015
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2012_R2, #PB_Constant) = 0
  #PB_OS_Windows_Server_2012_R2 = -1016
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_10, #PB_Constant) = 0
  #PB_OS_Windows_10 = -1017
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_11, #PB_Constant) = 0
  #PB_OS_Windows_11 = -1018
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2016, #PB_Constant) = 0
  #PB_OS_Windows_Server_2016 = -1019
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2019, #PB_Constant) = 0
  #PB_OS_Windows_Server_2019 = -1020
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2022, #PB_Constant) = 0
  #PB_OS_Windows_Server_2022 = -1021
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Server_2025, #PB_Constant) = 0
  #PB_OS_Windows_Server_2025 = -1022
CompilerEndIf
CompilerIf Defined(PB_OS_Windows_Future, #PB_Constant) = 0
  #PB_OS_Windows_Future = -1023
CompilerEndIf

Procedure.s GetWindowsVersionString()
  Protected v.RTL_OSVERSIONINFOW
  Protected h.i, *fn
  Protected ok.i = 0
  Protected name.s
  Protected osId.i = OSVersion()

  ; Get accurate major/minor/build from ntdll (unaffected by manifest compatibility shims).
  v\dwOSVersionInfoSize = SizeOf(RTL_OSVERSIONINFOW)

  h = OpenLibrary(#PB_Any, "ntdll.dll")
  If h
    *fn = GetFunction(h, "RtlGetVersion")
    If *fn
      CallFunctionFast(*fn, @v)
      ok = 1
    EndIf
    CloseLibrary(h)
  EndIf

  ; Primary mapping uses PureBasic's OSVersion() constants.
  Select osId
    Case #PB_OS_Windows_NT3_51      : name = "Windows NT 3.51"
    Case #PB_OS_Windows_95          : name = "Windows 95"
    Case #PB_OS_Windows_98
      If ok And v\dwBuildNumber >= 2222
        name = "Windows 98 SE"
      Else
        name = "Windows 98"
      EndIf
    Case #PB_OS_Windows_ME          : name = "Windows ME"
    Case #PB_OS_Windows_NT4_0       : name = "Windows NT 4.0"
    Case #PB_OS_Windows_2000        : name = "Windows 2000"
    Case #PB_OS_Windows_XP          : name = "Windows XP"
    Case #PB_OS_Windows_Server_2003 : name = "Windows Server 2003"
    Case #PB_OS_Windows_Vista       : name = "Windows Vista"
    Case #PB_OS_Windows_Server_2008 : name = "Windows Server 2008"
    Case #PB_OS_Windows_7           : name = "Windows 7"
    Case #PB_OS_Windows_Server_2008_R2 : name = "Windows Server 2008 R2"
    Case #PB_OS_Windows_8           : name = "Windows 8"
    Case #PB_OS_Windows_Server_2012 : name = "Windows Server 2012"
    Case #PB_OS_Windows_8_1         : name = "Windows 8.1"
    Case #PB_OS_Windows_Server_2012_R2 : name = "Windows Server 2012 R2"
    Case #PB_OS_Windows_10
      If ok And v\dwBuildNumber >= 22000
        name = "Windows 11"
      Else
        name = "Windows 10"
      EndIf
    Case #PB_OS_Windows_11          : name = "Windows 11"
    Case #PB_OS_Windows_Server_2016 : name = "Windows Server 2016"
    Case #PB_OS_Windows_Server_2019 : name = "Windows Server 2019"
    Case #PB_OS_Windows_Server_2022 : name = "Windows Server 2022"
    Case #PB_OS_Windows_Server_2025 : name = "Windows Server 2025"
    Case #PB_OS_Windows_Future      : name = "Windows (future version)"
  EndSelect
  ; Fallback if OSVersion() returned an unknown/unsupported id.
  If name = ""
    If ok
      Select v\dwMajorVersion
        Case 3
          Select v\dwMinorVersion
            Case 0  : name = "Windows 3.0"
            Case 10 : name = "Windows 3.1"
            Default : name = "Windows 3.x"
          EndSelect

        Case 4
          Select v\dwMinorVersion
            Case 0  : name = "Windows 95"
            Case 10
              If v\dwBuildNumber >= 2222
                name = "Windows 98 SE"
              Else
                name = "Windows 98"
              EndIf
            Case 90 : name = "Windows ME"
            Default : name = "Windows 4.x"
          EndSelect

        Case 5
          Select v\dwMinorVersion
            Case 0 : name = "Windows 2000"
            Case 1 : name = "Windows XP"
            Case 2 : name = "Windows Server 2003"
            Default : name = "Windows 5.x"
          EndSelect

        Case 6
          Select v\dwMinorVersion
            Case 0 : name = "Windows Vista / Server 2008"
            Case 1 : name = "Windows 7 / Server 2008 R2"
            Case 2 : name = "Windows 8 / Server 2012"
            Case 3 : name = "Windows 8.1 / Server 2012 R2"
            Default : name = "Windows 6.x"
          EndSelect

        Case 10
          If v\dwBuildNumber >= 22000
            name = "Windows 11"
          Else
            name = "Windows 10"
          EndIf

        Default
          name = "Windows " + Str(v\dwMajorVersion) + "." + Str(v\dwMinorVersion)
      EndSelect
    Else
      name = "Windows"
    EndIf
  EndIf

  If ok
    ProcedureReturn name + " (build " + Str(v\dwBuildNumber) + ")"
  EndIf

  ProcedureReturn name
EndProcedure

Procedure.s GetCpuBrandString()
  Protected *buf
  Protected brand.s
  Protected maxLeaf.q
  Protected leaf.q
  Protected eax.q, ebx.q, ecx.q, edx.q
  Protected saveRbx.q
  Protected i.i, off.i

  *buf = AllocateMemory(49)
  If *buf = 0
    ProcedureReturn "Unknown CPU"
  EndIf
  FillMemory(*buf, 49, 0)

  leaf = $80000000
  !MOV [p.v_saveRbx], rbx
  !MOV eax, [p.v_leaf]
  !CPUID
  !MOV [p.v_maxLeaf], rax
  !MOV rbx, [p.v_saveRbx]

  If maxLeaf >= $80000004
    For i = 0 To 2
      leaf = $80000002 + i

      !MOV [p.v_saveRbx], rbx
      !MOV eax, [p.v_leaf]
      !CPUID
      !MOV [p.v_eax], rax
      !MOV [p.v_ebx], rbx
      !MOV [p.v_ecx], rcx
      !MOV [p.v_edx], rdx
      !MOV rbx, [p.v_saveRbx]

      off = i * 16
      PokeL(*buf + off + 0, eax)
      PokeL(*buf + off + 4, ebx)
      PokeL(*buf + off + 8, ecx)
      PokeL(*buf + off + 12, edx)
    Next
  EndIf

  brand = Trim(PeekS(*buf, -1, #PB_Ascii))
  FreeMemory(*buf)
  If brand = ""
    brand = "Unknown CPU"
  EndIf
  ProcedureReturn brand
EndProcedure

;
; -----------------------------------------------------------------------------
; BINOMIAL (EXACT) support code (BTPE) - PureBasic only, NO ASM.
; Uses existing RNG state: perThreadRngState(threadIndex) via XorShift64Star(threadIndex).
; Keeps public entry point name/signature:
;   BinomialHeads_BTPE_Exact(n.i, threadIndex.i, sigma.d)
; Note:
; - sigma is kept only for call-site compatibility (unused here).
; - n is constant in this program, so InitBinomialHalf_BTPE() runs once (thread-safe).
; -----------------------------------------------------------------------------

; XorShift64Star() is defined later in this file, so forward declare it here.
Declare.q XorShift64Star(threadIndex.i)

; Inline XorShift64* step for tight BTPE loops (faster than a Procedure call).
; Usage: BTPE_NEXT64(stateVar, outVar)
Macro BTPE_NEXT64(stateVar, outVar)
  stateVar ! ((stateVar >> 12) & #LSR_MASK_12)
  stateVar ! (stateVar << 25)
  stateVar ! ((stateVar >> 27) & #LSR_MASK_27)
  outVar = stateVar * 2685821657736338717
EndMacro

Declare ApplyLayout()
Declare ResizeUI()
Declare ApplyViewScale(percent.i)
Declare StartSimulation()
Declare RequestReset()
Declare OpenUserManual()
Declare OpenReadme()
Declare OpenLicense()
Declare OpenThirdPartyNotices()
Declare ShowTextDialog(title.s, body.s, requestedW.i = #TEXTDLG_W, requestedH.i = #TEXTDLG_H)
Declare ShowAbout()

Declare MergeDeviationStats(batchCount.q, batchMean.d, batchM2.d, batchCountAboveThreshold.q, batchMaxValue.w)
Declare ResetDeviationStats()
Declare ResetPlotAboveThreshold()
Declare AppendPlotAboveValue(value.i)
Declare AppendPlotAboveValues(*vals, count.i)
Declare UpdateDistributionPlot()

; Per-thread cached uniform (speed trick): 2 uniforms per RNG call
Global Dim rngSpare.q(#POOL_MAX_THREADS - 1)
Global Dim rngHasSpare.b(#POOL_MAX_THREADS - 1)

Procedure.d RandU01_Excl(threadIndex.i)
  ; Fast (0,1) exclusive uniform with 32-bit resolution.
  ; Uses cached high 32 bits so BTPE's (u,v) typically costs one RNG call.
  Protected v.q
  Protected r.q

  If rngHasSpare(threadIndex)
    v = rngSpare(threadIndex)
    rngHasSpare(threadIndex) = 0
  Else
    r = XorShift64Star(threadIndex)
    v = r & $FFFFFFFF
    rngSpare(threadIndex) = (r >> 32) & $FFFFFFFF
    rngHasSpare(threadIndex) = 1
  EndIf

  ProcedureReturn (v + 0.5) * 2.3283064365386963e-10 ; 2^-32
EndProcedure

; BTPE globals (initialized once for constant n)
Global binomialTablesInitialized.i
Global binomialTablesMutex.i
Global binomialParamN.i
Global binomialParamM.i
Global.d btpeProbabilityP, btpeProbabilityQ, btpeXnp, btpeFfm, btpeFm, btpeXnpq
Global.d btpeParameterP1, btpeModeXm, btpeLeftBoundXl, btpeRightBoundXr, btpeConstantC
Global.d btpeRegionLeftXll, btpeRegionLeftXlr, btpeParameterP2, btpeParameterP3, btpeParameterP4
Global.d btpeNPlus1

; BTPE fast accept/reject helpers (precomputed once per constant n)
Global btpeLogFactN.i
Global.d btpeLogRatioConst
Global btpeKThreshold.i
Global Dim btpeLogFact.d(0)
Global Dim btpeRatioPos.d(20) ; ratio C(n,m+delta)/C(n,m), delta=0..20
Global Dim btpeRatioNeg.d(20) ; ratio C(n,m-delta)/C(n,m), delta=0..20

; -----------------------------------------------------------------------------
; BINOMIAL (EXACT) alternative engine: BTRD (Hormann 1993)
; -----------------------------------------------------------------------------
Global btrdTablesInitialized.i
Global btrdTablesMutex.i
Global btrdParamN.i
Global.d btrdParamP
Global btrdIsFlipped.i
Global btrdModeM.i
Global.d btrd_r, btrd_nr, btrd_npq
Global.d btrd_a, btrd_b, btrd_c, btrd_alpha, btrd_vr, btrd_urvr

; -----------------------------------------------------------------------------
; BINOMIAL (EXACT) reference engine: CPython random.binomialvariate (BG + BTRS)
; -----------------------------------------------------------------------------
Global cpyTablesInitialized.i
Global cpyTablesMutex.i
Global cpyParamN.i
Global.d cpyParamP
Global cpyIsFlipped.i
Global cpyModeM.i
Global.d cpy_spq, cpy_a, cpy_b, cpy_c, cpy_alpha, cpy_vr
Global.d cpy_lpq, cpy_h
Global.d cpyLog2_1mp

Procedure InitBinomialHalf_BTPE(n.i)
  Protected.d p, q, xnp, ffm, fm, xnpq, p1, xm, xl, xr, c, al, xll, xlr, p2, p3, p4
  Protected i.i

  If binomialTablesMutex = 0
    binomialTablesMutex = CreateMutex()
  EndIf

  LockMutex(binomialTablesMutex)
  If binomialTablesInitialized = 0 Or binomialParamN <> n

    p = 0.5
    q = 0.5
    xnp = n * p

    ffm = xnp + p
    binomialParamM = Int(ffm)
    fm = binomialParamM

    xnpq = xnp * q
    p1 = Int(2.195 * Sqr(xnpq) - 4.6 * q) + 0.5
    xm = fm + 0.5
    xl = xm - p1
    xr = xm + p1
    c  = 0.134 + 20.5 / (15.3 + fm)

    al  = (ffm - xl) / (ffm - xl * p)
    xll = al * (1.0 + 0.5 * al)

    al  = (xr - ffm) / (xr * q)
    xlr = al * (1.0 + 0.5 * al)

    p2 = p1 * (1.0 + c + c)
    p3 = p2 + c / xll
    p4 = p3 + c / xlr

    btpeProbabilityP    = p
    btpeProbabilityQ    = q
    btpeXnp  = xnp
    btpeFfm  = ffm
    btpeFm   = fm
    btpeXnpq = xnpq

    btpeParameterP1 = p1
    btpeModeXm = xm
    btpeLeftBoundXl = xl
    btpeRightBoundXr = xr
    btpeConstantC  = c

    btpeRegionLeftXll = xll
    btpeRegionLeftXlr = xlr
    btpeParameterP2  = p2
    btpeParameterP3  = p3
    btpeParameterP4  = p4

    btpeNPlus1 = n + 1.0

    ; Precompute exact log-factorials and small-delta ratios (one-time per n)
    If btpeLogFactN <> n Or ArraySize(btpeLogFact()) <> n
      ReDim btpeLogFact.d(n)
      btpeLogFact(0) = 0.0
      For i = 1 To n
        btpeLogFact(i) = btpeLogFact(i - 1) + Log(i)
      Next
      btpeLogFactN = n
    EndIf

    btpeLogRatioConst = btpeLogFact(binomialParamM) + btpeLogFact(n - binomialParamM)
    btpeKThreshold = Int(btpeXnpq * 0.5 - 1.0)

    btpeRatioPos(0) = 1.0
    btpeRatioNeg(0) = 1.0
    For i = 1 To 20
      btpeRatioPos(i) = btpeRatioPos(i - 1) * ((n - (binomialParamM + i - 1)) / (binomialParamM + i))
      btpeRatioNeg(i) = btpeRatioNeg(i - 1) * ((binomialParamM - i + 1) / (n - binomialParamM + i))
    Next

    binomialParamN = n
    binomialTablesInitialized = 1
  EndIf
  UnlockMutex(binomialTablesMutex)
EndProcedure

Procedure.i BinomialHeads_BTPE_Exact(n.i, threadIndex.i, sigma.d)
  ; ---------------------------------------------------------------------------
  ; Exact Binomial(n, 0.5) using BTPE (Kachitvichyanukul & Schmeiser, 1988)
  ; PureBasic-only (NO inline assembler).
  ;
  ; Speed notes (this implementation):
  ; - Avoids per-call RandU01_Excl() overhead by keeping the 32-bit spare cache
  ;   in LOCAL variables during the rejection loop (writes back once on exit).
  ; - Replaces the expensive Stirling/log final test with an exact log-factorial
  ;   ratio (table precomputed once per n).
  ; - Uses precomputed exact ratios for |ix-m| <= 20 (no loops, no logs).
  ; ---------------------------------------------------------------------------

  If binomialTablesInitialized = 0 Or binomialParamN <> n
    InitBinomialHalf_BTPE(n)
  EndIf

  Protected ix.i, k.i, delta.i
  Protected.d u, v, x, amaxp, ynorm, alv, logRatio
  Protected r.q, u32.q, spare.q
  Protected hasSpare.i
  Protected result.i
  Protected xst.q

  ; Keep RNG state local for this BTPE call (cuts array traffic + procedure-call overhead)
  xst = perThreadRngState(threadIndex)

  ; Pull per-thread spare uniform cache into locals (cuts array traffic in loop)
  hasSpare = rngHasSpare(threadIndex)
  spare    = rngSpare(threadIndex)

gen:
  ; u = U(0,1) exclusive, 32-bit resolution
  If hasSpare
    u32 = spare
    hasSpare = 0
  Else
    BTPE_NEXT64(xst, r)
    u32 = r & $FFFFFFFF
    spare = (r >> 32) & $FFFFFFFF
    hasSpare = 1
  EndIf
  u = (u32 + 0.5) * 2.3283064365386963e-10
  u = u * btpeParameterP4

  ; v = U(0,1) exclusive
  If hasSpare
    u32 = spare
    hasSpare = 0
  Else
    BTPE_NEXT64(xst, r)
    u32 = r & $FFFFFFFF
    spare = (r >> 32) & $FFFFFFFF
    hasSpare = 1
  EndIf
  v = (u32 + 0.5) * 2.3283064365386963e-10

  If u <= btpeParameterP1
    ; TRIANGULAR region (AUTO-ACCEPT)
    ix = Int(btpeModeXm - btpeParameterP1 * v + u)
    If ix < 0 Or ix > n
      Goto gen
    EndIf
    result = ix
    Goto done

  ElseIf u <= btpeParameterP2
    ; PARALLELOGRAM region
    x = btpeLeftBoundXl + (u - btpeParameterP1) / btpeConstantC
    v = v * btpeConstantC + 1.0 - Abs(btpeModeXm - x) / btpeParameterP1
    If v > 1.0 Or v <= 0.0
      Goto gen
    EndIf
    ix = Int(x)
    If ix < 0 Or ix > n
      Goto gen
    EndIf

  Else
    ; EXPONENTIAL tails
    If u <= btpeParameterP3
      ; LEFT tail
      ix = Int(btpeLeftBoundXl + Log(v) / btpeRegionLeftXll)
      If ix < 0
        Goto gen
      EndIf
      v = v * (u - btpeParameterP2) * btpeRegionLeftXll
    Else
      ; RIGHT tail
      ix = Int(btpeRightBoundXr - Log(v) / btpeRegionLeftXlr)
      If ix > n
        Goto gen
      EndIf
      v = v * (u - btpeParameterP3) * btpeRegionLeftXlr
    EndIf
  EndIf

  ; ---------------------------------------------------------------------------
  ; Accept / Reject (parallelogram + tails only)
  ; ---------------------------------------------------------------------------
  k = Abs(ix - binomialParamM)

  ; Near the mode: exact precomputed ratios (fastest)
  If k <= 20
    If ix >= binomialParamM
      delta = ix - binomialParamM
      If v > btpeRatioPos(delta)
        Goto gen
      EndIf
    Else
      delta = binomialParamM - ix
      If v > btpeRatioNeg(delta)
        Goto gen
      EndIf
    EndIf
    result = ix
    Goto done
  EndIf

  ; Extreme tails: use exact log-factorial ratio (avoids huge multiplicative loops)
  If k >= btpeKThreshold
    If v <= 0.0
      Goto gen
    EndIf
    alv = Log(v)
    logRatio = btpeLogRatioConst - btpeLogFact(ix) - btpeLogFact(n - ix)
    If alv > logRatio
      Goto gen
    EndIf
    result = ix
    Goto done
  EndIf

  ; Squeezing bounds on log(f(x))
  amaxp = (k / btpeXnpq) * ((k * (k / 3.0 + 0.625) + 0.1666666666666) / btpeXnpq + 0.5)
  ynorm = -(k * k) / (2.0 * btpeXnpq)

  If v <= 0.0
    Goto gen
  EndIf
  alv = Log(v)

  If alv < ynorm - amaxp
    result = ix
    Goto done
  EndIf
  If alv > ynorm + amaxp
    Goto gen
  EndIf

  ; Final acceptance using exact log-factorial ratio:
  ; log( C(n,ix) / C(n,m) )  (the 2^-n term cancels for p=q=0.5)
  logRatio = btpeLogRatioConst - btpeLogFact(ix) - btpeLogFact(n - ix)
  If alv > logRatio
    Goto gen
  EndIf

  result = ix

done:
  ; Write back RNG state ONCE (big win vs per-uniform array traffic)
  perThreadRngState(threadIndex) = xst

  ; Write back the spare cache ONCE (big win vs array traffic inside the loop)
  rngSpare(threadIndex) = spare
  rngHasSpare(threadIndex) = hasSpare
  ProcedureReturn result
EndProcedure

; =============================================================================
; BINOMIAL (EXACT) - BTRD (Hormann transformed rejection / decomposition)
; =============================================================================
; This is a direct port of the BTRD algorithm as implemented in Boost.
; Exact Binomial(t, p) generator. This program uses p=0.5,
; but the code keeps the p<=0.5 symmetry so it stays correct if extended later.
;
; References:
; - Wolfgang Hormann (1993), "The generation of binomial random variates"
; - Boost: boost/random/binomial_distribution.hpp
;
; Notes:
; - For small mean (m < 11), fall back to direct Bernoulli counting. This is exact,
;   simple, and only used for very small problems.
; - Uses the same per-thread xorshift64* RNG + 32-bit spare cache as BTPE.

#BTRD_FC_TABLE0 = 0.08106146679532726
#BTRD_FC_TABLE1 = 0.04134069595540929
#BTRD_FC_TABLE2 = 0.02767792568499834
#BTRD_FC_TABLE3 = 0.02079067210376509
#BTRD_FC_TABLE4 = 0.01664469118982119
#BTRD_FC_TABLE5 = 0.01387612882307075
#BTRD_FC_TABLE6 = 0.01189670994589177
#BTRD_FC_TABLE7 = 0.01041126526197209
#BTRD_FC_TABLE8 = 0.009255462182712733
#BTRD_FC_TABLE9 = 0.008330563433362871

; Correction factor for Stirling approximation of log(k!)
Procedure.d BTRD_Fc(k.i)
  Protected.d ikp1, t
  Select k
    Case 0 : ProcedureReturn #BTRD_FC_TABLE0
    Case 1 : ProcedureReturn #BTRD_FC_TABLE1
    Case 2 : ProcedureReturn #BTRD_FC_TABLE2
    Case 3 : ProcedureReturn #BTRD_FC_TABLE3
    Case 4 : ProcedureReturn #BTRD_FC_TABLE4
    Case 5 : ProcedureReturn #BTRD_FC_TABLE5
    Case 6 : ProcedureReturn #BTRD_FC_TABLE6
    Case 7 : ProcedureReturn #BTRD_FC_TABLE7
    Case 8 : ProcedureReturn #BTRD_FC_TABLE8
    Case 9 : ProcedureReturn #BTRD_FC_TABLE9
  EndSelect

  ikp1 = 1.0 / (k + 1.0)
  t = (1.0/12.0 - (1.0/360.0 - (1.0/1260.0) * (ikp1*ikp1)) * (ikp1*ikp1)) * ikp1
  ProcedureReturn t
EndProcedure

Procedure InitBinomialHalf_BTRD(n.i)
  ; p is fixed to 0.5 for this simulator
  Protected.d p, q, spq
  Protected.d sqrt_npq

  If btrdTablesMutex = 0
    btrdTablesMutex = CreateMutex()
  EndIf

  LockMutex(btrdTablesMutex)
  If btrdTablesInitialized = 0 Or btrdParamN <> n

    p = 0.5
    q = 1.0 - p

    btrdParamP = p
    btrdIsFlipped = 0

    ; Mode m = floor((t+1)*p)
    btrdModeM = Round((n + 1.0) * p, #PB_Round_Down)

    ; BTRD is safe when n*p >= 10. Boost uses m < 11 as the small-mean cutoff.
    ; Keep that cutoff and use direct Bernoulli counting in that case.
    ; (Exact, and only used when the mean is tiny.)
    If btrdModeM < 11
      btrd_r = 0.0 : btrd_nr = 0.0 : btrd_npq = 0.0
      btrd_a = 0.0 : btrd_b = 0.0 : btrd_c = 0.0
      btrd_alpha = 0.0 : btrd_vr = 0.0 : btrd_urvr = 0.0
    Else
      btrd_r  = p / (1.0 - p)
      btrd_nr = (n + 1.0) * btrd_r
      btrd_npq = n * p * (1.0 - p)

      sqrt_npq = Sqr(btrd_npq)
      btrd_b = 1.15 + 2.53 * sqrt_npq
      btrd_a = -0.0873 + 0.0248 * btrd_b + 0.01 * p
      btrd_c = n * p + 0.5
      btrd_alpha = (2.83 + 5.1 / btrd_b) * sqrt_npq
      btrd_vr = 0.92 - 4.2 / btrd_b
      btrd_urvr = 0.86 * btrd_vr
    EndIf

    btrdParamN = n
    btrdTablesInitialized = 1
  EndIf
  UnlockMutex(btrdTablesMutex)
EndProcedure

Procedure.i BinomialHeads_BTRD_Exact(n.i, threadIndex.i)
  ; Exact Binomial(n, 0.5) via BTRD (Hormann).
  ; Uses per-thread RNG state and spare cache locally, writes back once.
  If btrdTablesInitialized = 0 Or btrdParamN <> n
    InitBinomialHalf_BTRD(n)
  EndIf

  Protected xst.q, spare.q, r.q, u32.q
  Protected hasSpare.i
  Protected.d u, v, us, km, rho, tval, h, f
  Protected k.i, i.i, nm.i, nk.i
  Protected.d absu, denom, vk
  Protected result.i

  xst = perThreadRngState(threadIndex)
  hasSpare = rngHasSpare(threadIndex)
  spare    = rngSpare(threadIndex)

  ; Small-mean fallback (exact, but only used when mean is tiny):
  ; Direct Bernoulli counting is simplest and stays exact.
  If btrdModeM < 11
    result = 0
    For i = 1 To n
      ; u in (0,1)
      If hasSpare
        u32 = spare
        hasSpare = 0
      Else
        BTPE_NEXT64(xst, r)
        u32 = r & $FFFFFFFF
        spare = (r >> 32) & $FFFFFFFF
        hasSpare = 1
      EndIf
      u = (u32 + 0.5) * 2.3283064365386963e-10
      If u < btrdParamP
        result + 1
      EndIf
    Next
    Goto btrd_done
  EndIf

btrd_loop:
  ; v = U(0,1)
  If hasSpare
    u32 = spare
    hasSpare = 0
  Else
    BTPE_NEXT64(xst, r)
    u32 = r & $FFFFFFFF
    spare = (r >> 32) & $FFFFFFFF
    hasSpare = 1
  EndIf
  v = (u32 + 0.5) * 2.3283064365386963e-10

  If v <= btrd_urvr
    u = v / btrd_vr - 0.43
    denom = 0.5 - Abs(u)
    If denom <= 0.0
      Goto btrd_loop
    EndIf
    k = Round(( (2.0 * btrd_a / denom + btrd_b) * u + btrd_c ), #PB_Round_Down)
    If k < 0 Or k > n
      Goto btrd_loop
    EndIf
    result = k
    Goto btrd_done
  EndIf

  If v >= btrd_vr
    ; u = U01 - 0.5
    If hasSpare
      u32 = spare
      hasSpare = 0
    Else
      BTPE_NEXT64(xst, r)
      u32 = r & $FFFFFFFF
      spare = (r >> 32) & $FFFFFFFF
      hasSpare = 1
    EndIf
    u = (u32 + 0.5) * 2.3283064365386963e-10
    u - 0.5
  Else
    u = v / btrd_vr - 0.93
    If u < 0.0
      u = -0.5 - u
    Else
      u = 0.5 - u
    EndIf
    ; v = U01 * v_r
    If hasSpare
      u32 = spare
      hasSpare = 0
    Else
      BTPE_NEXT64(xst, r)
      u32 = r & $FFFFFFFF
      spare = (r >> 32) & $FFFFFFFF
      hasSpare = 1
    EndIf
    v = (u32 + 0.5) * 2.3283064365386963e-10 * btrd_vr
  EndIf

  us = 0.5 - Abs(u)
  If us <= 0.0
    Goto btrd_loop
  EndIf

  k = Round(( (2.0 * btrd_a / us + btrd_b) * u + btrd_c ), #PB_Round_Down)
  If k < 0 Or k > n
    Goto btrd_loop
  EndIf

  v = v * btrd_alpha / (btrd_a / (us*us) + btrd_b)

  km = Abs(k - btrdModeM)

  If km <= 15.0
    f = 1.0
    If btrdModeM < k
      i = btrdModeM
      Repeat
        i + 1
        f * (btrd_nr / i - btrd_r)
      Until i = k
    ElseIf btrdModeM > k
      i = k
      Repeat
        i + 1
        v * (btrd_nr / i - btrd_r)
      Until i = btrdModeM
    EndIf
    If v <= f
      result = k
      Goto btrd_done
    Else
      Goto btrd_loop
    EndIf
  EndIf

  ; Final acceptance/rejection
  If v <= 0.0
    Goto btrd_loop
  EndIf
  vk = Log(v)

  rho = (km / btrd_npq) * ( (( (km/3.0 + 0.625) * km + (1.0/6.0) ) / btrd_npq) + 0.5 )
  tval = -(km * km) / (2.0 * btrd_npq)

  If vk < tval - rho
    result = k
    Goto btrd_done
  EndIf
  If vk > tval + rho
    Goto btrd_loop
  EndIf

  nm = n - btrdModeM + 1
  h = (btrdModeM + 0.5) * Log( (btrdModeM + 1.0) / (btrd_r * nm) ) + BTRD_Fc(btrdModeM) + BTRD_Fc(n - btrdModeM)

  nk = n - k + 1
  If vk <= h + (n + 1.0) * Log(nm / nk) + (k + 0.5) * Log( (nk * btrd_r) / (k + 1.0) ) - BTRD_Fc(k) - BTRD_Fc(n - k)
    result = k
    Goto btrd_done
  EndIf

  Goto btrd_loop

btrd_done:
  perThreadRngState(threadIndex) = xst
  rngSpare(threadIndex) = spare
  rngHasSpare(threadIndex) = hasSpare
  ProcedureReturn result
EndProcedure

; =============================================================================
; BINOMIAL (EXACT) - CPython random.binomialvariate (BG + BTRS)
; =============================================================================
; Ported (algorithmically) from CPython Lib/random.py.
; - For n*p < 10: BG (geometric method) -- O(n*p) expected time.
; - Else: BTRS (transformed rejection with squeeze) by Hormann.
;
; In this simulator p is fixed at 0.5, so symmetry is usually a no-op, but
; keep it for completeness.

#LOG2_D = 0.6931471805599453

Procedure InitBinomialHalf_CPython(n.i)
  ; p fixed to 0.5
  Protected.d p, q

  If cpyTablesMutex = 0
    cpyTablesMutex = CreateMutex()
  EndIf

  LockMutex(cpyTablesMutex)
  If cpyTablesInitialized = 0 Or cpyParamN <> n

    p = 0.5
    q = 1.0 - p

    cpyParamP = p
    cpyIsFlipped = 0

    ; Precompute constants used by CPython's BTRS branch.
    cpy_spq = Sqr(n * p * q)
    cpy_b = 1.15 + 2.53 * cpy_spq
    cpy_a = -0.0873 + 0.0248 * cpy_b + 0.01 * p
    cpy_c = n * p + 0.5
    cpy_vr = 0.92 - 4.2 / cpy_b

    cpy_alpha = (2.83 + 5.1 / cpy_b) * cpy_spq
    cpy_lpq = Log(p / q)

    cpyModeM = Round((n + 1.0) * p, #PB_Round_Down)

    ; CPython uses lgamma(). For integer arguments, a precomputed log-factorial table
    ; is exact and faster. Reuse BTPE's log-factorial table builder.
    InitBinomialHalf_BTPE(n)
    cpy_h = btpeLogFact(cpyModeM) + btpeLogFact(n - cpyModeM)

    ; BG method constant: c = log2(1-p)
    cpyLog2_1mp = Log(1.0 - p) / #LOG2_D

    cpyParamN = n
    cpyTablesInitialized = 1
  EndIf
  UnlockMutex(cpyTablesMutex)
EndProcedure

Procedure.i BinomialHeads_CPython_Exact(n.i, threadIndex.i)
  If cpyTablesInitialized = 0 Or cpyParamN <> n
    InitBinomialHalf_CPython(n)
  EndIf

  Protected xst.q, spare.q, r.q, u32.q
  Protected hasSpare.i
  Protected.d p, q
  Protected.d u, v, us
  Protected k.i
  Protected setupP.d
  Protected x.i, y.i
  Protected.d cLog2.d

  xst = perThreadRngState(threadIndex)
  hasSpare = rngHasSpare(threadIndex)
  spare    = rngSpare(threadIndex)

  p = cpyParamP
  q = 1.0 - p

  ; Fast path
  If n = 1
    ; u in (0,1)
    If hasSpare
      u32 = spare
      hasSpare = 0
    Else
      BTPE_NEXT64(xst, r)
      u32 = r & $FFFFFFFF
      spare = (r >> 32) & $FFFFFFFF
      hasSpare = 1
    EndIf
    u = (u32 + 0.5) * 2.3283064365386963e-10
    If u < p
      k = 1
    Else
      k = 0
    EndIf
    Goto cpy_done
  EndIf

  ; BG method when mean is small: n*p < 10
  If (n * p) < 10.0
    x = 0
    y = 0
    cLog2 = cpyLog2_1mp
    If cLog2 = 0.0
      k = 0
      Goto cpy_done
    EndIf
    Repeat
      ; y += floor(log2(U)/c) + 1
      ; U must be in (0,1).
      If hasSpare
        u32 = spare
        hasSpare = 0
      Else
        BTPE_NEXT64(xst, r)
        u32 = r & $FFFFFFFF
        spare = (r >> 32) & $FFFFFFFF
        hasSpare = 1
      EndIf
      u = (u32 + 0.5) * 2.3283064365386963e-10
      y + Round( ( (Log(u) / #LOG2_D) / cLog2 ), #PB_Round_Down ) + 1
      If y > n
        k = x
        Break
      EndIf
      x + 1
    ForEver
    Goto cpy_done
  EndIf

  ; BTRS (Hormann): transformed rejection with squeeze
cpy_loop:
  ; u = U01 - 0.5
  If hasSpare
    u32 = spare
    hasSpare = 0
  Else
    BTPE_NEXT64(xst, r)
    u32 = r & $FFFFFFFF
    spare = (r >> 32) & $FFFFFFFF
    hasSpare = 1
  EndIf
  u = (u32 + 0.5) * 2.3283064365386963e-10
  u - 0.5

  us = 0.5 - Abs(u)
  If us <= 0.0
    Goto cpy_loop
  EndIf

  k = Round(( (2.0 * cpy_a / us + cpy_b) * u + cpy_c ), #PB_Round_Down)
  If k < 0 Or k > n
    Goto cpy_loop
  EndIf

  ; v = U01
  If hasSpare
    u32 = spare
    hasSpare = 0
  Else
    BTPE_NEXT64(xst, r)
    u32 = r & $FFFFFFFF
    spare = (r >> 32) & $FFFFFFFF
    hasSpare = 1
  EndIf
  v = (u32 + 0.5) * 2.3283064365386963e-10

  If us >= 0.07 And v <= cpy_vr
    Goto cpy_accept
  EndIf

  v = v * cpy_alpha / (cpy_a / (us*us) + cpy_b)
  If v <= 0.0
    Goto cpy_loop
  EndIf

  ; Acceptance-rejection test:
  ; CPython compares log(v) to the log of the rescaled binomial distribution.
  ; Use precomputed log-factorials (exact for integer inputs).
  If Log(v) <= cpy_h - btpeLogFact(k) - btpeLogFact(n - k) + (k - cpyModeM) * cpy_lpq
    Goto cpy_accept
  EndIf

  Goto cpy_loop

cpy_accept:
  ; Symmetry (kept for completeness)
  If cpyIsFlipped
    k = n - k
  EndIf

cpy_done:
  perThreadRngState(threadIndex) = xst
  rngSpare(threadIndex) = spare
  rngHasSpare(threadIndex) = hasSpare
  ProcedureReturn k
EndProcedure

; =============================================================================
; Kernel selection helper (applies #FORCE_KERNEL safely)
; =============================================================================
Procedure SetKernelModeFromForce()
  Shared configuredKernelPolicy
  Shared detectedSupportsAVX.i, detectedSupportsAVX2.i, detectedSupportsAVX512.i, detectedSupportsPOPCNT.i

  Protected detected.i

  detected = IsAVXSupported()
  kernelSelectionSuffix = ""
  kernelSelectionWarning = ""

  Select configuredKernelPolicy

    Case 5
      activeKernelSupportLevel = detected
      kernelSelectionSuffix = " (auto)"

    Case 4
      If detectedSupportsAVX512
        activeKernelSupportLevel = 4
        kernelSelectionSuffix = " (forced AVX-512)"
      Else
        activeKernelSupportLevel = detected
        kernelSelectionSuffix = " (forced AVX-512 unavailable -> auto)"
        kernelSelectionWarning = "Kernel note: forced AVX-512 unavailable; auto level " + Str(detected) + "."
      EndIf

    Case 3
      If detectedSupportsAVX2
        activeKernelSupportLevel = 3
        kernelSelectionSuffix = " (forced AVX2)"
      Else
        activeKernelSupportLevel = detected
        kernelSelectionSuffix = " (forced AVX2 unavailable -> auto)"
        kernelSelectionWarning = "Kernel note: forced AVX2 unavailable; auto level " + Str(detected) + "."
      EndIf

    Case 2
      If detectedSupportsAVX
        activeKernelSupportLevel = 2
        kernelSelectionSuffix = " (forced AVX)"
      Else
        activeKernelSupportLevel = detected
        kernelSelectionSuffix = " (forced AVX unavailable -> auto)"
        kernelSelectionWarning = "Kernel note: forced AVX unavailable; auto level " + Str(detected) + "."
      EndIf

    Case 1
      If detectedSupportsPOPCNT
        activeKernelSupportLevel = 1
        kernelSelectionSuffix = " (forced POPCNT)"
      Else
        activeKernelSupportLevel = detected
        kernelSelectionSuffix = " (forced POPCNT unavailable -> auto)"
        kernelSelectionWarning = "Kernel note: forced POPCNT unavailable; auto level " + Str(detected) + "."
      EndIf

    Default
      activeKernelSupportLevel = 0
      kernelSelectionSuffix = " (forced SWAR)"

  EndSelect

EndProcedure

; =============================================================================
; Buffered file output using WORD array (no *buffer pointers)
; =============================================================================
Procedure FlushBuffer()
  Shared isFileOutputEnabled.i, outputFile
  Protected bytes.q
  Protected bytesWritten.i

  If isFileOutputEnabled = 0 Or outputFile = 0
    outputDeviationWordsUsed = 0
    ProcedureReturn
  EndIf

  If outputDeviationWordsUsed > 0
    bytes = outputDeviationWordsUsed * 2
    bytesWritten = WriteData(outputFile, @outputDeviationWords(), bytes)
    If bytesWritten <> bytes
      FatalError("WriteData() failed or partial write (" + Str(bytesWritten) + "/" + Str(bytes) + " bytes).")
    EndIf
    outputDeviationWordsUsed = 0
  EndIf
EndProcedure

; Store a local batch of WORDs into buffer; caller holds mutex.
; Avoid pointer copying. The simple loop is fast enough at 512 words.
Procedure StoreBatchWords(Array localBatch.w(1), localCount.i)
  Shared isFileOutputEnabled.i
  If isFileOutputEnabled = 0 : ProcedureReturn : EndIf
  Protected i.i

  If localCount <= 0
    ProcedureReturn
  EndIf

  ; Ensure enough space (flush if needed)
  If outputDeviationWordsUsed + localCount > configuredOutputBufferWordCount
    FlushBuffer()
  EndIf

  For i = 0 To localCount - 1
    outputDeviationWords(outputDeviationWordsUsed + i) = localBatch(i)
  Next

  outputDeviationWordsUsed + localCount

  If outputDeviationWordsUsed >= configuredOutputBufferWordCount
    FlushBuffer()
  EndIf
EndProcedure

; =============================================================================
; Small helpers
; =============================================================================
Procedure.i MinIntValue(value1.i, value2.i)
  Protected mask.i
  mask = (value1 - value2) >> 63
  ProcedureReturn (value1 & mask) | (value2 & ~mask)
EndProcedure

Procedure.s FormatDuration(seconds.d)
  Protected total.q, h.q, m.q, s.q

  If seconds <= 0.0
    ProcedureReturn "000h:00m:00s"
  EndIf

  total = Int(seconds)
  h = total / 3600
  m = (total % 3600) / 60
  s = total % 60

  ProcedureReturn RSet(Str(h), 3, "0") + "h:" + RSet(Str(m), 2, "0") + "m:" + RSet(Str(s), 2, "0") + "s"
EndProcedure

; =============================================================================
; BINOMIAL APPROX: pointer-free per-thread PRNG
; =============================================================================

; Seed mix function to decorrelate thread seeds.
Procedure.q Mix64(x.q)
  x ! ((x >> 33) & #LSR_MASK_33)
  x * $FF51AFD7ED558CCD
  x ! ((x >> 33) & #LSR_MASK_33)
  x * $C4CEB9FE1A85EC53
  x ! ((x >> 33) & #LSR_MASK_33)
  ProcedureReturn x
EndProcedure

Procedure.q InitThreadRngState(base.q, threadIndex.i)
  Protected s.q
  s = base + (threadIndex * $9E3779B97F4A7C15)
  s = Mix64(s)
  If s = 0
    s = $D1B54A32D192ED03
  EndIf
  ProcedureReturn s
EndProcedure

; XorShift64* step for one specific thread index (updates perThreadRngState(threadIndex)).
Procedure.q XorShift64Star(threadIndex.i)
  Protected x.q

  x = perThreadRngState(threadIndex)

  x ! ((x >> 12) & #LSR_MASK_12)
  x ! (x << 25)
  x ! ((x >> 27) & #LSR_MASK_27)

  perThreadRngState(threadIndex) = x
  ProcedureReturn x * 2685821657736338717
EndProcedure

; Uniform in [0,1) from top 53 bits.
Procedure.d Uniform01(threadIndex.i)
  Protected v.q
  Protected mantissa.q

  v = XorShift64Star(threadIndex)
  mantissa = (v >> 11) & #LSR_MASK_11
  ProcedureReturn mantissa * 1.1102230246251565e-16 ; 2^-53
EndProcedure

; Approximate Binomial(n,0.5) heads count using CLT normal approximation.
Procedure.i BinomialHeads_CLT_K(n.i, threadIndex.i, sigma.d, k.i, kHalf.d, zScale.d)
  Protected sumU.d
  Protected i.i
  Protected z.d
  Protected headsD.d
  Protected headsI.i

  sumU = 0.0
  For i = 1 To k
    sumU + Uniform01(threadIndex)
  Next

  z = (sumU - kHalf) * zScale
  headsD = (n * 0.5) + (z * sigma)

  headsI = Int(headsD + 0.5)
  If headsI < 0 : headsI = 0 : EndIf
  If headsI > n : headsI = n : EndIf

  ProcedureReturn headsI
EndProcedure

; =============================================================================
; Kernels (BIT-EXACT mode, full 16-quad blocks only)
; =============================================================================

; -----------------------------------------------------------------------------
; AVX2 popcount emulation tables (32 bytes each, used with VPSHUFB)
; - AVX2 has no native vector popcount.
; - Emulate popcount by counting low/high nibbles via a 16-entry LUT.
; -----------------------------------------------------------------------------
DataSection
  AVX2_PopcntLUT:
    Data.a 0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4
    Data.a 0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4

  AVX2_LowNibbleMask:
    Data.a $0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F
    Data.a $0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F
EndDataSection

Procedure.q Kernel_AVX512_VPOPCNTQ(arrayPtr.i, quadEnd.q, zmmSumBuffer.i)
  Protected result.q

  If zmmSumBuffer = 0
    FatalError("AVX-512 kernel requested but zmmSumBuffer is NULL.")
  EndIf

  !MOV r8,  [p.v_arrayPtr]
  !MOV r9,  [p.v_quadEnd]
  !XOR rcx, rcx
  !XOR r10, r10
  !VPXORQ zmm2, zmm2, zmm2

  !quadloop_avx512:
    !CMP rcx, r9
    !JG  endloop_avx512

    !VMOVDQU64 zmm0, [r8 + rcx*8]
    !VMOVDQU64 zmm1, [r8 + rcx*8 + 64]

    !VPOPCNTQ  zmm0, zmm0
    !VPOPCNTQ  zmm1, zmm1

    !VPADDQ    zmm0, zmm0, zmm1
    !VPADDQ    zmm2, zmm2, zmm0

    !ADD rcx, 16
    !INC r10
    !JMP quadloop_avx512

  !endloop_avx512:

  !MOV rdx, [p.v_zmmSumBuffer]
  !VMOVDQU64 [rdx], zmm2

  !MOV r11, [rdx + 0]
  !ADD r11, [rdx + 8]
  !ADD r11, [rdx + 16]
  !ADD r11, [rdx + 24]
  !ADD r11, [rdx + 32]
  !ADD r11, [rdx + 40]
  !ADD r11, [rdx + 48]
  !ADD r11, [rdx + 56]

  !MOV rax, r10
  !SHL rax, 9
  !SUB r11, rax

  !MOV [p.v_result], r11
  ProcedureReturn result
EndProcedure

Procedure.q Kernel_AVX_PSHUFB_Popcnt(arrayPtr.i, quadEnd.q, xmmSumBuffer.i)
  Protected result.q
  Protected lutPtr.i  = ?AVX2_PopcntLUT
  Protected maskPtr.i = ?AVX2_LowNibbleMask

  !MOV  r8,  [p.v_arrayPtr]        ; r8  = base pointer (bytes)
  !MOV  r9,  [p.v_quadEnd]         ; r9  = inclusive quad index
  !INC  r9                         ; r9  = quadEnd+1
  !SHR  r9,  4                     ; r9  = blocks = (quadEnd+1)/16
  !MOV  r10, r9                    ; r10 = blocks (saved for expected subtract)

  !TEST r9,  r9
  !JZ   endloop_avx_popcnt

  ; Load LUT + mask (first 16 bytes used)
  !MOV      rdx, [p.v_lutPtr]
  !VMOVDQU  xmm3, [rdx]
  !MOV      rdx, [p.v_maskPtr]
  !VMOVDQU  xmm4, [rdx]

  ; Two accumulators reduce VPADDQ dependency pressure, xmm7 stays zero for VPSADBW
  !VPXOR xmm5, xmm5, xmm5
  !VPXOR xmm6, xmm6, xmm6
  !VPXOR xmm7, xmm7, xmm7

  !quadloop_avx_popcnt:

    ; 8 x 16B = 128B (16 quads)
    !VMOVDQU xmm0, [r8 + 0]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm5, xmm5, xmm1

    !VMOVDQU xmm0, [r8 + 16]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm6, xmm6, xmm1

    !VMOVDQU xmm0, [r8 + 32]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm5, xmm5, xmm1

    !VMOVDQU xmm0, [r8 + 48]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm6, xmm6, xmm1

    !VMOVDQU xmm0, [r8 + 64]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm5, xmm5, xmm1

    !VMOVDQU xmm0, [r8 + 80]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm6, xmm6, xmm1

    !VMOVDQU xmm0, [r8 + 96]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm5, xmm5, xmm1

    !VMOVDQU xmm0, [r8 + 112]
    !VPAND   xmm1, xmm0, xmm4
    !VPSRLW  xmm2, xmm0, 4
    !VPAND   xmm2, xmm2, xmm4
    !VPSHUFB xmm1, xmm3, xmm1
    !VPSHUFB xmm2, xmm3, xmm2
    !VPADDB  xmm1, xmm1, xmm2
    !VPSADBW xmm1, xmm1, xmm7
    !VPADDQ  xmm6, xmm6, xmm1

    !ADD r8, 128
    !DEC r9
    !JNZ quadloop_avx_popcnt

  !endloop_avx_popcnt:

  !VPADDQ  xmm5, xmm5, xmm6

  ; In-register horizontal sum (avoid temporary buffer store/load)
  !VPEXTRQ r11, xmm5, 0
  !VPEXTRQ rax, xmm5, 1
  !ADD r11, rax

  ; subtract expectation: blocks * 512
  !MOV rax, r10
  !SHL rax, 9
  !SUB r11, rax

  !VZEROUPPER
  !MOV [p.v_result], r11
  ProcedureReturn result
EndProcedure

Procedure.q Kernel_AVX2_PSHUFB_Popcnt(arrayPtr.i, quadEnd.q, ymmSumBuffer.i)
  Protected result.q
  Protected lutPtr.i  = ?AVX2_PopcntLUT
  Protected maskPtr.i = ?AVX2_LowNibbleMask

  ; blocks = (quadEnd+1)/16  (quadEnd is inclusive, and expected to be (16N-1))
  !MOV  r8,  [p.v_arrayPtr]        ; r8  = base pointer (bytes)
  !MOV  r9,  [p.v_quadEnd]
  !INC  r9                         ; r9  = quadEnd+1
  !SHR  r9,  4                     ; r9  = blocks
  !MOV  r10, r9                    ; r10 = blocks (saved for expected subtraction)

  !TEST r9,  r9
  !JZ   endloop_avx2_popcnt

  ; Load LUT + mask
  !MOV     rdx, [p.v_lutPtr]
  !VMOVDQU ymm3, [rdx]             ; ymm3 = nibble popcount LUT (0..15)
  !MOV     rdx, [p.v_maskPtr]
  !VMOVDQU ymm4, [rdx]             ; ymm4 = 0x0F mask per byte

  ; Two accumulators reduce VPADDQ chain depth; ymm6 stays zero for VPSADBW
  !VPXOR ymm5, ymm5, ymm5          ; accumulator A
  !VPXOR ymm6, ymm6, ymm6          ; zero vector
  !VPXOR ymm7, ymm7, ymm7          ; accumulator B

  !quadloop_avx2_popcnt:

    ; ---- 32 bytes @ +0 ----
    !VMOVDQU ymm0, [r8 + 0]
    !VPAND   ymm1, ymm0, ymm4
    !VPSRLW  ymm2, ymm0, 4
    !VPAND   ymm2, ymm2, ymm4
    !VPSHUFB ymm1, ymm3, ymm1
    !VPSHUFB ymm2, ymm3, ymm2
    !VPADDB  ymm1, ymm1, ymm2
    !VPSADBW ymm1, ymm1, ymm6      ; sums bytes -> 4x qword
    !VPADDQ  ymm5, ymm5, ymm1

    ; ---- 32 bytes @ +32 ----
    !VMOVDQU ymm0, [r8 + 32]
    !VPAND   ymm1, ymm0, ymm4
    !VPSRLW  ymm2, ymm0, 4
    !VPAND   ymm2, ymm2, ymm4
    !VPSHUFB ymm1, ymm3, ymm1
    !VPSHUFB ymm2, ymm3, ymm2
    !VPADDB  ymm1, ymm1, ymm2
    !VPSADBW ymm1, ymm1, ymm6
    !VPADDQ  ymm7, ymm7, ymm1

    ; ---- 32 bytes @ +64 ----
    !VMOVDQU ymm0, [r8 + 64]
    !VPAND   ymm1, ymm0, ymm4
    !VPSRLW  ymm2, ymm0, 4
    !VPAND   ymm2, ymm2, ymm4
    !VPSHUFB ymm1, ymm3, ymm1
    !VPSHUFB ymm2, ymm3, ymm2
    !VPADDB  ymm1, ymm1, ymm2
    !VPSADBW ymm1, ymm1, ymm6
    !VPADDQ  ymm5, ymm5, ymm1

    ; ---- 32 bytes @ +96 ----
    !VMOVDQU ymm0, [r8 + 96]
    !VPAND   ymm1, ymm0, ymm4
    !VPSRLW  ymm2, ymm0, 4
    !VPAND   ymm2, ymm2, ymm4
    !VPSHUFB ymm1, ymm3, ymm1
    !VPSHUFB ymm2, ymm3, ymm2
    !VPADDB  ymm1, ymm1, ymm2
    !VPSADBW ymm1, ymm1, ymm6
    !VPADDQ  ymm7, ymm7, ymm1

    !ADD r8, 128
    !DEC r9
    !JNZ quadloop_avx2_popcnt

  !endloop_avx2_popcnt:

  !VPADDQ  ymm5, ymm5, ymm7

  ; In-register horizontal reduction of 4x qword accumulator
  !VEXTRACTI128 xmm0, ymm5, 1
  !VPADDQ       xmm5, xmm5, xmm0
  !VPEXTRQ      r11, xmm5, 0
  !VPEXTRQ      rax, xmm5, 1
  !ADD          r11, rax

  ; subtract expectation: blocks * 512
  !MOV rax, r10
  !SHL rax, 9
  !SUB r11, rax

  !VZEROUPPER
  !MOV [p.v_result], r11
  ProcedureReturn result
EndProcedure

Procedure.q Kernel_POPCNT_Tuned(arrayPtr.i, quadEnd.q)
  Protected result.q

  !MOV r8,  [p.v_arrayPtr]
  !MOV r9,  [p.v_quadEnd]
  !INC r9
  !SHR r9, 4

  !XOR r10, r10
  !TEST r9, r9
  !JZ  endloop_popcnt_tuned

  !quadloop_popcnt_tuned:

    !POPCNT r11, [r8 + 0]
    !POPCNT rax, [r8 + 8]
    !ADD    r11, rax
    !POPCNT rax, [r8 + 16]
    !ADD    r11, rax
    !POPCNT rax, [r8 + 24]
    !ADD    r11, rax
    !POPCNT rax, [r8 + 32]
    !ADD    r11, rax
    !POPCNT rax, [r8 + 40]
    !ADD    r11, rax
    !POPCNT rax, [r8 + 48]
    !ADD    r11, rax
    !POPCNT rax, [r8 + 56]
    !ADD    r11, rax

    !POPCNT rdx, [r8 + 64]
    !POPCNT rax, [r8 + 72]
    !ADD    rdx, rax
    !POPCNT rax, [r8 + 80]
    !ADD    rdx, rax
    !POPCNT rax, [r8 + 88]
    !ADD    rdx, rax
    !POPCNT rax, [r8 + 96]
    !ADD    rdx, rax
    !POPCNT rax, [r8 + 104]
    !ADD    rdx, rax
    !POPCNT rax, [r8 + 112]
    !ADD    rdx, rax
    !POPCNT rax, [r8 + 120]
    !ADD    rdx, rax

    !ADD r11, rdx
    !LEA r10, [r10 + r11 - 512]

    !ADD r8, 128
    !DEC r9
    !JNZ quadloop_popcnt_tuned

  !endloop_popcnt_tuned:
  !MOV [p.v_result], r10
  ProcedureReturn result
EndProcedure

Procedure.q Kernel_SWAR_Unroll8(Array randomQuadBuffer.q(1), quadEnd.q)
  Protected headsSum.q, expected.q
  Protected quadIndex.q
  Protected integerValue.q
  Protected headsCount.i

  headsSum = 0

  For quadIndex = 0 To quadEnd Step 8

    integerValue = randomQuadBuffer(quadIndex + 0)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

    integerValue = randomQuadBuffer(quadIndex + 1)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

    integerValue = randomQuadBuffer(quadIndex + 2)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

    integerValue = randomQuadBuffer(quadIndex + 3)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

    integerValue = randomQuadBuffer(quadIndex + 4)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

    integerValue = randomQuadBuffer(quadIndex + 5)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

    integerValue = randomQuadBuffer(quadIndex + 6)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

    integerValue = randomQuadBuffer(quadIndex + 7)
    SWAR_POPCOUNT64(integerValue, headsCount)
    headsSum + headsCount

  Next

  expected = (quadEnd + 1) * 32
  ProcedureReturn (headsSum - expected)
EndProcedure

; =============================================================================
; Thread worker (parameter is ONLY threadIndex, no pointers/structs)
; =============================================================================
Procedure CoinFlipSimulation64_RunOnce(threadIndex.q)

  Protected runIndex.q
  Protected maxDeviation.q, maxDeviationPercent.d
  Protected absoluteDeviation.q

  Protected flipsNeeded.q
  Protected instancesToSimulate.q

  ; BIT-EXACT variables
  Protected coinFlipResult.q
  Protected quadsNeeded.q
  Protected unusedBits.q, validBitsToUse.q, bitMask.q
  Protected one.q = 1
  Protected integerValue.q
  Protected headsCount.i
  Protected flipIndex.q, quadIndex.q
  Protected Dim randomQuadBuffer.q(1)
  Protected arrayPtr.i
  Protected quadEnd.q
  Protected zmmSumBuffer.i
  Protected ymmSumBuffer.i
  Protected xmmSumBuffer.i
  Protected kernelResult.q
  Protected startIndex.q

  ; BINOMIAL variables
  Protected n.i, expectedHeads.i
  Protected sigma.d
  Protected k.i
  Protected kHalf.d
  Protected zScale.d
  Protected headsI.i
  Protected diffI.i

  ; Local batch
  Protected localBatchSamples.i
  localBatchSamples = configuredLocalBatchSamples
  If localBatchSamples < 1 : localBatchSamples = 1 : EndIf
  Protected Dim localBatch.w(localBatchSamples - 1)
  Protected localCount.i
  Protected localFlushLimit.i
  Protected firstFlushLimit.i
  Protected progressPublishLimit.i
  Protected flushJitter.i

  ; Keep steady-state batches full-sized for throughput. Only the first flush is
  ; staggered, which avoids a startup convoy without doubling long-run lock cost.
  localFlushLimit = localBatchSamples
  firstFlushLimit = localBatchSamples
  If localBatchSamples >= 32
    flushJitter = (threadIndex * 37) % (localBatchSamples / 2)
    firstFlushLimit = localBatchSamples - flushJitter
    If firstFlushLimit < (localBatchSamples / 2) : firstFlushLimit = localBatchSamples / 2 : EndIf
    If firstFlushLimit < 16 : firstFlushLimit = 16 : EndIf
  EndIf
  localFlushLimit = firstFlushLimit

  ; No-graph/no-file runs should stay very fast. Publish progress coarsely so
  ; the UI has movement without making the hot loop lock every small batch.
  progressPublishLimit = localBatchSamples * 16
  If progressPublishLimit < 4096 : progressPublishLimit = 4096 : EndIf

  ; Live distribution stats (per local flush batch, merged into global stats)
  Protected batchStatsCount.q
  Protected batchStatsMean.d
  Protected batchStatsM2.d
  Protected batchStatsCountAboveThreshold.q
  Protected batchStatsMaxValue.w
  Protected batchStatsValue.d
  Protected batchStatsDelta.d

  ; Graph collection is frozen per run so benchmark labels match measured work.
  Protected plotCollectEnabled.i

  ; Plot tick marks: keep the actual deviation values >= threshold (per flush batch)
  Protected Dim localAbove.w(255)
  Protected localAboveCount.i

  Protected collectToBatch.i  ; 1 when per-sample values are required (save file and/or live plot)
  Shared outputFile, ioMutex, isFileOutputEnabled
  Shared completedWorkBlockCount.q, workerThreadCount.q, totalSamplesWritten.q
  Shared maxDeviationPercentOverall.d, simulationStartMillis.q, maxDeviationAbsoluteOverall.q
  Shared activeKernelSupportLevel.i

  Shared configuredInstancesPerWorkBlock.q, configuredWorkBlocksPerThread.q, configuredFlipsPerSample.q
  Shared configuredSamplerMode.i, configuredBinomialMethod.i, configuredBinomialCltK.i
  Shared configuredLocalBatchSamples.i
  Shared simulationIsRunning.i, stopRequested.i, workerThreadsFinished.i, workerThreadsTotal.i
  Shared progressPercent.i
  Shared fatalErrorFlag.i
  Shared runLiveGraphEnabled.i

  flipsNeeded = configuredFlipsPerSample
  instancesToSimulate = configuredInstancesPerWorkBlock

  plotCollectEnabled = runLiveGraphEnabled

      collectToBatch = Bool(isFileOutputEnabled Or plotCollectEnabled)
  ; ---------------------------
  ; BIT-EXACT setup
  ; ---------------------------
  If configuredSamplerMode = 0

    quadsNeeded = (flipsNeeded + 63) / 64
    quadsNeeded = Int(quadsNeeded)
    ReDim randomQuadBuffer(quadsNeeded - 1)

    zmmSumBuffer = 0
    ymmSumBuffer = 0
    xmmSumBuffer = 0

    If activeKernelSupportLevel = 4
      zmmSumBuffer = AllocateMemory(64)
      If zmmSumBuffer = 0
        FatalError("Memory allocation failed (zmmSumBuffer).")
      EndIf
    EndIf

  EndIf

  ; ---------------------------
  ; BINOMIAL setup
  ; ---------------------------
  If configuredSamplerMode = 1
    n = flipsNeeded
    expectedHeads = n / 2
    sigma = Sqr(n * 0.25)

    ; CLT parameters are only needed when Binomial method = 2 (CLT K approx).
    If configuredBinomialMethod = 2
      k = configuredBinomialCltK
      If k < 1 : k = 1 : EndIf
      kHalf = k * 0.5
      zScale = Sqr(12.0 / k)
    Else
      k = 1 : kHalf = 0.5 : zScale = 1.0
    EndIf
  EndIf

  ; Each thread performs workBlocksPerThread run-blocks
  For runIndex = 1 To configuredWorkBlocksPerThread

    If stopRequested Or fatalErrorFlag
      Goto thread_done
    EndIf

    maxDeviation = 0
    maxDeviationPercent = 0.0
    localCount = 0

        plotCollectEnabled = runLiveGraphEnabled

    ; Reset batch stats used for the live bell-curve plot
    batchStatsCount = 0
    batchStatsMean  = 0.0
    batchStatsM2    = 0.0
    batchStatsCountAboveThreshold = 0
    batchStatsMaxValue = 0

    localAboveCount = 0
    For flipIndex = 1 To instancesToSimulate

      ; -----------------------------------------------------------------------
      ; BINOMIAL-APPROX mode
      ; -----------------------------------------------------------------------
      If configuredSamplerMode = 1
        Select configuredBinomialMethod
          Case 0
            headsI = BinomialHeads_BTPE_Exact(n, threadIndex, sigma) ; Exact BTPE
          Case 1
            headsI = BinomialHeads_BTRD_Exact(n, threadIndex)        ; Exact BTRD (Hormann)
          Case 2
            headsI = BinomialHeads_CLT_K(n, threadIndex, sigma, k, kHalf, zScale) ; Approx CLT (K uniforms)
          Case 3
            headsI = BinomialHeads_CPython_Exact(n, threadIndex)     ; Exact CPython (BG+BTRS)
          Default
            headsI = BinomialHeads_BTPE_Exact(n, threadIndex, sigma)
        EndSelect
        diffI = headsI - expectedHeads
        absoluteDeviation = Abs(diffI)

      ; -----------------------------------------------------------------------
      ; BIT-EXACT mode
      ; -----------------------------------------------------------------------
      Else
        coinFlipResult = 0

        RandomData(@randomQuadBuffer(), quadsNeeded * SizeOf(Quad))
        arrayPtr = @randomQuadBuffer()

        quadEnd = quadsNeeded - (quadsNeeded % 16) - 1

        Select activeKernelSupportLevel
          Case 4
            kernelResult = Kernel_AVX512_VPOPCNTQ(arrayPtr, quadEnd, zmmSumBuffer)
          Case 3
            kernelResult = Kernel_AVX2_PSHUFB_Popcnt(arrayPtr, quadEnd, ymmSumBuffer)
          Case 2
            kernelResult = Kernel_AVX_PSHUFB_Popcnt(arrayPtr, quadEnd, xmmSumBuffer)
          Case 1
            kernelResult = Kernel_POPCNT_Tuned(arrayPtr, quadEnd)
          Default
            kernelResult = Kernel_SWAR_Unroll8(randomQuadBuffer(), quadEnd)
        EndSelect

        coinFlipResult + kernelResult

        startIndex = quadsNeeded - (quadsNeeded % 16)

        For quadIndex = startIndex To quadsNeeded - 1

          integerValue = randomQuadBuffer(quadIndex)

          If quadIndex = quadsNeeded - 1
            unusedBits = (quadsNeeded * 64) - flipsNeeded
            validBitsToUse = 64 - unusedBits

            ; Build mask safely (avoid $FFFFFFFFFFFFFFFF >> unusedBits issues)
            If unusedBits = 0
              bitMask = -1
            Else
              ; validBitsToUse is 1..63 here
              bitMask = (one << validBitsToUse) - 1
            EndIf

            integerValue & bitMask
          EndIf

          SWAR_POPCOUNT64(integerValue, headsCount)

          If quadIndex = quadsNeeded - 1
            coinFlipResult + ((2 * headsCount - validBitsToUse + (validBitsToUse % 2)) / 2)
          Else
            coinFlipResult + (headsCount - 32)
          EndIf

        Next

        absoluteDeviation = Abs(coinFlipResult)
      EndIf

      ; Clamp to 16-bit range
      absoluteDeviation = MinIntValue(absoluteDeviation, 65535)

      ; Update batch statistics for the live plot (Welford running mean/variance).
; This is optional and can be turned off for maximum simulation speed.
If plotCollectEnabled
  batchStatsCount + 1
  batchStatsValue = absoluteDeviation
  batchStatsDelta = batchStatsValue - batchStatsMean
  batchStatsMean + batchStatsDelta / batchStatsCount
  batchStatsM2 + batchStatsDelta * (batchStatsValue - batchStatsMean)

  If absoluteDeviation >= configuredPlotThreshold
    batchStatsCountAboveThreshold + 1

    ; Store the actual value for blue tick marks on the midline (rare events)
    If localAboveCount > ArraySize(localAbove())
      ReDim localAbove.w(localAboveCount * 2 + 256)
    EndIf
    localAbove(localAboveCount) = absoluteDeviation
    localAboveCount + 1
  EndIf

  If absoluteDeviation > batchStatsMaxValue
    batchStatsMaxValue = absoluteDeviation
  EndIf
EndIf

      If maxDeviation < absoluteDeviation
        maxDeviation = absoluteDeviation
      EndIf

      ; Add to local batch only when per-sample values are required.
      If collectToBatch
        localBatch(localCount) = absoluteDeviation
      EndIf
      localCount + 1

      ; Fast path: when not saving and live plot is OFF, avoid periodic flush/locks
      If collectToBatch
        ; Flush local batch periodically (reduces lock overhead)
        If (localCount >= localFlushLimit) Or stopRequested Or fatalErrorFlag
          If isFileOutputEnabled
            LockMutex(fileMutex)
              StoreBatchWords(localBatch(), localCount)
            UnlockMutex(fileMutex)
          EndIf

          LockMutex(ioMutex)
            totalSamplesWritten + localCount

            ; Merge the batch statistics for the live plot (only if enabled)
            If plotCollectEnabled And batchStatsCount > 0
              MergeDeviationStats(batchStatsCount, batchStatsMean, batchStatsM2, batchStatsCountAboveThreshold, batchStatsMaxValue)
              If localAboveCount > 0
                AppendPlotAboveValues(@localAbove(), localAboveCount)
              EndIf
            EndIf
          UnlockMutex(ioMutex)
          localCount = 0
          batchStatsCount = 0
          batchStatsMean  = 0.0
          batchStatsM2    = 0.0
          batchStatsCountAboveThreshold = 0
          batchStatsMaxValue = 0
          localAboveCount = 0
          plotCollectEnabled = runLiveGraphEnabled
          collectToBatch = Bool(isFileOutputEnabled Or plotCollectEnabled)
          localFlushLimit = localBatchSamples

          If stopRequested Or fatalErrorFlag
            Goto thread_done
          EndIf
        EndIf
      Else
        ; Publish lightweight progress periodically even when not collecting
        ; plot/file data. This keeps throughput/progress from arriving in
        ; synchronized block-end waves.
        If (localCount >= progressPublishLimit) Or stopRequested Or fatalErrorFlag
          LockMutex(ioMutex)
            totalSamplesWritten + localCount
          UnlockMutex(ioMutex)
          localCount = 0

          If stopRequested Or fatalErrorFlag
            Goto thread_done
          EndIf
        EndIf
      EndIf

    Next

    ; Flush remainder / commit progress
    If localCount > 0
      If collectToBatch
        If isFileOutputEnabled
          LockMutex(fileMutex)
            StoreBatchWords(localBatch(), localCount)
          UnlockMutex(fileMutex)
        EndIf

        LockMutex(ioMutex)
          totalSamplesWritten + localCount

          ; Merge the batch statistics for the live plot (only if enabled)
          If plotCollectEnabled And batchStatsCount > 0
            MergeDeviationStats(batchStatsCount, batchStatsMean, batchStatsM2, batchStatsCountAboveThreshold, batchStatsMaxValue)
              If localAboveCount > 0
                AppendPlotAboveValues(@localAbove(), localAboveCount)
              EndIf
          EndIf
        UnlockMutex(ioMutex)
      Else
        ; no-collect fast path: only update the global sample counter once per work block
        LockMutex(ioMutex)
          totalSamplesWritten + localCount
        UnlockMutex(ioMutex)
      EndIf

      plotCollectEnabled = runLiveGraphEnabled
      collectToBatch = Bool(isFileOutputEnabled Or plotCollectEnabled)

      localCount = 0
      batchStatsCount = 0
      batchStatsMean  = 0.0
      batchStatsM2    = 0.0
      batchStatsCountAboveThreshold = 0
      batchStatsMaxValue = 0

          localAboveCount = 0
      If stopRequested Or fatalErrorFlag
        Goto thread_done
      EndIf
    EndIf
    ; Progress update (completed work only)
    maxDeviationPercent = Round(((maxDeviation * 100.0) / flipsNeeded) * 1000, #PB_Round_Down) / 1000

    LockMutex(ioMutex)
      completedWorkBlockCount + 1

      ; Track global maxima
      If maxDeviation > maxDeviationAbsoluteOverall
        maxDeviationAbsoluteOverall = maxDeviation
      EndIf
      If maxDeviationPercent > maxDeviationPercentOverall
        maxDeviationPercentOverall = maxDeviationPercent
      EndIf
    UnlockMutex(ioMutex)
  Next

thread_done:

  ; Mark this worker as finished (used by GUI timer to finalize)
  LockMutex(ioMutex)
    workerThreadsFinished + 1
  UnlockMutex(ioMutex)
  PostEvent(#EventThreadFinished, #WinMain, 0, 0, 0)

  If configuredSamplerMode = 0
    If zmmSumBuffer
      FreeMemory(zmmSumBuffer)
    EndIf
    If ymmSumBuffer
      FreeMemory(ymmSumBuffer)
    EndIf
    If xmmSumBuffer
      FreeMemory(xmmSumBuffer)
    EndIf
  EndIf

EndProcedure

; =============================================================================
; Persistent worker loop (thread pool)
; - Threads are created once and then wait on poolRunSemaphore for each run.
; - StartSimulation() signals poolRunSemaphore N times to release all workers.
; - To shut down cleanly, set poolQuitFlag=1 and signal N times.
; =============================================================================
Procedure CoinFlipWorkerLoop(threadIndex.q)
  ; Note: Physical threadIndex is fixed at pool creation time (0..#POOL_MAX_THREADS-1).
  ; For each run, assign a *logical* thread index [0..poolActiveThreadCount-1]
  ; using a ticket. Runs can start with any thread count without caring
  ; which physical threads wake first.
  ;
  ; Accuracy improvement:
  ; - Workers first wake on poolRunSemaphore and "arm" at a start barrier.
  ; - When all active workers are armed, the main thread takes simulationStartMillis
  ;   and releases poolGoSemaphore so hot loops begin after the timestamp.
  Shared poolRunSemaphore.i, poolGoSemaphore.i, poolReadyAllSem.i
  Shared poolQuitFlag.i, poolActiveThreadCount.i
  Shared poolRunTicket.i, poolTicketMutex.i
  Shared poolReadyCount.i, poolReadyMutex.i

  Protected logicalIndex.i
  Protected readyNow.i

  While #True
    WaitSemaphore(poolRunSemaphore)

    If poolQuitFlag
      Break
    EndIf

    ; Assign logical index for this run
    LockMutex(poolTicketMutex)
    logicalIndex = poolRunTicket
    poolRunTicket + 1
    UnlockMutex(poolTicketMutex)

    ; Robustness: normal operation signals exactly poolActiveThreadCount times,
    ; so logicalIndex will always be in range.
    If logicalIndex < 0 Or logicalIndex >= poolActiveThreadCount
      Continue
    EndIf

    ; Arm at the start line (barrier)
    LockMutex(poolReadyMutex)
    poolReadyCount + 1
    readyNow = poolReadyCount
    UnlockMutex(poolReadyMutex)

    If readyNow = poolActiveThreadCount
      SignalSemaphore(poolReadyAllSem) ; last armed worker notifies main thread
    EndIf

    ; Wait for GO signal after timestamp is taken
    WaitSemaphore(poolGoSemaphore)

    If poolQuitFlag
      Break
    EndIf

    CoinFlipSimulation64_RunOnce(logicalIndex)
  Wend
EndProcedure

Global outputFilePath.s

; =============================================================================
; Main program (GUI)
; =============================================================================

Enumeration Gadgets
  #G_MainScroll
  #G_Instances
  #G_Runs
  #G_Flips
  #G_BufferMiB
  #G_LocalBatch
  #G_SamplerMode
  #G_BinomMethod
  #G_BinomK
  #G_ForceKernel
  #G_SaveToFile
  #G_OutputPath
  #G_BrowsePath
  #G_ThreadPolicy
  #G_CustomThreads
  #G_Start
  #G_Stop
  #G_Progress
  #G_Derived
  #G_SepLine
  #G_Prog1
  #G_Prog2
  #G_Prog3
  #G_Prog4
  #G_Log
  #G_AnalyseLog
  #G_LoadLog
  #G_SaveLog
  #G_AppendFiles
  #G_CopyLog
  #G_ClearLog
  #G_Reset
  #G_LiveGraph
  #G_LoadData
  #G_LblPlotThreshold
  #G_PlotThreshold
  #G_PlotInfoLabel
  #G_PlotInfo
  #G_PlotCanvas
; --- Static labels / headers (layout refactor; safe to append) ---
#G_LblSettings
#G_LblInstances
#G_LblRuns
#G_LblFlips
#G_LblBufferMiB
#G_LblLocalBatch
#G_LblSamplerHeader
#G_LblBinomHeader
#G_LblBinomK
#G_LblKernelHeader
#G_LblThreadHeader
#G_LblCustomThreads
#G_LblLogHeader
#G_Count
EndEnumeration

#TIMER_UI      = 1
#TIMER_UI_MS   = 100
#TIMER_PLOT    = 2
#TIMER_PLOT_MS = #PLOT_UPDATE_INTERVAL_MS
#PLOT_STATUS_UPDATE_MS = 300

; ----------------------------------------------------------------------------
; Window callback: detect interactive move/resize (for smooth UI)
; ----------------------------------------------------------------------------
#MSG_WM_ENTERSIZEMOVE = $0231
#MSG_WM_EXITSIZEMOVE  = $0232

#MSG_WM_SETREDRAW     = $000B
#MSG_WM_COPY          = $0301
#MSG_EM_GETSEL        = $00B0
#MSG_EM_SETTARGETDEVICE = $0400 + 72
#MSG_WM_KEYDOWN       = $0100
#VK_RETURN            = $0D

; Context-menu handling for the log (EditorGadget / RichEdit)
#MSG_WM_CONTEXTMENU   = $007B
#MSG_WM_NULL          = $0000
#GWL_WNDPROC          = -4
#GWL_STYLE            = -16
#GWL_EXSTYLE          = -20
#TPM_RIGHTBUTTON      = $0002
#ES_AUTOHSCROLL       = $0080
#WS_HSCROLL           = $00100000
#SW_SHOWNORMAL        = 1

Structure WORKAREA_RECT
  left.l
  top.l
  right.l
  bottom.l
EndStructure

Structure LOGPOINT
  x.l
  y.l
EndStructure

Global gLogOldProc.i
Global gAnalysisOldProc.i
Global gAnalysisWindow.i

; SetWindowPos flags (local definitions for portability)
#SWP_NOSIZE      = $0001
#SWP_NOMOVE      = $0002
#SWP_NOZORDER    = $0004
#SWP_NOACTIVATE  = $0010
#WS_CLIPCHILDREN  = $02000000
#WS_CLIPSIBLINGS  = $04000000
#RDW_INVALIDATE  = $0001
#RDW_NOERASE      = $0020
#RDW_ALLCHILDREN = $0080
#RDW_UPDATENOW   = $0100

Global gInSizeMove.i
Global gNeedPlotRedraw.i
Global gBaseTitle.s
Global gFontUi.i
Global gFontUiSize.i
Global gViewScalePct.i = #VIEW_SCALE_DEFAULT
Global gAppendLogExports.i = 0
Global gAppendAnalysisExports.i = 0
Global gRedrawBatchDepth.i
Global gHandlingConfigComboEvent.i
Global gLastSamplerMode.i = -1
Global gLastBinomialMethod.i = -1
Global Dim gCommitEditOldProc.i(#G_Count - 1)

Procedure.i MainWinCB(hWnd.i, uMsg.i, wParam.i, lParam.i)
  Select uMsg
    Case #MSG_WM_ENTERSIZEMOVE
      gInSizeMove = 1

    Case #MSG_WM_EXITSIZEMOVE
      gInSizeMove = 0
      gNeedPlotRedraw = 1
  EndSelect

  ProcedureReturn #PB_ProcessPureBasicEvents

EndProcedure

; ----------------------------------------------------------------------------
; Log control subclass: show popup menu on right-click even when PB gadget events
; don't report #PB_EventType_RightClick for the EditorGadget / RichEdit.
; ----------------------------------------------------------------------------
Procedure.i LogWndProc(hWnd.i, uMsg.i, wParam.i, lParam.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows

    Select uMsg
      Case #MSG_WM_CONTEXTMENU
        ; lParam = screen coordinates (x,y). If -1, Windows indicates "keyboard context menu".
        Protected x.i = lParam & $FFFF
        Protected y.i = (lParam >> 16) & $FFFF

        If x = $FFFF And y = $FFFF
          Protected pt.LOGPOINT
          GetCursorPos_(@pt)
          x = pt\x
          y = pt\y
        EndIf

        ; Use the WinAPI popup tracking so it always appears at the requested point.
        ; This will generate a normal #PB_Event_Menu in the main event loop.
        SetForegroundWindow_(WindowID(#WinMain))
        TrackPopupMenu_(MenuID(1), #TPM_RIGHTBUTTON, x, y, 0, WindowID(#WinMain), 0)
        PostMessage_(WindowID(#WinMain), #MSG_WM_NULL, 0, 0)

        ProcedureReturn 0
    EndSelect

    If gLogOldProc
      ProcedureReturn CallWindowProc_(gLogOldProc, hWnd, uMsg, wParam, lParam)
    Else
      ProcedureReturn DefWindowProc_(hWnd, uMsg, wParam, lParam)
    EndIf

  CompilerEndIf

  ProcedureReturn 0
EndProcedure

Procedure.i AnalysisWndProc(hWnd.i, uMsg.i, wParam.i, lParam.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows

    Select uMsg
      Case #MSG_WM_CONTEXTMENU
        Protected x.i = lParam & $FFFF
        Protected y.i = (lParam >> 16) & $FFFF

        If x = $FFFF And y = $FFFF
          Protected pt.LOGPOINT
          GetCursorPos_(@pt)
          x = pt\x
          y = pt\y
        EndIf

        If gAnalysisWindow And IsWindow(gAnalysisWindow)
          SetForegroundWindow_(WindowID(gAnalysisWindow))
          TrackPopupMenu_(MenuID(2), #TPM_RIGHTBUTTON, x, y, 0, WindowID(gAnalysisWindow), 0)
          PostMessage_(WindowID(gAnalysisWindow), #MSG_WM_NULL, 0, 0)
        EndIf

        ProcedureReturn 0
    EndSelect

    If gAnalysisOldProc
      ProcedureReturn CallWindowProc_(gAnalysisOldProc, hWnd, uMsg, wParam, lParam)
    Else
      ProcedureReturn DefWindowProc_(hWnd, uMsg, wParam, lParam)
    EndIf

  CompilerEndIf

  ProcedureReturn 0
EndProcedure

Procedure.i CommitEditGadgetFromHwnd(hWnd.i)
  Protected gadget.i

  For gadget = 0 To #G_Count - 1
    If IsGadget(gadget) And GadgetID(gadget) = hWnd
      ProcedureReturn gadget
    EndIf
  Next

  ProcedureReturn -1
EndProcedure

Procedure.i CommitEditWndProc(hWnd.i, uMsg.i, wParam.i, lParam.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected gadget.i = CommitEditGadgetFromHwnd(hWnd)

    If uMsg = #MSG_WM_KEYDOWN And wParam = #VK_RETURN
      If gadget >= 0
        PostEvent(#EventEditCommit, #WinMain, gadget, 0, gadget)
        ProcedureReturn 0
      EndIf
    EndIf

    If gadget >= 0 And gCommitEditOldProc(gadget)
      ProcedureReturn CallWindowProc_(gCommitEditOldProc(gadget), hWnd, uMsg, wParam, lParam)
    EndIf

    ProcedureReturn DefWindowProc_(hWnd, uMsg, wParam, lParam)
  CompilerEndIf

  ProcedureReturn 0
EndProcedure

Procedure SubclassCommitEditGadget(gadget.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If gadget >= 0 And gadget < #G_Count And IsGadget(gadget)
      If gCommitEditOldProc(gadget) = 0
        gCommitEditOldProc(gadget) = SetWindowLongPtr_(GadgetID(gadget), #GWL_WNDPROC, @CommitEditWndProc())
      EndIf
    EndIf
  CompilerEndIf
EndProcedure

Procedure SubclassCommitEditGadgets()
  SubclassCommitEditGadget(#G_Instances)
  SubclassCommitEditGadget(#G_Runs)
  SubclassCommitEditGadget(#G_Flips)
  SubclassCommitEditGadget(#G_BufferMiB)
  SubclassCommitEditGadget(#G_LocalBatch)
  SubclassCommitEditGadget(#G_BinomK)
  SubclassCommitEditGadget(#G_CustomThreads)
  SubclassCommitEditGadget(#G_PlotThreshold)
EndProcedure

Procedure EnableStableChildRedrawHwnd(hWnd.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If hWnd
      ; Clip sibling/child paint instead of using WS_EX_COMPOSITED. The composited
      ; extended style can make frequent canvas/text updates flicker or lag because
      ; Windows repaints the child tree as one large surface.
      Protected style.i = GetWindowLongPtr_(hWnd, #GWL_STYLE)
      Protected newStyle.i = style | #WS_CLIPCHILDREN | #WS_CLIPSIBLINGS
      If newStyle <> style
        SetWindowLongPtr_(hWnd, #GWL_STYLE, newStyle)
      EndIf
    EndIf
  CompilerEndIf
EndProcedure

Procedure BeginUiRedrawBatch()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If gRedrawBatchDepth = 0
      If IsWindow(#WinMain)
        SendMessage_(WindowID(#WinMain), #MSG_WM_SETREDRAW, 0, 0)
      EndIf
      If IsGadget(#G_MainScroll)
        SendMessage_(GadgetID(#G_MainScroll), #MSG_WM_SETREDRAW, 0, 0)
      EndIf
    EndIf
    gRedrawBatchDepth + 1
  CompilerEndIf
EndProcedure

Procedure EndUiRedrawBatch()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If gRedrawBatchDepth > 0
      gRedrawBatchDepth - 1
      If gRedrawBatchDepth = 0
        If IsGadget(#G_MainScroll)
          SendMessage_(GadgetID(#G_MainScroll), #MSG_WM_SETREDRAW, 1, 0)
        EndIf
        If IsWindow(#WinMain)
          SendMessage_(WindowID(#WinMain), #MSG_WM_SETREDRAW, 1, 0)
          RedrawWindow_(WindowID(#WinMain), 0, 0, #RDW_INVALIDATE | #RDW_NOERASE | #RDW_ALLCHILDREN | #RDW_UPDATENOW)
        EndIf
      EndIf
    EndIf
  CompilerEndIf
EndProcedure

Procedure PresentBufferedCanvasImage(canvasGadget.i, image.i)
  If image = 0 : ProcedureReturn : EndIf

  If IsGadget(canvasGadget) And GadgetType(canvasGadget) = #PB_GadgetType_Canvas
    If StartDrawing(CanvasOutput(canvasGadget))
      DrawingMode(#PB_2DDrawing_Default)
      DrawImage(ImageID(image), 0, 0)
      StopDrawing()
    EndIf
  EndIf

  FreeImage(image)
EndProcedure

; ------------------------------------------------------------------------------
; DPI / scaling helpers
; ------------------------------------------------------------------------------
; PureBasic gadget/window coordinates are DPI-aware logical units. Keep layout
; constants in those units and bridge only when calling Win32 APIs, which return
; or expect physical pixels.
; ------------------------------------------------------------------------------
; GetSystemMetrics indices (for portability)
#SM_CXSCREEN = 0
#SM_CYSCREEN = 1
#SM_CXVSCROLL = 2
#SM_CYHSCROLL = 3
#SPI_GETWORKAREA = 48

Procedure InitDpiScale()
  ; Kept for call-site compatibility. PureBasic handles the active monitor DPI.
EndProcedure

Procedure.i PhysToPB_X(px.i)
  ProcedureReturn DesktopUnscaledX(px)
EndProcedure

Procedure.i PhysToPB_Y(py.i)
  ProcedureReturn DesktopUnscaledY(py)
EndProcedure

Procedure.i PBToPhys_X(x.i)
  ProcedureReturn DesktopScaledX(x)
EndProcedure

Procedure.i PBToPhys_Y(y.i)
  ProcedureReturn DesktopScaledY(y)
EndProcedure

Procedure.i GetMainWorkAreaPhys(*work.WORKAREA_RECT)
  If *work = 0 : ProcedureReturn 0 : EndIf

  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If SystemParametersInfo_(#SPI_GETWORKAREA, 0, *work, 0)
      ProcedureReturn 1
    EndIf

    *work\left = 0
    *work\top = 0
    *work\right = GetSystemMetrics_(#SM_CXSCREEN)
    *work\bottom = GetSystemMetrics_(#SM_CYSCREEN)
    If *work\right > 0 And *work\bottom > 0
      ProcedureReturn 1
    EndIf
  CompilerEndIf

  ProcedureReturn 0
EndProcedure

Procedure SetMainWindowFrameSize(frameW_PB.i, frameH_PB.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected hWnd.i = WindowID(#WinMain)
    If hWnd
      ; SetWindowPos() uses physical pixels; the caller passes PureBasic units.
      SetWindowPos_(hWnd, 0, 0, 0, PBToPhys_X(frameW_PB), PBToPhys_Y(frameH_PB), #SWP_NOMOVE | #SWP_NOZORDER | #SWP_NOACTIVATE)
    EndIf
  CompilerEndIf
EndProcedure

Declare.i UiScaleXInt(value.i)
Declare.i UiScaleYInt(value.i)
Declare SetMainWindowStartupFrame(preferredW_PB.i, preferredH_PB.i)

Procedure ApplyMainWindowScaleBounds()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected hWnd.i = WindowID(#WinMain)
    If hWnd = 0 : ProcedureReturn : EndIf

    Protected work.WORKAREA_RECT
    If GetMainWorkAreaPhys(@work) = 0
      WindowBounds(#WinMain, UiScaleXInt(#WIN_MIN_W), UiScaleYInt(#WIN_MIN_H), #PB_Ignore, #PB_Ignore)
      ProcedureReturn
    EndIf

    Protected workW.i = work\right - work\left
    Protected workH.i = work\bottom - work\top
    Protected workFrameW.i = PhysToPB_X(workW)
    Protected workFrameH.i = PhysToPB_Y(workH)
    Protected minFrameW.i = PhysToPB_X(UiScaleXInt(#WIN_MIN_W))
    Protected minFrameH.i = PhysToPB_Y(UiScaleYInt(#WIN_MIN_H))

    If minFrameW < 1 : minFrameW = 1 : EndIf
    If minFrameH < 1 : minFrameH = 1 : EndIf
    If workFrameW > 0 And minFrameW > workFrameW : minFrameW = workFrameW : EndIf
    If workFrameH > 0 And minFrameH > workFrameH : minFrameH = workFrameH : EndIf

    ; Leave the maximum unconstrained. Windows should decide the maximized size
    ; from the current monitor/work-area and DPI setting.
    WindowBounds(#WinMain, minFrameW, minFrameH, #PB_Ignore, #PB_Ignore)
  CompilerElse
    WindowBounds(#WinMain, UiScaleXInt(#WIN_MIN_W), UiScaleYInt(#WIN_MIN_H), #PB_Ignore, #PB_Ignore)
  CompilerEndIf
EndProcedure

Procedure SetMainWindowStartupFrame(preferredW_PB.i, preferredH_PB.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected hWnd.i = WindowID(#WinMain)
    If hWnd = 0 : ProcedureReturn : EndIf

    Protected work.WORKAREA_RECT
    Protected marginX.i = #WIN_SCREEN_MARGIN
    Protected marginY.i = #WIN_SCREEN_MARGIN
    Protected workW.i, workH.i, targetW.i, targetH.i, targetX.i, targetY.i
    Protected minW.i = UiScaleXInt(#WIN_MIN_W)
    Protected minH.i = UiScaleYInt(#WIN_MIN_H)

    If marginX < 8 : marginX = 8 : EndIf
    If marginY < 8 : marginY = 8 : EndIf

    If SystemParametersInfo_(#SPI_GETWORKAREA, 0, @work, 0)
      workW = work\right - work\left
      workH = work\bottom - work\top
    Else
      work\left = 0
      work\top = 0
      workW = GetSystemMetrics_(#SM_CXSCREEN)
      workH = GetSystemMetrics_(#SM_CYSCREEN)
    EndIf

    ; Win32 window positioning uses physical pixels. Keep all work-area math in
    ; physical pixels, then PureBasic gadget layout converts back to PB units.
    targetW = PBToPhys_X(preferredW_PB)
    targetH = PBToPhys_Y(preferredH_PB)

    If targetW > workW - (marginX * 2) : targetW = workW - (marginX * 2) : EndIf
    If targetH > workH - (marginY * 2) : targetH = workH - (marginY * 2) : EndIf

    If targetW < minW : targetW = minW : EndIf
    If targetH < minH : targetH = minH : EndIf
    If targetW > workW : targetW = workW : EndIf
    If targetH > workH : targetH = workH : EndIf

    targetX = work\left + (workW - targetW) / 2
    targetY = work\top + (workH - targetH) / 2
    If targetX < work\left : targetX = work\left : EndIf
    If targetY < work\top : targetY = work\top : EndIf

    SetWindowPos_(hWnd, 0, targetX, targetY, targetW, targetH, #SWP_NOZORDER | #SWP_NOACTIVATE)
  CompilerElse
    SetMainWindowFrameSize(preferredW_PB, preferredH_PB)
  CompilerEndIf
EndProcedure

Procedure UpdateMainWindowTitle()
  If IsWindow(#WinMain) = 0 : ProcedureReturn : EndIf

  SetWindowTitle(#WinMain, gBaseTitle)
EndProcedure

Procedure.i ClampUiFontSize(fontSize.i)
  If fontSize < 5 : fontSize = 5 : EndIf
  If fontSize > 20 : fontSize = 20 : EndIf
  ProcedureReturn fontSize
EndProcedure

Procedure.i NormalizeViewScale(percent.i)
  Select percent
    Case 50, 75, 100, 125, 150
      ProcedureReturn percent
  EndSelect
  ProcedureReturn #VIEW_SCALE_DEFAULT
EndProcedure

Procedure.s ViewPreferencesPath()
  Protected dir.s

  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    dir = GetEnvironmentVariable("APPDATA")
    If dir <> ""
      dir + "\Coinflip"
      CreateDirectory(dir)
      ProcedureReturn dir + "\Coinflip.ini"
    EndIf
  CompilerEndIf

  ProcedureReturn GetHomeDirectory() + "Coinflip.ini"
EndProcedure

Procedure LoadViewPreference()
  Protected path.s = ViewPreferencesPath()
  If path <> "" And OpenPreferences(path)
    PreferenceGroup("View")
    gViewScalePct = NormalizeViewScale(ReadPreferenceInteger("ScalePercent", #VIEW_SCALE_DEFAULT))
    PreferenceGroup("Files")
    gAppendLogExports = Bool(ReadPreferenceInteger("AppendLogExports", ReadPreferenceInteger("AppendTextExports", 0)))
    gAppendAnalysisExports = Bool(ReadPreferenceInteger("AppendAnalysisExports", ReadPreferenceInteger("AppendTextExports", 0)))
    ClosePreferences()
  Else
    gViewScalePct = #VIEW_SCALE_DEFAULT
    gAppendLogExports = 0
    gAppendAnalysisExports = 0
  EndIf
EndProcedure

Procedure SaveViewPreference()
  Protected path.s = ViewPreferencesPath()
  If path <> "" And CreatePreferences(path)
    PreferenceGroup("View")
    WritePreferenceInteger("ScalePercent", gViewScalePct)
    PreferenceGroup("Files")
    WritePreferenceInteger("AppendLogExports", Bool(gAppendLogExports))
    WritePreferenceInteger("AppendAnalysisExports", Bool(gAppendAnalysisExports))
    ClosePreferences()
  EndIf
EndProcedure

Procedure.i UiScaleInt(value.i)
  Protected scaled.i = Int(((value * #UI_DPI_BOOST_NUM * gViewScalePct) / (#UI_DPI_BOOST_DEN * 100)) + 0.5)
  If value > 0 And scaled < 1 : scaled = 1 : EndIf
  ProcedureReturn scaled
EndProcedure

Procedure.i UiScaleXInt(value.i)
  ProcedureReturn UiScaleInt(value)
EndProcedure

Procedure.i UiScaleYInt(value.i)
  ProcedureReturn UiScaleInt(value)
EndProcedure

Procedure EnsureUiFontsForScale()
  Protected gadget.i
  Protected newFont.i
  Protected oldFont.i
  Protected fontSize.i = ClampUiFontSize(Int(((#UI_FONT_SIZE * gViewScalePct) / 100.0) + 0.5))

  If gFontUi = 0 Or gFontUiSize <> fontSize
    newFont = LoadFont(#PB_Any, "Segoe UI", fontSize)
    If newFont
      oldFont = gFontUi
      gFontUi = newFont
      gFontUiSize = fontSize
    EndIf
  EndIf

  If gFontUi
    SetGadgetFont(#PB_Default, FontID(gFontUi))
    For gadget = #G_MainScroll To #G_LblLogHeader
      If IsGadget(gadget)
        SetGadgetFont(gadget, FontID(gFontUi))
      EndIf
    Next
  EndIf

  If oldFont
    FreeFont(oldFont)
  EndIf
EndProcedure

Procedure.i GetScaledMinimumContentWidth()
  ProcedureReturn (UiScaleXInt(#MARGIN) * 2) + UiScaleXInt(#COL1_W) + UiScaleXInt(#COL2_W) + UiScaleXInt(#RIGHT_MIN_W) + (UiScaleXInt(#GAP_X) * 2)
EndProcedure

Procedure.i GetScaledMinimumTopHeight()
  Protected titleH.i = UiScaleYInt(#TITLE_H)
  Protected rowH.i = UiScaleYInt(#ROW_H)
  Protected btnH.i = UiScaleYInt(#BTN_H)
  Protected smallBtnH.i = UiScaleYInt(#SMALLBTN_H)
  Protected gapY.i = UiScaleYInt(#GAP_Y)
  Protected progH.i = UiScaleYInt(#PROG_H)
  Protected progLineGap.i = UiScaleYInt(#PROG_LINE_GAP)
  Protected logMinH.i = UiScaleYInt(#LOG_MIN_H)
  Protected minCol1H.i
  Protected minCol2H.i
  Protected minCol3H.i
  Protected minTopH.i

  minCol1H = (titleH + gapY)
  minCol1H + (5 * (rowH + gapY))
  minCol1H + (titleH + gapY) + (rowH + gapY)
  minCol1H + (titleH + gapY) + (rowH + gapY)
  minCol1H + (rowH + gapY)

  minCol2H = (titleH + gapY) + (rowH + gapY)
  minCol2H + (rowH + gapY)
  minCol2H + (rowH + gapY)
  minCol2H + (titleH + gapY) + (rowH + gapY)
  minCol2H + (rowH + gapY)
  minCol2H + ((rowH * #DERIVED_ROWS) + gapY)

  minCol3H = (btnH + progLineGap + progH + gapY)
  minCol3H + (smallBtnH + gapY)
  minCol3H + logMinH

  minTopH = minCol1H
  If minCol2H > minTopH : minTopH = minCol2H : EndIf
  If minCol3H > minTopH : minTopH = minCol3H : EndIf
  ProcedureReturn minTopH
EndProcedure

Procedure.i GetScaledMinimumContentHeight()
  Protected margin.i = UiScaleYInt(#MARGIN)
  Protected gapY.i = UiScaleYInt(#GAP_Y)
  Protected plotBarH.i = UiScaleYInt(#PLOTINFO_LABEL_H) + UiScaleYInt(2) + UiScaleYInt(#ROW_H)
  Protected minContentH.i = (margin * 2) + GetScaledMinimumTopHeight() + gapY + plotBarH + gapY + UiScaleYInt(#PLOT_MIN_HEIGHT)
  If minContentH < 1 : minContentH = 1 : EndIf
  ProcedureReturn minContentH
EndProcedure

; ----------------------------------------------------------------------------
; Progress bar (custom-drawn Canvas)
; ----------------------------------------------------------------------------
; Custom canvas drawing keeps the percent label:
;   - white text
;   - black outline
;   - centered (stable)
; Avoids theme-dependent repaint issues with native ProgressBar controls.
; ----------------------------------------------------------------------------
Global uiLastProgressPercent.i
Global uiLastProgressDrawnPercent.i = -1
Global uiLastProgressDrawnW.i = -1
Global uiLastProgressDrawnH.i = -1
Global uiLastPlotInfoDrawnText.s
Global uiLastPlotInfoDrawnW.i = -1
Global uiLastPlotInfoDrawnH.i = -1

Structure BufferedTextCanvasState
  text.s
  w.i
  h.i
EndStructure

Global uiDerivedCanvas.BufferedTextCanvasState
Global uiSepCanvas.BufferedTextCanvasState
uiDerivedCanvas\w = -1
uiDerivedCanvas\h = -1
uiSepCanvas\w = -1
uiSepCanvas\h = -1
Global logLinesSinceTrimCheck.i

Procedure DrawProgressCanvas(percent.i, forceRedraw.i = #False)
  If percent < 0 : percent = 0 : EndIf
  If percent > 100 : percent = 100 : EndIf
  uiLastProgressPercent = percent

  If IsGadget(#G_Progress) = 0 : ProcedureReturn : EndIf
  If GadgetType(#G_Progress) <> #PB_GadgetType_Canvas : ProcedureReturn : EndIf

  If forceRedraw = #False And percent = uiLastProgressDrawnPercent And uiLastProgressDrawnW > 0 And uiLastProgressDrawnH > 0
    ProcedureReturn
  EndIf

  Protected w.i
  Protected h.i
  If StartDrawing(CanvasOutput(#G_Progress))
    w = OutputWidth()
    h = OutputHeight()
    StopDrawing()
  EndIf
  If w < 1 : w = 1 : EndIf
  If h < 1 : h = 1 : EndIf

  If forceRedraw = #False
    If percent = uiLastProgressDrawnPercent And w = uiLastProgressDrawnW And h = uiLastProgressDrawnH
      ProcedureReturn
    EndIf
  EndIf

  Protected bufferImage.i = CreateImage(#PB_Any, w, h, 32)
  If bufferImage = 0 : ProcedureReturn : EndIf

  If StartDrawing(ImageOutput(bufferImage))
    If gFontUi : DrawingFont(FontID(gFontUi)) : EndIf

    ; Colors: use system highlight for the fill (matches Windows accent/theme).
    Protected bgCol.l = RGB(230, 230, 230)
    Protected borderCol.l = RGB(120, 120, 120)
    Protected fillCol.l = GetSysColor_(13) ; COLOR_HIGHLIGHT

    Box(0, 0, w, h, bgCol)

    Protected innerW.i = w - 2
    Protected innerH.i = h - 2
    If innerW < 1 : innerW = 1 : EndIf
    If innerH < 1 : innerH = 1 : EndIf

    Protected fillW.i = (innerW * percent) / 100
    If fillW > 0
      Box(1, 1, fillW, innerH, fillCol)
    EndIf

    ; Border
    Line(0, 0, w, 1, borderCol)
    Line(0, h - 1, w, 1, borderCol)
    Line(0, 0, 1, h, borderCol)
    Line(w - 1, 0, 1, h, borderCol)

    ; Text (shadow + white)
    DrawingMode(#PB_2DDrawing_Transparent)

    Protected s.s = RSet(Str(percent), 3, " ") + "%"
    Protected tx.i = (w - TextWidth(s)) / 2
    Protected ty.i = (h - TextHeight(s)) / 2
    If tx < 0 : tx = 0 : EndIf
    If ty < 0 : ty = 0 : EndIf

    ; Strong black outline on all sides, matching the high-contrast progress
    ; label style used in the rest of the Windows-scaled UI.
    Protected dx.i, dy.i, r.i
    For r = 1 To 2
      For dy = -r To r
        For dx = -r To r
          If dx = 0 And dy = 0
            Continue
          EndIf
          ; Only draw the outer ring for this radius (keeps it crisp)
          If Abs(dx) = r Or Abs(dy) = r
            DrawText(tx + dx, ty + dy, s, RGB(0, 0, 0))
          EndIf
        Next
      Next
    Next
    ; Foreground text
    DrawText(tx, ty, s, RGB(255, 255, 255))

    StopDrawing()
    PresentBufferedCanvasImage(#G_Progress, bufferImage)
    uiLastProgressDrawnPercent = percent
    uiLastProgressDrawnW = w
    uiLastProgressDrawnH = h
  Else
    FreeImage(bufferImage)
  EndIf
EndProcedure

Procedure DrawPlotStatusCanvas(text.s, forceRedraw.i = #False)
  If IsGadget(#G_PlotInfo) = 0 : ProcedureReturn : EndIf

  If GadgetType(#G_PlotInfo) <> #PB_GadgetType_Canvas
    SetGadgetText(#G_PlotInfo, text)
    ProcedureReturn
  EndIf

  Protected w.i
  Protected h.i
  If StartDrawing(CanvasOutput(#G_PlotInfo))
    w = OutputWidth()
    h = OutputHeight()
    StopDrawing()
  EndIf
  If w < 1 : w = 1 : EndIf
  If h < 1 : h = 1 : EndIf

  If forceRedraw = #False And text = uiLastPlotInfoDrawnText And w = uiLastPlotInfoDrawnW And h = uiLastPlotInfoDrawnH
    ProcedureReturn
  EndIf

  Protected bufferImage.i = CreateImage(#PB_Any, w, h, 32)
  If bufferImage = 0 : ProcedureReturn : EndIf

  If StartDrawing(ImageOutput(bufferImage))
    If gFontUi : DrawingFont(FontID(gFontUi)) : EndIf

    Protected bgCol.l = RGB(255, 255, 192)
    Protected borderCol.l = RGB(120, 120, 120)
    Protected padX.i = UiScaleXInt(6)
    Protected ty.i

    Box(0, 0, w, h, bgCol)
    Line(0, 0, w, 1, borderCol)
    Line(0, h - 1, w, 1, borderCol)
    Line(0, 0, 1, h, borderCol)
    Line(w - 1, 0, 1, h, borderCol)

    DrawingMode(#PB_2DDrawing_Transparent)
    ty = (h - TextHeight(text)) / 2
    If ty < 0 : ty = 0 : EndIf
    DrawText(padX, ty, text, RGB(0, 0, 0))

    StopDrawing()
    PresentBufferedCanvasImage(#G_PlotInfo, bufferImage)
    uiLastPlotInfoDrawnText = text
    uiLastPlotInfoDrawnW = w
    uiLastPlotInfoDrawnH = h
  Else
    FreeImage(bufferImage)
  EndIf
EndProcedure

Procedure DrawBufferedTextCanvas(gadget.i, text.s, *state.BufferedTextCanvasState, forceRedraw.i = #False)
  If IsGadget(gadget) = 0 : ProcedureReturn : EndIf
  If *state = 0 : ProcedureReturn : EndIf

  If GadgetType(gadget) <> #PB_GadgetType_Canvas
    If forceRedraw Or GetGadgetText(gadget) <> text
      SetGadgetText(gadget, text)
    EndIf
    ProcedureReturn
  EndIf

  Protected w.i
  Protected h.i
  If StartDrawing(CanvasOutput(gadget))
    w = OutputWidth()
    h = OutputHeight()
    StopDrawing()
  EndIf
  If w < 1 : w = 1 : EndIf
  If h < 1 : h = 1 : EndIf

  If forceRedraw = #False And text = *state\text And w = *state\w And h = *state\h
    ProcedureReturn
  EndIf

  Protected bufferImage.i = CreateImage(#PB_Any, w, h, 32)
  If bufferImage = 0 : ProcedureReturn : EndIf

  If StartDrawing(ImageOutput(bufferImage))
    If gFontUi : DrawingFont(FontID(gFontUi)) : EndIf

    Protected bgCol.l = GetSysColor_(15) ; COLOR_BTNFACE
    Protected fgCol.l = RGB(0, 0, 0)
    Protected padX.i = UiScaleXInt(2)
    Protected lineY.i = 0
    Protected lineH.i = TextHeight("Ag")
    Protected i.i
    Protected line.s
    Protected lines.i = CountString(text, #LF$) + 1

    If lineH < 1 : lineH = 1 : EndIf
    Box(0, 0, w, h, bgCol)
    DrawingMode(#PB_2DDrawing_Transparent)

    For i = 1 To lines
      line = StringField(text, i, #LF$)
      If lineY + lineH > h
        Break
      EndIf
      DrawText(padX, lineY, line, fgCol)
      lineY + lineH
    Next

    StopDrawing()
    PresentBufferedCanvasImage(gadget, bufferImage)
    *state\text = text
    *state\w = w
    *state\h = h
  Else
    FreeImage(bufferImage)
  EndIf
EndProcedure

Procedure DrawDerivedCanvas(text.s, forceRedraw.i = #False)
  DrawBufferedTextCanvas(#G_Derived, text, @uiDerivedCanvas, forceRedraw)
EndProcedure

Procedure DrawSepCanvas(text.s, forceRedraw.i = #False)
  DrawBufferedTextCanvas(#G_SepLine, text, @uiSepCanvas, forceRedraw)
EndProcedure
Declare StopSimulation()
Declare ApplyPlotUIRules()
Declare LoadDeviationDataFile(filePath.s)

Procedure LogLine(msg.s)
  Protected t.s = FormatDate("%hh:%ii:%ss", Date()) + "  " + msg
  Protected h.i = GadgetID(#G_Log)
  Protected s.s = t + #CRLF$

  ; Append efficiently to the read-only EditorGadget. Suppress redraw while the
  ; RichEdit moves the caret, appends text, trims old text, and scrolls.
  SendMessage_(h, #MSG_WM_SETREDRAW, 0, 0)
  SendMessage_(h, #EM_SETSEL, -1, -1)
  SendMessage_(h, #EM_REPLACESEL, 0, @s)

  ; Keep log memory bounded for long runs.
  logLinesSinceTrimCheck + 1
  If logLinesSinceTrimCheck >= 25
    logLinesSinceTrimCheck = 0

    If GetWindowTextLength_(h) > #LOG_MAX_CHARS
      Protected logText.s = GetGadgetText(#G_Log)
      If Len(logText) > #LOG_TRIM_TARGET_CHARS
        logText = Right(logText, #LOG_TRIM_TARGET_CHARS)
        Protected cutPos.i = FindString(logText, #LF$, 1)
        If cutPos > 0
          logText = Mid(logText, cutPos + 1)
        EndIf
        SetGadgetText(#G_Log, logText)
        SendMessage_(h, #EM_SETSEL, -1, -1)
      EndIf
    EndIf
  EndIf

  SendMessage_(h, #EM_SCROLLCARET, 0, 0)
  SendMessage_(h, #MSG_WM_SETREDRAW, 1, 0)
  RedrawWindow_(h, 0, 0, #RDW_INVALIDATE | #RDW_NOERASE | #RDW_UPDATENOW)
EndProcedure

Procedure.s ShortLogText(text.s, maxLen.i)
  text = ReplaceString(text, #CR$, "")
  text = ReplaceString(text, #LF$, "")
  text = ReplaceString(Trim(text), #TAB$, " ")
  While FindString(text, "  ", 1)
    text = ReplaceString(text, "  ", " ")
  Wend

  If maxLen > 3 And Len(text) > maxLen
    ProcedureReturn Left(text, maxLen - 3) + "..."
  EndIf

  ProcedureReturn text
EndProcedure

Procedure.s CleanLogValue(text.s)
  text = ReplaceString(text, #CR$, "")
  text = ReplaceString(text, #LF$, "")
  text = ReplaceString(text, #TAB$, " ")
  ProcedureReturn Trim(text)
EndProcedure

Procedure.i StartsWithNumber(text.s)
  Protected first.s = Left(CleanLogValue(text), 1)
  ProcedureReturn Bool((first >= "0" And first <= "9") Or first = "-" Or first = "+" Or first = ".")
EndProcedure

Procedure.s FormatCfMs(speed.d)
  If speed < 0.0
    ProcedureReturn "n/a"
  EndIf

  ProcedureReturn FormatNumber(speed, 0, ".", ",") + " cf/ms"
EndProcedure

Procedure.d ParseSpeedCfMsFromLine(line.s)
  line = CleanLogValue(line)
  Protected start.i = FindString(line, "Speed:", 1)
  Protected stop.i
  Protected valueText.s

  If start = 0 : ProcedureReturn -1.0 : EndIf
  start + Len("Speed:")
  stop = FindString(line, "cf/ms", start)
  If stop = 0 : ProcedureReturn -1.0 : EndIf

  valueText = Mid(line, start, stop - start)
  valueText = ReplaceString(valueText, ",", "")
  valueText = ReplaceString(valueText, " ", "")
  ProcedureReturn ValD(valueText)
EndProcedure

Procedure.d ParseResultSigmaFromText(text.s)
  text = CleanLogValue(text)
  Protected partCount.i
  Protected i.i
  Protected valueText.s

  partCount = CountString(text, "|") + 1
  For i = partCount To 1 Step -1
    valueText = CleanLogValue(StringField(text, i, "|"))
    If Right(valueText, 1) = "s" And StartsWithNumber(valueText)
      valueText = Left(valueText, Len(valueText) - 1)
      valueText = CleanLogValue(valueText)
      If valueText <> ""
        ProcedureReturn ValD(valueText)
      EndIf
    EndIf
  Next

  ProcedureReturn -1.0
EndProcedure

Procedure.d ParseExpectedSigmaMeanFromStats(line.s)
  line = CleanLogValue(line)
  Protected start.i = FindString(line, "expected max ", 1)
  Protected stop.i
  Protected valueText.s

  If start = 0 : ProcedureReturn -1.0 : EndIf
  start + Len("expected max ")
  stop = FindString(line, "s", start)
  If stop = 0 : ProcedureReturn -1.0 : EndIf
  valueText = CleanLogValue(Mid(line, start, stop - start))
  ProcedureReturn ValD(valueText)
EndProcedure

Procedure.d ParseExpectedSigmaRangeValue(line.s, wantHigh.i)
  line = CleanLogValue(line)
  Protected openPos.i = FindString(line, "(", 1)
  Protected dotsPos.i
  Protected closePos.i
  Protected valueText.s

  If openPos = 0 : ProcedureReturn -1.0 : EndIf
  dotsPos = FindString(line, "..", openPos)
  closePos = FindString(line, "s)", openPos)
  If dotsPos = 0 Or closePos = 0 : ProcedureReturn -1.0 : EndIf

  If wantHigh
    valueText = Mid(line, dotsPos + 2, closePos - (dotsPos + 2))
  Else
    valueText = Mid(line, openPos + 1, dotsPos - (openPos + 1))
  EndIf

  ProcedureReturn ValD(Trim(valueText))
EndProcedure

Procedure.s ExtractLogPayload(line.s)
  line = CleanLogValue(line)
  ; Log lines start with HH:MM:SS. Strip that prefix when present.
  If Len(line) >= 10 And Mid(line, 3, 1) = ":" And Mid(line, 6, 1) = ":"
    ProcedureReturn CleanLogValue(Mid(line, 10))
  EndIf

  ProcedureReturn CleanLogValue(line)
EndProcedure

Procedure.i LogPayloadHasLabel(payload.s, label.s)
  payload = CleanLogValue(payload)
  ProcedureReturn Bool(Left(UCase(payload), Len(UCase(label))) = UCase(label))
EndProcedure

Procedure.s LogPayloadValue(payload.s, label.s)
  payload = CleanLogValue(payload)
  If LogPayloadHasLabel(payload, label)
    ProcedureReturn CleanLogValue(Mid(payload, Len(label) + 1))
  EndIf

  ProcedureReturn ""
EndProcedure

Declare.s TrimDecimalZeros(text.s)

Procedure.s NormalizeAnalysisMode(mode.s)
  Protected text.s = CleanLogValue(mode)

  If Left(text, Len("BIT-EXACT | ")) = "BIT-EXACT | "
    text = Mid(text, Len("BIT-EXACT | ") + 1)
  ElseIf Left(text, Len("BINOMIAL | ")) = "BINOMIAL | "
    text = Mid(text, Len("BINOMIAL | ") + 1)
  EndIf

  ProcedureReturn text
EndProcedure

Procedure.s CompactAnalysisMode(mode.s, maxLen.i = 28)
  Protected text.s = NormalizeAnalysisMode(mode)

  text = ReplaceString(text, " popcount", "")
  text = ReplaceString(text, " (recommended)", "")
  text = ReplaceString(text, " (alternative)", "")
  text = ReplaceString(text, "exact", "ex")
  text = ReplaceString(text, "forced ", "")
  text = ReplaceString(text, "unavailable -> auto", "auto fallback")

  If maxLen > 3 And Len(text) > maxLen
    text = Left(text, maxLen - 3) + "..."
  EndIf

  ProcedureReturn text
EndProcedure

Procedure.s PadRight(text.s, width.i)
  If Len(text) >= width
    ProcedureReturn Left(text, width)
  EndIf

  ProcedureReturn text + Space(width - Len(text))
EndProcedure

Procedure.s PadLeft(text.s, width.i)
  If Len(text) >= width
    ProcedureReturn Right(text, width)
  EndIf

  ProcedureReturn Space(width - Len(text)) + text
EndProcedure

Procedure.s FormatCompactCfMs(speed.d)
  If speed < 0.0
    ProcedureReturn "n/a"
  EndIf

  If speed >= 1000000000.0
    ProcedureReturn TrimDecimalZeros(FormatNumber(speed / 1000000000.0, 2, ".", ",")) + "B"
  EndIf
  If speed >= 1000000.0
    ProcedureReturn TrimDecimalZeros(FormatNumber(speed / 1000000.0, 1, ".", ",")) + "M"
  EndIf

  ProcedureReturn FormatNumber(speed, 0, ".", ",")
EndProcedure

Procedure.s AnalysisGraphLabel(graphState.s)
  If graphState = "on"
    ProcedureReturn "selected"
  EndIf
  If graphState = "off"
    ProcedureReturn "not selected"
  EndIf

  ProcedureReturn "not logged"
EndProcedure

Procedure InitPowerNameTable()
  If powerNameTableReady
    ProcedureReturn
  EndIf

  Protected i.i, p.i
  Protected zeros.i
  Protected name.s
  Protected scale.d

  Restore PowerOfTenNameTable
  For i = 0 To #POWER_NAME_COUNT - 1
    Read.i zeros
    Read.s name

    scale = 1.0
    For p = 1 To zeros
      scale * 10.0
    Next

    powerNameTable(i)\zeros = zeros
    powerNameTable(i)\name = name
    powerNameTable(i)\scale = scale
  Next

  powerNameTableReady = 1
EndProcedure

Procedure.s TrimDecimalZeros(text.s)
  If FindString(text, ".", 1)
    While Len(text) > 0 And Right(text, 1) = "0"
      text = Left(text, Len(text) - 1)
    Wend
    If Len(text) > 0 And Right(text, 1) = "."
      text = Left(text, Len(text) - 1)
    EndIf
  EndIf

  ProcedureReturn text
EndProcedure

Procedure.s FormatNamedNumber(value.d)
  InitPowerNameTable()

  Protected sign.s = ""
  Protected absValue.d = value
  If absValue < 0.0
    sign = "-"
    absValue = -absValue
  EndIf

  If absValue < 1000.0
    ProcedureReturn "about " + sign + FormatNumber(absValue, 0, ".", ",")
  EndIf

  Protected i.i
  Protected best.i = -1
  For i = 0 To #POWER_NAME_COUNT - 1
    If absValue >= powerNameTable(i)\scale
      best = i
    EndIf
  Next

  If best < 0
    ProcedureReturn "about " + sign + FormatNumber(absValue, 0, ".", ",")
  EndIf

  Protected scaled.d = absValue / powerNameTable(best)\scale
  Protected decimals.i
  If scaled >= 100.0
    decimals = 0
  ElseIf scaled >= 10.0
    decimals = 1
  Else
    decimals = 2
  EndIf

  ProcedureReturn "about " + sign + TrimDecimalZeros(FormatNumber(scaled, decimals, ".", ",")) + " " + powerNameTable(best)\name
EndProcedure

Procedure.s FormatNamedCoinFlipRate(speedCfPerMs.d)
  ProcedureReturn FormatNamedNumber(speedCfPerMs) + " coin flips per millisecond"
EndProcedure

Procedure.s FormatNamedCoinFlips(totalCf.d)
  ProcedureReturn FormatNamedNumber(totalCf) + " coin flips"
EndProcedure

Procedure MaybeLogPeriodicThroughput(nowMs.q, progress.i, etaSeconds.d, throughputFlipsPerMs.d, liveThroughputFlipsPerMs.d)
  Protected pct.i = progress
  Protected msg.s

  If simulationIsRunning = 0 Or simulationStartMillis <= 0
    ProcedureReturn
  EndIf

  If nextThroughputLogMillis <= 0
    nextThroughputLogMillis = simulationStartMillis + #LOG_THROUGHPUT_INTERVAL_MS
  EndIf

  If nowMs < nextThroughputLogMillis
    ProcedureReturn
  EndIf

  If pct < 0 : pct = 0 : EndIf
  If pct > 100 : pct = 100 : EndIf

  msg = "Run " + Str(pct) + "% | time " + FormatDuration((nowMs - simulationStartMillis) / 1000.0)

  If etaSeconds >= 0.0
    msg + " | eta " + FormatDuration(etaSeconds)
  EndIf

  If throughputFlipsPerMs >= 0.0
    msg + " | avg " + FormatCfMs(throughputFlipsPerMs)
  EndIf

  If liveThroughputFlipsPerMs >= 0.0
    msg + " | live " + FormatCfMs(liveThroughputFlipsPerMs)
  EndIf

  LogLine(msg)

  Repeat
    nextThroughputLogMillis + #LOG_THROUGHPUT_INTERVAL_MS
  Until nextThroughputLogMillis > nowMs
EndProcedure

; Robust integer parsing for user-entered text.
; - Accepts thousands separators: space, comma, underscore, apostrophe, dot.
; - Ignores other non-digit characters, so minor typos are tolerated.
; - Returns defaultValue when no digits are found.
; - Caps digit count to avoid 64-bit overflow.
Procedure.q ParseIntQFromString(text.s, defaultValue.q)
  Protected s.s = Trim(text)
  If s = "" : ProcedureReturn defaultValue : EndIf

  ; Optional sign handling (rarely used in this program, but harmless).
  Protected sign.q = 1
  If Left(s, 1) = "-"
    sign = -1
    s = Mid(s, 2)
  ElseIf Left(s, 1) = "+"
    s = Mid(s, 2)
  EndIf

  ; Collect digits from the entire string, skipping common separators.
  ; This lets users type "350,757" or "350 757" etc., and also tolerates small typos.
  Protected digits.s = ""
  Protected i.i, c.i
  For i = 1 To Len(s)
    c = Asc(Mid(s, i, 1))
    If c >= 48 And c <= 57
      digits + Chr(c)
    EndIf
  Next

  If digits = ""
    ProcedureReturn defaultValue
  EndIf

  ; Prevent overflow on Val() for absurd input lengths.
  If Len(digits) > 18
    digits = Left(digits, 18)
  EndIf

  ProcedureReturn Val(digits) * sign
EndProcedure

; Parse integer from a gadget text field.
Procedure.q ParseIntQFromGadget(gadget.i, defaultValue.q)
  ProcedureReturn ParseIntQFromString(GetGadgetText(gadget), defaultValue)
EndProcedure

; Cache CPU count once for consistent thread policy behavior and lower UI overhead.
Procedure.i GetCpuCountCached()
  Static cachedCount.i

  If cachedCount < 1
    cachedCount = CountCPUs()
    If cachedCount < 1
      cachedCount = 1
    EndIf
  EndIf

  ProcedureReturn cachedCount
EndProcedure

Procedure.q ClampQ(value.q, minValue.q, maxValue.q)
  If value < minValue : ProcedureReturn minValue : EndIf
  If value > maxValue : ProcedureReturn maxValue : EndIf
  ProcedureReturn value
EndProcedure

Procedure.q ResolveThreadCount(policy.i, customThreads.q)
  Protected cpuCount.q = GetCpuCountCached()
  Protected threads.q

  Select policy
    Case 1
      threads = cpuCount
    Case 2
      threads = customThreads
    Default
      threads = cpuCount * cpuCount
  EndSelect

  ProcedureReturn ClampQ(threads, 1, #POOL_MAX_THREADS)
EndProcedure

Procedure.i IsCommitEditEvent(eventType.i, eventData.i)
  If eventType = #PB_EventType_LostFocus
    ProcedureReturn #True
  EndIf

  ; Enter key fallback for StringGadget edits (compiler-version safe).
  If eventType = #PB_EventType_KeyDown And eventData = #PB_Shortcut_Return
    ProcedureReturn #True
  EndIf

  ProcedureReturn #False
EndProcedure

Procedure UpdateDerivedInfo()
  Protected threads.q, flips.q, inst.q, runs.q, totalSamples.q, totalFlips.q, bytes.q
  Protected cpuCount.q = GetCpuCountCached()

  inst  = ParseIntQFromGadget(#G_Instances, #INSTANCES_TO_SIMULATE)
  runs  = ParseIntQFromGadget(#G_Runs, #SIMULATION_RUNS)
  flips = ParseIntQFromGadget(#G_Flips, #FLIPS_NEEDED)

  threads = ResolveThreadCount(GetGadgetState(#G_ThreadPolicy), ParseIntQFromGadget(#G_CustomThreads, cpuCount * cpuCount))

  totalSamples = threads * inst * runs
  totalFlips = totalSamples * flips
  bytes = totalSamples * 2

  DrawDerivedCanvas(Str(threads) + " threads   " + FormatNumber(totalSamples, 0, ".", ",") + " samples" + #LF$ +
                    "Total: " + FormatNumber(totalFlips, 0, ".", ",") + " cf" + #LF$ +
                    FormatNamedCoinFlips(totalFlips) + "   File: " + FormatNumber(bytes / (1024.0*1024.0), 2, ".", ",") + " MiB" + #LF$ +
                    "Each sample: " + FormatNumber(flips, 0, ".", ",") + " flips" + #LF$ +
                    "Formula: threads x blocks x instances x flips")
  DrawSepCanvas("")
EndProcedure

Procedure DisableSettings(disable.i)
  Protected state.i = Bool(disable)
  DisableGadget(#G_Instances, state)
  DisableGadget(#G_Runs, state)
  DisableGadget(#G_Flips, state)
  DisableGadget(#G_BufferMiB, state)
  DisableGadget(#G_LocalBatch, state)
  DisableGadget(#G_SamplerMode, state)
  DisableGadget(#G_BinomMethod, state)
  DisableGadget(#G_BinomK, state)
  DisableGadget(#G_ForceKernel, state)
  DisableGadget(#G_SaveToFile, state)
  DisableGadget(#G_OutputPath, state)
  DisableGadget(#G_BrowsePath, state)
  DisableGadget(#G_ThreadPolicy, state)
  DisableGadget(#G_CustomThreads, state)
EndProcedure

Procedure ApplySamplerUIRules()
  ; UI "ghosting" rules:
  ; - When BINOMIAL is selected, BIT-EXACT kernel controls are disabled (greyed out).
  ; - When BIT-EXACT is selected, BINOMIAL-only controls are disabled (greyed out).
  ;
  ; This prevents the user from selecting options that have no effect for the current mode,
  ; and makes the GUI feel consistent and predictable.

  Protected samplerMode.i = GetGadgetState(#G_SamplerMode)

  If samplerMode = 1
    ; BINOMIAL: enable binomial controls, disable kernel selection.
    DisableGadget(#G_BinomMethod, 0)

    ; K is only relevant when CLT is chosen (binomial method = 2).
    ; If method is not CLT (2), K is disabled.
    DisableGadget(#G_BinomK, Bool(GetGadgetState(#G_BinomMethod) <> 2))

    ; Kernel policy is irrelevant in BINOMIAL mode (no bitstreams are generated).
    DisableGadget(#G_ForceKernel, 1)
  Else
    ; BIT-EXACT: disable binomial-only controls, enable kernel selection.
    DisableGadget(#G_BinomMethod, 1)
    DisableGadget(#G_BinomK, 1)
    DisableGadget(#G_ForceKernel, 0)
  EndIf
EndProcedure

Procedure ApplyBinomialMethodUIRules()
  ; Only the CLT path uses K. Keep this narrow so selecting a method does not
  ; churn unrelated native controls while the ComboBox is still closing.
  If GetGadgetState(#G_SamplerMode) = 1
    DisableGadget(#G_BinomK, Bool(GetGadgetState(#G_BinomMethod) <> 2))
  EndIf
EndProcedure

Procedure SyncConfigurationSelectionCache()
  If IsGadget(#G_SamplerMode)
    gLastSamplerMode = GetGadgetState(#G_SamplerMode)
  EndIf
  If IsGadget(#G_BinomMethod)
    gLastBinomialMethod = GetGadgetState(#G_BinomMethod)
  EndIf
EndProcedure

Procedure HandleConfigurationComboChange(gadget.i, eventType.i)
  Protected samplerMode.i
  Protected binomialMethod.i

  If eventType <> #PB_EventType_Change
    ProcedureReturn
  EndIf
  If gHandlingConfigComboEvent
    ProcedureReturn
  EndIf

  samplerMode = GetGadgetState(#G_SamplerMode)
  binomialMethod = GetGadgetState(#G_BinomMethod)

  If samplerMode < 0 : samplerMode = #SAMPLER_MODE : EndIf
  If binomialMethod < 0 Or binomialMethod > 3 : binomialMethod = 0 : EndIf

  Select gadget
    Case #G_SamplerMode
      If samplerMode = gLastSamplerMode
        ProcedureReturn
      EndIf
    Case #G_BinomMethod
      If binomialMethod = gLastBinomialMethod
        ProcedureReturn
      EndIf
    Default
      ProcedureReturn
  EndSelect

  gLastSamplerMode = samplerMode
  gLastBinomialMethod = binomialMethod
  configuredSamplerMode = samplerMode
  configuredBinomialMethod = binomialMethod

  gHandlingConfigComboEvent = 1
  BeginUiRedrawBatch()
  If gadget = #G_SamplerMode
    ApplySamplerUIRules()
  Else
    ApplyBinomialMethodUIRules()
  EndIf
  EndUiRedrawBatch()
  UpdateDerivedInfo()
  gHandlingConfigComboEvent = 0
EndProcedure

Procedure ApplyThreadUIRules()
  ; Thread control rules:
  ; - Applies equally to BINOMIAL and BIT-EXACT.
  ; - Clamp to [1..#POOL_MAX_THREADS] to protect UI and scheduler.

  Protected policy.i = GetGadgetState(#G_ThreadPolicy)
  Protected cpuCount.q = GetCpuCountCached()
  Protected threads.q = ResolveThreadCount(policy, ParseIntQFromGadget(#G_CustomThreads, cpuCount * cpuCount))

  ; Keep global in sync for pool sizing calls outside StartSimulation().
  workerThreadCount = threads
  DisableGadget(#G_ThreadPolicy, #False)

  If policy = 2
    DisableGadget(#G_CustomThreads, #False)
  Else
    SetGadgetText(#G_CustomThreads, Str(threads))
    DisableGadget(#G_CustomThreads, #True)
  EndIf
EndProcedure

Procedure ApplySaveUIRules()
  ; Enable/disable output file selection based on the Save checkbox.
  Protected save.i = GetGadgetState(#G_SaveToFile)

  If save
    DisableGadget(#G_OutputPath, #False)
    DisableGadget(#G_BrowsePath, #False)
    GadgetToolTip(#G_OutputPath, "Output file path (used only when saving is enabled).")
    GadgetToolTip(#G_BrowsePath, "Browse for output file path.")
  Else
    DisableGadget(#G_OutputPath, #True)
    DisableGadget(#G_BrowsePath, #True)
    GadgetToolTip(#G_OutputPath, "Disabled: enable 'Save output file' to select a file path.")
    GadgetToolTip(#G_BrowsePath, "Disabled: enable 'Save output file' to browse for a file.")
  EndIf
EndProcedure

; =============================================================================
; Plot UI rules (industry-standard behavior)
; =============================================================================
Procedure ApplyPlotUIRules()
  ; Graph selection is locked during a run so the log label matches measured work.
  liveGraphEnabled = GetGadgetState(#G_LiveGraph)
  DisableGadget(#G_LiveGraph, simulationIsRunning)

  ; Threshold affects plot + ">= threshold" counts. Lock while running to keep stats consistent.
  configuredPlotThreshold = ClampQ(ParseIntQFromGadget(#G_PlotThreshold, #PLOT_THRESHOLD), 0, 65535)
  SetGadgetText(#G_PlotThreshold, Str(configuredPlotThreshold))
  lastPlotThresholdText = GetGadgetText(#G_PlotThreshold)
  DisableGadget(#G_PlotThreshold, simulationIsRunning)

  ; The "Load data..." button is only meaningful when the simulator is NOT running.
  DisableGadget(#G_LoadData, simulationIsRunning)

  ; Redraw once so the plot immediately reflects the checkbox state / threshold.
  ; - If Live graph is OFF: the canvas gets a grey overlay.
  ; - If Live graph is ON : the overlay is removed and live updates resume on the plot timer.
  UpdateDistributionPlot()
EndProcedure

; =============================================================================

Procedure ApplyConfigurationUIRules()
  ApplySamplerUIRules()
  ApplyThreadUIRules()
  ApplySaveUIRules()
EndProcedure

Procedure ApplyRunControlUI(isRunning.i)
  BeginUiRedrawBatch()
  DisableSettings(isRunning)
  DisableGadget(#G_Start, Bool(isRunning))
  DisableGadget(#G_Stop, Bool(Not isRunning))
  ApplyConfigurationUIRules()
  ApplyPlotUIRules()
  EndUiRedrawBatch()
EndProcedure

Global lastPlotStatusText.s
Global lastPlotStatusUpdateMs.q

Procedure SetPlotStatusLine(prefix.s, progress.i, etaSeconds.d, throughputFlipsPerMs.d, liveThroughputFlipsPerMs.d, maxDeviation.q, maxPct.d, zSigma.d, forceUpdate.i = #False)
  Protected pct.i = progress
  Protected text.s

  If IsGadget(#G_PlotInfo) = 0 : ProcedureReturn : EndIf

  If pct < 0 : pct = 0 : EndIf
  If pct > 100 : pct = 100 : EndIf

  If prefix <> ""
    text = prefix + "  "
  EndIf

  text + "P:" + Str(pct) + "%"

  If etaSeconds >= 0.0
    text + "  E:" + FormatDuration(etaSeconds)
  EndIf

  If throughputFlipsPerMs >= 0.0
    text + "  T:" + FormatCfMs(throughputFlipsPerMs)
  EndIf

  If liveThroughputFlipsPerMs >= 0.0
    text + "  L:" + FormatCfMs(liveThroughputFlipsPerMs)
  EndIf

  If maxDeviation >= 0
    text + "  M:" + Str(maxDeviation) + " (" + FormatNumber(maxPct, 2) + "%, " + FormatNumber(zSigma, 2) + "s)"
  EndIf

  If forceUpdate = #False
    If text = lastPlotStatusText
      ProcedureReturn
    EndIf

    If simulationIsRunning And prefix = "Running"
      Protected nowMs.q = ElapsedMilliseconds()
      If lastPlotStatusUpdateMs > 0 And nowMs - lastPlotStatusUpdateMs < #PLOT_STATUS_UPDATE_MS
        ProcedureReturn
      EndIf
      lastPlotStatusUpdateMs = nowMs
    EndIf
  Else
    lastPlotStatusUpdateMs = ElapsedMilliseconds()
  EndIf

  DrawPlotStatusCanvas(text, forceUpdate)
  lastPlotStatusText = text
EndProcedure

; =============================================================================
; Load a saved .data file (only when the simulator is stopped)
; - Reads WORD deviations (2 bytes each)
; - Computes mean, std-dev (Welford), max, and count >= threshold
; - Stores the stats into the same globals used by the live plot
; =============================================================================
Procedure LoadDeviationDataFile(filePath.s)
  Protected file.i, fileSize.q, bytesLeft.q
  Protected *buf, bufSize.i, bytesToRead.i, bytesRead.i
  Protected count.q
  Protected mean.d, m2.d
  Protected v.i, delta.d
  Protected countAbove.q
  Protected maxValue.i
  Protected words.i, *p, i.i

  If simulationIsRunning
    ProcedureReturn
  EndIf

  If filePath = ""
    ProcedureReturn
  EndIf

  file = ReadFile(#PB_Any, filePath)
  If file = 0
    MessageRequester("Load data", "Could not open file:" + #LF$ + filePath, #PB_MessageRequester_Error)
    ProcedureReturn
  EndIf

  fileSize = Lof(file)
  If fileSize < 2
    CloseFile(file)
    MessageRequester("Load data", "File is empty or too small.", #PB_MessageRequester_Warning)
    ProcedureReturn
  EndIf

  ; Reset stats
  ResetDeviationStats()
  loadedDataFilePath = filePath
  loadedDataIsActive = 1

  ; Buffered reading (fast even for very large files)
  bufSize = 1024 * 1024   ; 1 MiB
  *buf = AllocateMemory(bufSize)
  If *buf = 0
    CloseFile(file)
    MessageRequester("Load data", "Out of memory while allocating read buffer.", #PB_MessageRequester_Error)
    ProcedureReturn
  EndIf

  bytesLeft = fileSize

  While bytesLeft > 0
    bytesToRead = bufSize
    If bytesToRead > bytesLeft
      bytesToRead = bytesLeft
    EndIf

    bytesRead = ReadData(file, *buf, bytesToRead)
    If bytesRead <= 0
      Break
    EndIf

    ; Interpret as WORDs (little-endian). If the file ends with an odd byte, ignore it.
    words = bytesRead / 2
    *p = *buf

    For i = 0 To words - 1
      v = PeekW(*p) & $FFFF
      *p + 2

      count + 1

      ; Welford running mean/std-dev
      delta = v - mean
      mean + delta / count
      m2 + delta * (v - mean)

      If v >= configuredPlotThreshold
        countAbove + 1
        AppendPlotAboveValue(v)
      EndIf

      If v > maxValue
        maxValue = v
      EndIf
    Next

    bytesLeft - bytesRead
  Wend

  FreeMemory(*buf)
  CloseFile(file)

; Store computed stats into globals used by the plot.
; Note: ioMutex may not exist until a simulation run has started, so guard it.
If ioMutex
  LockMutex(ioMutex)
    deviationStatsCount = count
    deviationStatsMean  = mean
    deviationStatsM2    = m2
    deviationStatsCountAtOrAboveThreshold = countAbove
    deviationStatsMaxValue = maxValue
  UnlockMutex(ioMutex)
Else
  deviationStatsCount = count
  deviationStatsMean  = mean
  deviationStatsM2    = m2
  deviationStatsCountAtOrAboveThreshold = countAbove
  deviationStatsMaxValue = maxValue
EndIf

  LogLine("Loaded data file for plot: " + GetFilePart(filePath) + " (" + FormatNumber(count, 0, ".", ",") + " points)")
  UpdateDistributionPlot()
EndProcedure

; =============================================================================
; Load embedded deviation data (no disk I/O)
; - Used to show a meaningful plot at program startup
; - Also used when Reset is clicked
; =============================================================================
Procedure LoadEmbeddedDeviationData()
  Protected i.i
  Protected v.i
  Protected count.q
  Protected mean.d, m2.d
  Protected delta.d
  Protected countAbove.q
  Protected maxValue.i
  Protected *p

  If simulationIsRunning
    ProcedureReturn
  EndIf

  ; Reset stats and mark plot source.
  ResetDeviationStats()
  loadedDataIsActive = 1
  loadedDataFilePath = "(embedded)"

  *p = ?EmbeddedDeviationData
  For i = 0 To #EMBEDDED_PLOT_WORDS - 1
    v = PeekW(*p) & $FFFF
    *p + 2

    count + 1
    delta = v - mean
    mean + delta / count
    m2 + delta * (v - mean)

    If v >= configuredPlotThreshold
      countAbove + 1
      AppendPlotAboveValue(v)
    EndIf
    If v > maxValue
      maxValue = v
    EndIf
  Next

  ; Store computed stats into globals used by the plot.
  If ioMutex
    LockMutex(ioMutex)
      deviationStatsCount = count
      deviationStatsMean  = mean
      deviationStatsM2    = m2
      deviationStatsCountAtOrAboveThreshold = countAbove
      deviationStatsMaxValue = maxValue
    UnlockMutex(ioMutex)
  Else
    deviationStatsCount = count
    deviationStatsMean  = mean
    deviationStatsM2    = m2
    deviationStatsCountAtOrAboveThreshold = countAbove
    deviationStatsMaxValue = maxValue
  EndIf

  UpdateDistributionPlot()
EndProcedure

Procedure CopyLogToClipboard()
  Protected OUT.s = GetGadgetText(#G_Log)
  If OUT <> ""
    SetClipboardText(OUT)
    LogLine("Log copied to clipboard.")
  EndIf
EndProcedure

; Copy selected editor text, or the whole editor when no selection exists.
; Native edit-control messages keep clipboard behavior correct for RichEdit.
Procedure CopyEditorSelectionOrAll(editorGadget.i)
  If IsGadget(editorGadget) = 0
    ProcedureReturn
  EndIf

  ; Ensure the RichEdit has focus; WM_COPY can fail if another control owns focus.
  SetActiveGadget(editorGadget)
  Protected selA.l, selB.l
  Protected oldA.l, oldB.l

  SendMessage_(GadgetID(editorGadget), #MSG_EM_GETSEL, @selA, @selB)
  If selB > selA
    ; Copy selected text.
    SendMessage_(GadgetID(editorGadget), #MSG_WM_COPY, 0, 0)
  Else
    ; No selection -> copy all (temporarily select everything).
    oldA = selA : oldB = selB
    SendMessage_(GadgetID(editorGadget), #EM_SETSEL, 0, -1)
    SendMessage_(GadgetID(editorGadget), #MSG_WM_COPY, 0, 0)
    SendMessage_(GadgetID(editorGadget), #EM_SETSEL, oldA, oldB)
  EndIf
EndProcedure

Procedure CopyLogSelectionOrAll()
  CopyEditorSelectionOrAll(#G_Log)
EndProcedure

Procedure ClearLogUI()
  SetGadgetText(#G_Log, "")
EndProcedure

Procedure.i AppendLogExportsEnabled()
  If IsGadget(#G_AppendFiles)
    gAppendLogExports = Bool(GetGadgetState(#G_AppendFiles))
  EndIf

  ProcedureReturn Bool(gAppendLogExports)
EndProcedure

Procedure SetAppendLogExports(enabled.i, sourceGadget.i = -1)
  gAppendLogExports = Bool(enabled)
  If sourceGadget <> #G_AppendFiles And IsGadget(#G_AppendFiles)
    SetGadgetState(#G_AppendFiles, gAppendLogExports)
  EndIf
  SaveViewPreference()
EndProcedure

Procedure.i AppendAnalysisExportsEnabled()
  ProcedureReturn Bool(gAppendAnalysisExports)
EndProcedure

Procedure SetAppendAnalysisExports(enabled.i)
  gAppendAnalysisExports = Bool(enabled)
  SaveViewPreference()
EndProcedure

Procedure.s DefaultTextExportPath(name.s)
  Protected dir.s = GetUserDirectory(#PB_Directory_Documents)
  If dir = ""
    dir = GetCurrentDirectory()
  EndIf

  ProcedureReturn dir + name + "_" + #ProgramVersion$ + ".txt"
EndProcedure

Procedure.s TextExportHeader(action.s)
  Protected stamp.s = FormatDate("%yyyy-%mm-%dd %hh:%ii:%ss", Date())
  Protected line.s = "============================================================"

  ProcedureReturn line + #CRLF$ +
                  action + " " + stamp + "  |  Version " + #AppVersion$ + #CRLF$ +
                  line + #CRLF$ + #CRLF$
EndProcedure

Procedure.s TextExportAppendSeparator()
  ProcedureReturn #CRLF$ + #CRLF$ + TextExportHeader("Appended")
EndProcedure

Procedure.i WriteTextExportFile(filePath.s, text.s, appendMode.i)
  Protected file.i
  Protected existingSize.q

  If filePath = "" Or text = ""
    ProcedureReturn #False
  EndIf

  If appendMode And FileSize(filePath) >= 0
    file = OpenFile(#PB_Any, filePath)
    If file
      existingSize = Lof(file)
      FileSeek(file, existingSize)
      If existingSize > 0
        WriteString(file, TextExportAppendSeparator(), #PB_UTF8)
      EndIf
    EndIf
  Else
    file = CreateFile(#PB_Any, filePath)
  EndIf

  If file = 0
    ProcedureReturn #False
  EndIf

  If appendMode = 0 Or existingSize = 0
    WriteString(file, TextExportHeader("Saved"), #PB_UTF8)
  EndIf
  WriteString(file, text, #PB_UTF8)
  If Right(text, 2) <> #CRLF$ And Right(text, 1) <> #LF$
    WriteString(file, #CRLF$, #PB_UTF8)
  EndIf
  CloseFile(file)
  ProcedureReturn #True
EndProcedure

Procedure.s ReadTextExportFile(filePath.s)
  Protected file.i
  Protected text.s
  Protected line.s
  Protected firstLine.i = #True

  file = ReadFile(#PB_Any, filePath)
  If file = 0
    ProcedureReturn ""
  EndIf

  While Eof(file) = 0
    line = ReadString(file, #PB_UTF8)
    If firstLine = #False
      text + #CRLF$
    EndIf
    text + line
    firstLine = #False
  Wend

  CloseFile(file)
  ProcedureReturn text
EndProcedure

Procedure SaveLogToFile()
  Protected logText.s = GetGadgetText(#G_Log)
  Protected appendMode.i = AppendLogExportsEnabled()
  Protected filePath.s

  If logText = ""
    MessageRequester("Save log", "The log is empty.", #PB_MessageRequester_Info)
    ProcedureReturn
  EndIf

  filePath = SaveFileRequester("Save log", DefaultTextExportPath("Coinflip_Log"), "Text (*.txt)|*.txt|Log (*.log)|*.log|All (*.*)|*.*", 0)
  If filePath = ""
    ProcedureReturn
  EndIf

  If WriteTextExportFile(filePath, logText, appendMode)
    If appendMode
      LogLine("Log appended to " + GetFilePart(filePath) + ".")
    Else
      LogLine("Log saved to " + GetFilePart(filePath) + ".")
    EndIf
  Else
    MessageRequester("Save log", "Could not write the log file.", #PB_MessageRequester_Error)
  EndIf
EndProcedure

Procedure LoadLogFromFile()
  Protected filePath.s
  Protected text.s

  filePath = OpenFileRequester("Load log", DefaultTextExportPath("Coinflip_Log"), "Text (*.txt)|*.txt|Log (*.log)|*.log|All (*.*)|*.*", 0)
  If filePath = ""
    ProcedureReturn
  EndIf

  text = ReadTextExportFile(filePath)
  If text = "" And FileSize(filePath) > 0
    MessageRequester("Load log", "Could not read the selected log file.", #PB_MessageRequester_Error)
    ProcedureReturn
  EndIf

  SetGadgetText(#G_Log, text)
  LogLine("Log loaded from " + GetFilePart(filePath) + ".")
EndProcedure

Procedure SaveAnalysisToFile(body.s)
  Protected appendMode.i = AppendAnalysisExportsEnabled()
  Protected filePath.s

  If body = ""
    MessageRequester("Save analysis", "The analysis is empty.", #PB_MessageRequester_Info)
    ProcedureReturn
  EndIf

  filePath = SaveFileRequester("Save analysis", DefaultTextExportPath("Coinflip_Analysis"), "Text (*.txt)|*.txt|All (*.*)|*.*", 0)
  If filePath = ""
    ProcedureReturn
  EndIf

  If WriteTextExportFile(filePath, body, appendMode)
    If appendMode
      MessageRequester("Save analysis", "Analysis appended to " + GetFilePart(filePath) + ".", #PB_MessageRequester_Info)
    Else
      MessageRequester("Save analysis", "Analysis saved to " + GetFilePart(filePath) + ".", #PB_MessageRequester_Info)
    EndIf
  Else
    MessageRequester("Save analysis", "Could not write the analysis file.", #PB_MessageRequester_Error)
  EndIf
EndProcedure

Procedure.s BuildLogAnalysisSummary(logText.s)
  Protected lines.i = CountString(logText, #LF$) + 1
  Protected i.i
  Protected line.s
  Protected payload.s
  Protected modeText.s
  Protected familyText.s
  Protected planText.s
  Protected firstPlanText.s
  Protected graphText.s
  Protected resultText.s
  Protected elapsedText.s
  Protected speed.d
  Protected sigma.d
  Protected hasSigma.i
  Protected expectedSigma.d
  Protected expectedLow.d
  Protected expectedHigh.d
  Protected hasExpected.i
  Protected inRun.i
  Protected runCount.i
  Protected completedCount.i
  Protected bitCount.i
  Protected binCount.i
  Protected best.i = -1
  Protected bestBit.i = -1
  Protected bestBin.i = -1
  Protected slowest.i = -1
  Protected summary.s
  Protected rel.d
  Protected modelCount.i
  Protected modelIndex.i
  Protected avgSpeed.d
  Protected m.i
  Protected elapsedAt.i
  Protected mixedPlans.i
  Protected error.d
  Protected bestAccuracyModel.i = -1
  Protected bestSpeedModel.i = -1
  Protected speedAvg.d
  Protected accuracyAvg.d
  Protected fitText.s
  Protected sigmaText.s
  Protected graphDisplayText.s
  Protected graphSelectedCount.i
  Protected graphNotSelectedCount.i
  Protected graphCompareModel.i = -1
  Protected graphCompareCount.i
  Protected graphOnAvg.d
  Protected graphOffAvg.d
  Protected graphSpeedRatio.d
  Protected graphSpeedPct.d
  Protected graphSigmaText.s
  Protected graphPairedModelCount.i
  Protected graphSelectedFasterCount.i
  Protected graphNotSelectedFasterCount.i
  Protected graphTieCount.i
  Protected graphImpactSumPct.d
  Protected graphImpactAvgPct.d
  Protected graphImpactText.s
  Protected graphVerdictText.s
  Protected topLimit.i

  Protected Dim runs.LogAnalysisRun(0)
  Protected Dim models.LogAnalysisModel(0)

  For i = 1 To lines
    line = StringField(logText, i, #LF$)
    payload = ExtractLogPayload(line)

    If FindString(payload, "---- Run ", 1)
      If inRun And modeText <> "" And speed >= 0.0
        ReDim runs.LogAnalysisRun(runCount)
        runs(runCount)\mode = modeText
        runs(runCount)\family = familyText
        runs(runCount)\plan = planText
        runs(runCount)\graphState = graphText
        runs(runCount)\elapsed = elapsedText
        runs(runCount)\result = resultText
        runs(runCount)\expectedSigma = expectedSigma
        runs(runCount)\expectedLow = expectedLow
        runs(runCount)\expectedHigh = expectedHigh
        runs(runCount)\hasExpected = hasExpected
        runs(runCount)\sigma = sigma
        runs(runCount)\hasSigma = hasSigma
        runs(runCount)\speed = speed
        runCount + 1
      EndIf
      modeText = ""
      familyText = ""
      planText = ""
      graphText = ""
      resultText = ""
      elapsedText = ""
      speed = -1.0
      sigma = -1.0
      hasSigma = 0
      expectedSigma = -1.0
      expectedLow = -1.0
      expectedHigh = -1.0
      hasExpected = 0
      inRun = 1

    ElseIf inRun And LogPayloadHasLabel(payload, "Plan:")
      planText = LogPayloadValue(payload, "Plan:")

    ElseIf inRun And LogPayloadHasLabel(payload, "Graph:")
      graphText = LCase(LogPayloadValue(payload, "Graph:"))
      If graphText = "yes" Or graphText = "selected"
        graphText = "on"
      ElseIf graphText = "no" Or graphText = "not selected"
        graphText = "off"
      EndIf

    ElseIf inRun And LogPayloadHasLabel(payload, "Stats:")
      expectedSigma = ParseExpectedSigmaMeanFromStats(payload)
      expectedLow = ParseExpectedSigmaRangeValue(payload, #False)
      expectedHigh = ParseExpectedSigmaRangeValue(payload, #True)
      hasExpected = Bool(expectedSigma >= 0.0)

    ElseIf inRun And LogPayloadHasLabel(payload, "Mode:")
      modeText = LogPayloadValue(payload, "Mode:")
      If FindString(modeText, "BINOMIAL", 1)
        familyText = "BINOMIAL"
      ElseIf FindString(modeText, "BIT-EXACT", 1)
        familyText = "BIT-EXACT"
      Else
        familyText = "OTHER"
      EndIf

    ElseIf inRun And LogPayloadHasLabel(payload, "Finished:")
      elapsedAt = FindString(payload, "elapsed", 1)
      If elapsedAt
        elapsedText = CleanLogValue(Mid(payload, elapsedAt + Len("elapsed")))
      EndIf

    ElseIf inRun And LogPayloadHasLabel(payload, "Result:")
      resultText = LogPayloadValue(payload, "Result:")
      sigma = ParseResultSigmaFromText(resultText)
      hasSigma = Bool(sigma >= 0.0)

    ElseIf inRun And LogPayloadHasLabel(payload, "Speed:")
      speed = ParseSpeedCfMsFromLine(payload)
    EndIf
  Next

  If inRun And modeText <> "" And speed >= 0.0
    ReDim runs.LogAnalysisRun(runCount)
    runs(runCount)\mode = modeText
    runs(runCount)\family = familyText
    runs(runCount)\plan = planText
    runs(runCount)\graphState = graphText
    runs(runCount)\elapsed = elapsedText
    runs(runCount)\result = resultText
    runs(runCount)\expectedSigma = expectedSigma
    runs(runCount)\expectedLow = expectedLow
    runs(runCount)\expectedHigh = expectedHigh
    runs(runCount)\hasExpected = hasExpected
    runs(runCount)\sigma = sigma
    runs(runCount)\hasSigma = hasSigma
    runs(runCount)\speed = speed
    runCount + 1
  EndIf

  If runCount = 0
    ProcedureReturn "No complete runs found in the log." + #LF$ +
                    "Run one or more models until a Speed line is written, then click Analyse again."
  EndIf

  completedCount = runCount
  For i = 0 To runCount - 1
    If best < 0 Or runs(i)\speed > runs(best)\speed : best = i : EndIf
    If slowest < 0 Or runs(i)\speed < runs(slowest)\speed : slowest = i : EndIf

    If runs(i)\plan <> ""
      If firstPlanText = ""
        firstPlanText = runs(i)\plan
      ElseIf runs(i)\plan <> firstPlanText
        mixedPlans = 1
      EndIf
    EndIf

    If runs(i)\family = "BIT-EXACT"
      bitCount + 1
      If bestBit < 0 Or runs(i)\speed > runs(bestBit)\speed : bestBit = i : EndIf
    ElseIf runs(i)\family = "BINOMIAL"
      binCount + 1
      If bestBin < 0 Or runs(i)\speed > runs(bestBin)\speed : bestBin = i : EndIf
    EndIf

    modelIndex = -1
    For m = 0 To modelCount - 1
      If models(m)\mode = NormalizeAnalysisMode(runs(i)\mode)
        modelIndex = m
        Break
      EndIf
    Next

    If modelIndex < 0
      ReDim models.LogAnalysisModel(modelCount)
      modelIndex = modelCount
      models(modelIndex)\mode = NormalizeAnalysisMode(runs(i)\mode)
      models(modelIndex)\family = runs(i)\family
      models(modelIndex)\bestSpeed = runs(i)\speed
      models(modelIndex)\worstSpeed = runs(i)\speed
      models(modelIndex)\bestSigma = runs(i)\sigma
      models(modelIndex)\worstSigma = runs(i)\sigma
      modelCount + 1
    EndIf

    models(modelIndex)\count + 1
    models(modelIndex)\sumSpeed + runs(i)\speed
    If runs(i)\graphState = "on"
      models(modelIndex)\graphOnCount + 1
      models(modelIndex)\graphOnSpeedSum + runs(i)\speed
      graphSelectedCount + 1
      If runs(i)\hasSigma
        models(modelIndex)\graphOnSigmaCount + 1
        models(modelIndex)\graphOnSigmaSum + runs(i)\sigma
      EndIf
    ElseIf runs(i)\graphState = "off"
      models(modelIndex)\graphOffCount + 1
      models(modelIndex)\graphOffSpeedSum + runs(i)\speed
      graphNotSelectedCount + 1
      If runs(i)\hasSigma
        models(modelIndex)\graphOffSigmaCount + 1
        models(modelIndex)\graphOffSigmaSum + runs(i)\sigma
      EndIf
    EndIf
    If runs(i)\speed > models(modelIndex)\bestSpeed : models(modelIndex)\bestSpeed = runs(i)\speed : EndIf
    If runs(i)\speed < models(modelIndex)\worstSpeed : models(modelIndex)\worstSpeed = runs(i)\speed : EndIf
    If runs(i)\hasSigma
      models(modelIndex)\sigmaCount + 1
      models(modelIndex)\sumSigma + runs(i)\sigma
      If models(modelIndex)\sigmaCount = 1
        models(modelIndex)\bestSigma = runs(i)\sigma
        models(modelIndex)\worstSigma = runs(i)\sigma
      Else
        If runs(i)\sigma > models(modelIndex)\bestSigma : models(modelIndex)\bestSigma = runs(i)\sigma : EndIf
        If runs(i)\sigma < models(modelIndex)\worstSigma : models(modelIndex)\worstSigma = runs(i)\sigma : EndIf
      EndIf
    EndIf
    If runs(i)\hasSigma And runs(i)\hasExpected
      error = Abs(runs(i)\sigma - runs(i)\expectedSigma)
      models(modelIndex)\fitCount + 1
      models(modelIndex)\sumAbsSigmaError + error
      If runs(i)\expectedLow >= 0.0 And runs(i)\expectedHigh >= 0.0
        If runs(i)\sigma >= runs(i)\expectedLow And runs(i)\sigma <= runs(i)\expectedHigh
          models(modelIndex)\inExpectedRange + 1
        EndIf
      EndIf
    EndIf
  Next

  For i = 0 To modelCount - 1
    speedAvg = models(i)\sumSpeed / models(i)\count
    If bestSpeedModel < 0 Or speedAvg > (models(bestSpeedModel)\sumSpeed / models(bestSpeedModel)\count)
      bestSpeedModel = i
    EndIf
    If models(i)\fitCount > 0
      accuracyAvg = models(i)\sumAbsSigmaError / models(i)\fitCount
      If bestAccuracyModel < 0 Or accuracyAvg < (models(bestAccuracyModel)\sumAbsSigmaError / models(bestAccuracyModel)\fitCount)
        bestAccuracyModel = i
      EndIf
    EndIf
    If models(i)\graphOnCount > 0 And models(i)\graphOffCount > 0
      graphOnAvg = models(i)\graphOnSpeedSum / models(i)\graphOnCount
      graphOffAvg = models(i)\graphOffSpeedSum / models(i)\graphOffCount
      If graphOffAvg > 0.0
        graphSpeedPct = ((graphOnAvg / graphOffAvg) - 1.0) * 100.0
        graphImpactSumPct + graphSpeedPct
        graphPairedModelCount + 1
        If graphSpeedPct > 0.05
          graphSelectedFasterCount + 1
        ElseIf graphSpeedPct < -0.05
          graphNotSelectedFasterCount + 1
        Else
          graphTieCount + 1
        EndIf
      EndIf
      If graphCompareModel < 0 Or (models(i)\graphOnCount + models(i)\graphOffCount) > graphCompareCount
        graphCompareModel = i
        graphCompareCount = models(i)\graphOnCount + models(i)\graphOffCount
      EndIf
    EndIf
  Next
  If graphPairedModelCount > 0
    graphImpactAvgPct = graphImpactSumPct / graphPairedModelCount
  EndIf

  summary = "ANALYSE CURRENT LOG" + #LF$
  summary + "===================" + #LF$
  summary + "Scope   current visible log only" + #LF$
  summary + "Runs    " + Str(completedCount) + " complete | models " + Str(modelCount) + " | bit-exact " + Str(bitCount) + " | binomial " + Str(binCount) + #LF$
  If mixedPlans
    summary + "Workload mixed plans; compare speed with care" + #LF$
  ElseIf firstPlanText <> ""
    summary + "Workload " + ShortLogText(firstPlanText, 76) + #LF$
  EndIf

  summary + "KEY TAKEAWAYS" + #LF$
  If best >= 0
    summary + "- Fastest run: " + CompactAnalysisMode(runs(best)\mode, 30) + " at " + FormatCompactCfMs(runs(best)\speed) + " cf/ms"
    If runs(best)\graphState <> ""
      summary + " (" + AnalysisGraphLabel(runs(best)\graphState) + ")"
    EndIf
    summary + #LF$
  EndIf
  If bestSpeedModel >= 0
    summary + "- Best average: " + CompactAnalysisMode(models(bestSpeedModel)\mode, 30) + " at " + FormatCompactCfMs(models(bestSpeedModel)\sumSpeed / models(bestSpeedModel)\count) + " cf/ms"
    summary + " across " + Str(models(bestSpeedModel)\count) + " run"
    If models(bestSpeedModel)\count <> 1 : summary + "s" : EndIf
    summary + #LF$
  EndIf
  If graphPairedModelCount > 0
    If graphImpactAvgPct < -0.05
      graphImpactText = TrimDecimalZeros(FormatNumber(Abs(graphImpactAvgPct), 1, ".", ",")) + "% slower"
    ElseIf graphImpactAvgPct > 0.05
      graphImpactText = TrimDecimalZeros(FormatNumber(graphImpactAvgPct, 1, ".", ",")) + "% faster"
    Else
      graphImpactText = "about the same speed"
    EndIf
    summary + "- Graph selected: " + graphImpactText + " on average across " + Str(graphPairedModelCount) + " matched model"
    If graphPairedModelCount <> 1 : summary + "s" : EndIf
    summary + #LF$
  EndIf
  If bestAccuracyModel >= 0
    summary + "- Closest expected max: " + CompactAnalysisMode(models(bestAccuracyModel)\mode, 28)
    summary + " | fit " + FormatNumber(models(bestAccuracyModel)\sumAbsSigmaError / models(bestAccuracyModel)\fitCount, 2, ".", ",") + "s"
    summary + " | range " + Str(models(bestAccuracyModel)\inExpectedRange) + "/" + Str(models(bestAccuracyModel)\fitCount) + #LF$
  EndIf

  summary + "GRAPH IMPACT BY MODEL" + #LF$
  If graphSelectedCount > 0 Or graphNotSelectedCount > 0
    summary + "Logged selected " + Str(graphSelectedCount) + " run"
    If graphSelectedCount <> 1 : summary + "s" : EndIf
    summary + " | not selected " + Str(graphNotSelectedCount) + " run"
    If graphNotSelectedCount <> 1 : summary + "s" : EndIf
    summary + #LF$
    If graphPairedModelCount > 0
      summary + "Matched models " + Str(graphPairedModelCount) + " | selected faster " + Str(graphSelectedFasterCount)
      summary + " | not selected faster " + Str(graphNotSelectedFasterCount)
      If graphTieCount > 0
        summary + " | tied " + Str(graphTieCount)
      EndIf
      summary + #LF$
      summary + PadRight("Model", 20) + " " + PadLeft("Selected", 9) + " " + PadLeft("Not sel", 9) + " " + PadLeft("Impact", 8) + "  Read" + #LF$
      summary + PadRight("-----", 20) + " " + PadLeft("--------", 9) + " " + PadLeft("-------", 9) + " " + PadLeft("------", 8) + "  ----" + #LF$
      For i = 0 To modelCount - 1
        If models(i)\graphOnCount > 0 And models(i)\graphOffCount > 0
          graphOnAvg = models(i)\graphOnSpeedSum / models(i)\graphOnCount
          graphOffAvg = models(i)\graphOffSpeedSum / models(i)\graphOffCount
          If graphOffAvg > 0.0
            graphSpeedPct = ((graphOnAvg / graphOffAvg) - 1.0) * 100.0
            If graphSpeedPct < -0.05
              graphImpactText = "-" + TrimDecimalZeros(FormatNumber(Abs(graphSpeedPct), 1, ".", ",")) + "%"
              graphVerdictText = "not selected faster"
            ElseIf graphSpeedPct > 0.05
              graphImpactText = "+" + TrimDecimalZeros(FormatNumber(graphSpeedPct, 1, ".", ",")) + "%"
              graphVerdictText = "selected faster"
            Else
              graphImpactText = "0%"
              graphVerdictText = "same"
            EndIf
            summary + PadRight(CompactAnalysisMode(models(i)\mode, 20), 20) + " "
            summary + PadLeft(FormatCompactCfMs(graphOnAvg), 9) + " "
            summary + PadLeft(FormatCompactCfMs(graphOffAvg), 9) + " "
            summary + PadLeft(graphImpactText, 8) + "  " + graphVerdictText + #LF$
          EndIf
        EndIf
      Next
    Else
      summary + "Graph state is logged, but no model has both selected and not selected runs." + #LF$
      summary + "Run the same model both ways for a direct graph impact comparison." + #LF$
    EndIf
  Else
    summary + "Cannot compare: graph state was not recorded in these runs." + #LF$
    summary + "New runs record it automatically. Run the same model once selected and once not selected." + #LF$
  EndIf

  If modelCount = 1
    summary + "REPEAT STABILITY" + #LF$
    summary + CompactAnalysisMode(models(0)\mode, 34) + ": " + Str(models(0)\count) + " run"
    If models(0)\count <> 1 : summary + "s" : EndIf
    summary + " | avg " + FormatCompactCfMs(models(0)\sumSpeed / models(0)\count) + " cf/ms"
    summary + " | best " + FormatCompactCfMs(models(0)\bestSpeed)
    summary + " | slow " + FormatCompactCfMs(models(0)\worstSpeed) + #LF$
    If models(0)\worstSpeed > 0.0 And models(0)\bestSpeed <> models(0)\worstSpeed
      summary + "Run spread: " + FormatNumber(models(0)\bestSpeed / models(0)\worstSpeed, 2, ".", ",") + "x fastest vs slowest" + #LF$
    EndIf
  EndIf

  summary + "SPEED AND RESULT CHECK" + #LF$
  If bestBit >= 0
    summary + "Best bit-exact: " + CompactAnalysisMode(runs(bestBit)\mode, 30) + " at " + FormatCompactCfMs(runs(bestBit)\speed) + " cf/ms" + #LF$
  EndIf
  If bestBin >= 0
    summary + "Best binomial:  " + CompactAnalysisMode(runs(bestBin)\mode, 30) + " at " + FormatCompactCfMs(runs(bestBin)\speed) + " cf/ms" + #LF$
  EndIf
  If bestBit >= 0 And bestBin >= 0 And runs(bestBit)\speed > 0.0
    rel = runs(bestBin)\speed / runs(bestBit)\speed
    summary + "Binomial vs bit-exact: " + FormatNumber(rel, 2, ".", ",") + "x faster by best run" + #LF$
  EndIf
  If bestAccuracyModel >= 0
    summary + "Best max-sigma fit: " + CompactAnalysisMode(models(bestAccuracyModel)\mode, 28)
    summary + " | avg error " + FormatNumber(models(bestAccuracyModel)\sumAbsSigmaError / models(bestAccuracyModel)\fitCount, 2, ".", ",") + "s"
    summary + " | in range " + Str(models(bestAccuracyModel)\inExpectedRange) + "/" + Str(models(bestAccuracyModel)\fitCount) + #LF$
  Else
    summary + "Accuracy fit: not available; no expected max sigma was logged." + #LF$
  EndIf

  If modelCount = 1
    summary + "MODEL SUMMARY" + #LF$
  Else
    summary + "MODEL COMPARISON" + #LF$
  EndIf
  summary + "Graph = selected/not selected" + #LF$
  summary + PadRight("Model", 20) + PadLeft("N", 3) + " " + PadLeft("Avg", 8) + " " + PadLeft("Best", 8) + " " + PadLeft("Slow", 8) + " " + PadLeft("Max", 6) + " " + PadLeft("Fit", 6) + " " + PadLeft("Graph", 7) + #LF$
  summary + PadRight("-----", 20) + PadLeft("-", 3) + " " + PadLeft("---", 8) + " " + PadLeft("----", 8) + " " + PadLeft("----", 8) + " " + PadLeft("---", 6) + " " + PadLeft("---", 6) + " " + PadLeft("sel/not", 7) + #LF$

  Protected Dim modelUsed.i(modelCount - 1)
  Protected modelRank.i
  Protected modelCandidate.i
  For modelRank = 1 To modelCount
    modelCandidate = -1
    For i = 0 To modelCount - 1
      If modelUsed(i) = 0
        If modelCandidate < 0 Or (models(i)\sumSpeed / models(i)\count) > (models(modelCandidate)\sumSpeed / models(modelCandidate)\count)
          modelCandidate = i
        EndIf
      EndIf
    Next

    If modelCandidate >= 0
      modelUsed(modelCandidate) = 1
      avgSpeed = models(modelCandidate)\sumSpeed / models(modelCandidate)\count
      fitText = "-"
      If models(modelCandidate)\sigmaCount > 0
        sigmaText = FormatNumber(models(modelCandidate)\sumSigma / models(modelCandidate)\sigmaCount, 2, ".", ",") + "s"
      Else
        sigmaText = "-"
      EndIf
      If models(modelCandidate)\fitCount > 0
        fitText = FormatNumber(models(modelCandidate)\sumAbsSigmaError / models(modelCandidate)\fitCount, 2, ".", ",") + "s"
      EndIf
      graphDisplayText = "-"
      If models(modelCandidate)\graphOnCount > 0 Or models(modelCandidate)\graphOffCount > 0
        graphDisplayText = Str(models(modelCandidate)\graphOnCount) + "/" + Str(models(modelCandidate)\graphOffCount)
      EndIf
      summary + PadRight(CompactAnalysisMode(models(modelCandidate)\mode, 20), 20)
      summary + PadLeft(Str(models(modelCandidate)\count), 3) + " "
      summary + PadLeft(FormatCompactCfMs(avgSpeed), 8) + " "
      summary + PadLeft(FormatCompactCfMs(models(modelCandidate)\bestSpeed), 8) + " "
      summary + PadLeft(FormatCompactCfMs(models(modelCandidate)\worstSpeed), 8) + " "
      summary + PadLeft(sigmaText, 6) + " "
      summary + PadLeft(fitText, 6) + " "
      summary + PadLeft(graphDisplayText, 7)
      summary + #LF$
    EndIf
  Next

  summary + "RUN DETAILS" + #LF$
  ; Selection-sort style reporting keeps the original run array unchanged.
  Protected printed.i
  Protected rank.i
  Protected candidate.i
  Protected Dim used.i(runCount - 1)
  topLimit = runCount
  If topLimit > 12 : topLimit = 12 : EndIf
  For rank = 1 To topLimit
    candidate = -1
    For i = 0 To runCount - 1
      If used(i) = 0
        If candidate < 0 Or runs(i)\speed > runs(candidate)\speed
          candidate = i
        EndIf
      EndIf
    Next
    If candidate >= 0
      used(candidate) = 1
      summary + PadLeft(Str(rank) + ".", 3) + " " + PadRight(CompactAnalysisMode(runs(candidate)\mode, 20), 20)
      summary + " " + PadLeft(FormatCompactCfMs(runs(candidate)\speed), 8) + " cf/ms"
      summary + " | graph " + AnalysisGraphLabel(runs(candidate)\graphState)
      If runs(candidate)\elapsed <> ""
        summary + " | " + runs(candidate)\elapsed
      EndIf
      If runs(candidate)\hasSigma
        summary + " | " + FormatNumber(runs(candidate)\sigma, 2, ".", ",") + "s"
      EndIf
      summary + #LF$
      printed + 1
    EndIf
  Next
  If runCount > topLimit
    summary + "  ... " + Str(runCount - topLimit) + " more run"
    If runCount - topLimit <> 1 : summary + "s" : EndIf
    summary + #LF$
  EndIf

  If slowest >= 0 And best >= 0 And slowest <> best And runs(slowest)\speed > 0.0
    summary + "Spread: fastest run is " + FormatNumber(runs(best)\speed / runs(slowest)\speed, 2, ".", ",") + "x the slowest logged run."
  EndIf

  ProcedureReturn summary
EndProcedure

Procedure ShowLogAnalysis()
  Protected logText.s = GetGadgetText(#G_Log)
  Protected summary.s = BuildLogAnalysisSummary(logText)
  ShowTextDialog("Log analysis", summary, #ANALYSISDLG_W, #ANALYSISDLG_H)
EndProcedure

; =============================================================================
; Small helpers (GUI layout)
; =============================================================================
; =============================================================================
; Text dialog layout helper (documents/About/analysis)
; =============================================================================
Procedure ApplyTextDialogLayout(win.i, editorGadget.i, closeButton.i, copyButton.i = -1, saveButton.i = -1, appendButton.i = -1)
  Protected winW.i = WindowWidth(win)
  Protected winH.i = WindowHeight(win)

  Protected clientX.i = #TEXTDLG_MARGIN
  Protected clientY.i = #TEXTDLG_MARGIN
  Protected clientW.i = winW - (#TEXTDLG_MARGIN * 2)

  ; Button anchored bottom-right
  Protected btnW.i = #TEXTDLG_BTN_W
  Protected btnH.i = #TEXTDLG_BTN_H
  Protected btnX.i = winW - #TEXTDLG_MARGIN - btnW
  Protected btnY.i = winH - #TEXTDLG_MARGIN - btnH
  Protected copyW.i = #TEXTDLG_COPY_W
  Protected copyX.i
  Protected saveW.i = #TEXTDLG_SAVE_W
  Protected saveX.i
  Protected appendW.i = #TEXTDLG_APPEND_W
  Protected appendX.i

  ; Editor takes the remaining space above the button row
  Protected editorX.i = clientX
  Protected editorY.i = clientY
  Protected editorW.i = clientW
  Protected editorH.i = btnY - #TEXTDLG_MARGIN - editorY

  ResizeGadget(editorGadget, editorX, editorY, editorW, editorH)
  If copyButton >= 0 And IsGadget(copyButton)
    copyX = btnX - #TEXTDLG_MARGIN - copyW
    ResizeGadget(copyButton, copyX, btnY, copyW, btnH)
    If saveButton >= 0 And IsGadget(saveButton)
      saveX = copyX - #TEXTDLG_MARGIN - saveW
      ResizeGadget(saveButton, saveX, btnY, saveW, btnH)
      If appendButton >= 0 And IsGadget(appendButton)
        appendX = saveX - #TEXTDLG_MARGIN - appendW
        ResizeGadget(appendButton, appendX, btnY, appendW, btnH)
      EndIf
    EndIf
  ElseIf saveButton >= 0 And IsGadget(saveButton)
    saveX = btnX - #TEXTDLG_MARGIN - saveW
    ResizeGadget(saveButton, saveX, btnY, saveW, btnH)
    If appendButton >= 0 And IsGadget(appendButton)
      appendX = saveX - #TEXTDLG_MARGIN - appendW
      ResizeGadget(appendButton, appendX, btnY, appendW, btnH)
    EndIf
  EndIf
  ResizeGadget(closeButton, btnX, btnY, btnW, btnH)
EndProcedure

Procedure ConfigureAnalysisEditor(editorGadget.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected h.i = GadgetID(editorGadget)
    Protected style.i
    If h
      style = GetWindowLongPtr_(h, #GWL_STYLE)
      SetWindowLongPtr_(h, #GWL_STYLE, style | #WS_HSCROLL | #ES_AUTOHSCROLL)
      ; RichEdit word-wrap breaks padded tables badly. Use a wide target width
      ; so analysis lines stay intact and horizontal scrolling handles overflow.
      SendMessage_(h, #MSG_EM_SETTARGETDEVICE, 0, 1000000)
    EndIf
  CompilerEndIf
EndProcedure

Procedure ShowTextDialog(title.s, body.s, requestedW.i = #TEXTDLG_W, requestedH.i = #TEXTDLG_H)
  ; Simple modal text viewer for About and analysis summaries.
  ; Uses a read-only EditorGadget and a Close button.
  Protected win.i, ed.i, btn.i, copyBtn.i = -1, saveBtn.i = -1, appendBtn.i = -1
  Protected w.i = requestedW
  Protected h.i = requestedH
  Protected ev.i
  Protected i.i, lines.i, line.s
  Protected ww.i, hh.i
  Protected dialogFont.i
  Protected isAnalysis.i = Bool(title = "Log analysis")

  win = OpenWindow(#PB_Any, 0, 0, w, h, title, #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_Tool)
  If win = 0
    ProcedureReturn
  EndIf

; Compute initial dialog layout (locals)
Protected clientX.i = #TEXTDLG_MARGIN
Protected clientY.i = #TEXTDLG_MARGIN
Protected clientW.i = w - (#TEXTDLG_MARGIN * 2)

Protected btnW.i = #TEXTDLG_BTN_W
Protected btnH.i = #TEXTDLG_BTN_H
Protected btnX.i = w - #TEXTDLG_MARGIN - btnW
Protected btnY.i = h - #TEXTDLG_MARGIN - btnH
Protected copyW.i = #TEXTDLG_COPY_W
Protected copyX.i = btnX - #TEXTDLG_MARGIN - copyW
Protected saveW.i = #TEXTDLG_SAVE_W
Protected saveX.i = copyX - #TEXTDLG_MARGIN - saveW
Protected appendW.i = #TEXTDLG_APPEND_W
Protected appendX.i = saveX - #TEXTDLG_MARGIN - appendW

Protected edX.i = clientX
Protected edY.i = clientY
Protected edW.i = clientW
Protected edH.i = btnY - #TEXTDLG_MARGIN - edY

ed  = EditorGadget(#PB_Any, edX, edY, edW, edH, #PB_Editor_ReadOnly)
btn = ButtonGadget(#PB_Any, btnX, btnY, btnW, btnH, "Close")
If isAnalysis
  appendBtn = CheckBoxGadget(#PB_Any, appendX, btnY, appendW, btnH, "Append")
  SetGadgetState(appendBtn, gAppendAnalysisExports)
  GadgetToolTip(appendBtn, "Append saved analysis to an existing text file instead of replacing it.")
  saveBtn = ButtonGadget(#PB_Any, saveX, btnY, saveW, btnH, "Save")
  GadgetToolTip(saveBtn, "Save this analysis summary to a text file.")
  copyBtn = ButtonGadget(#PB_Any, copyX, btnY, copyW, btnH, "Copy")
  GadgetToolTip(copyBtn, "Copy this analysis summary.")
  dialogFont = LoadFont(#PB_Any, "Consolas", 9)
  If dialogFont
    SetGadgetFont(ed, FontID(dialogFont))
  EndIf
  ConfigureAnalysisEditor(ed)
  gAnalysisWindow = win
  gAnalysisOldProc = SetWindowLongPtr_(GadgetID(ed), #GWL_WNDPROC, @AnalysisWndProc())
EndIf
ApplyTextDialogLayout(win, ed, btn, copyBtn, saveBtn, appendBtn)

  ; Fill editor line-by-line
  lines = CountString(body, #LF$) + 1
  For i = 1 To lines
    line = StringField(body, i, #LF$)
    AddGadgetItem(ed, -1, line)
  Next
  If isAnalysis
    ConfigureAnalysisEditor(ed)
  EndIf

  SetActiveWindow(win)

  Repeat
    ev = WaitWindowEvent()
    If EventWindow() <> win
      ; ignore events for other windows while dialog is open
      Continue
    EndIf

    Select ev
      Case #PB_Event_CloseWindow
        Break

      Case #PB_Event_SizeWindow
        ApplyTextDialogLayout(win, ed, btn, copyBtn, saveBtn, appendBtn)

      Case #PB_Event_Menu
        If EventMenu() = #Menu_AnalysisCopy And isAnalysis
          CopyEditorSelectionOrAll(ed)
        EndIf

      Case #PB_Event_Gadget
        If EventGadget() = btn
          Break
        ElseIf isAnalysis And EventGadget() = appendBtn
          SetAppendAnalysisExports(GetGadgetState(appendBtn))
        ElseIf isAnalysis And EventGadget() = saveBtn
          SaveAnalysisToFile(body)
        ElseIf isAnalysis And EventGadget() = copyBtn
          SetClipboardText(body)
        ElseIf isAnalysis And EventGadget() = ed
          If EventType() = #PB_EventType_RightClick
            DisplayPopupMenu(2, WindowID(win))
          EndIf
        EndIf
    EndSelect
  ForEver

  If isAnalysis And gAnalysisOldProc
    SetWindowLongPtr_(GadgetID(ed), #GWL_WNDPROC, gAnalysisOldProc)
    gAnalysisOldProc = 0
    gAnalysisWindow = 0
  EndIf

  CloseWindow(win)
  If dialogFont
    FreeFont(dialogFont)
  EndIf
  If IsWindow(#WinMain)
    SetActiveWindow(#WinMain)
  EndIf
EndProcedure

; =============================================================
; Returns the default output file path used when "Save output file"
; is enabled and the Output Path field is empty.
;
; Stamp the filename with the program version so different
; builds do not overwrite each other's results.
; Example: Coinflip_<version>.data
; =============================================================
Procedure.s GetDefaultOutputFilePath()
  ProcedureReturn GetCurrentDirectory() + "Coinflip_" + #ProgramVersion$ + ".data"
EndProcedure

Procedure.s InstalledTextFilePath(fileName.s)
  Protected path.s = GetPathPart(ProgramFilename()) + fileName

  If FileSize(path) >= 0
    ProcedureReturn path
  EndIf

  path = GetCurrentDirectory() + fileName
  If FileSize(path) >= 0
    ProcedureReturn path
  EndIf

  ProcedureReturn ""
EndProcedure

Procedure OpenInstalledTextFile(fileName.s, title.s)
  Protected path.s = InstalledTextFilePath(fileName)

  If path = ""
    MessageRequester(title, fileName + " was not found beside the application.", #PB_MessageRequester_Warning)
    ProcedureReturn
  EndIf

  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If ShellExecute_(WindowID(#WinMain), "open", path, "", GetPathPart(path), #SW_SHOWNORMAL) <= 32
      MessageRequester(title, "Windows could not open this text file." + #LF$ + path, #PB_MessageRequester_Error)
    EndIf
  CompilerElse
    RunProgram(path)
  CompilerEndIf
EndProcedure

Procedure OpenUserManual()
  OpenInstalledTextFile("USER_MANUAL.txt", "User Manual")
EndProcedure

Procedure OpenReadme()
  OpenInstalledTextFile("README.txt", "README")
EndProcedure

Procedure OpenLicense()
  OpenInstalledTextFile("LICENSE.txt", "License")
EndProcedure

Procedure OpenThirdPartyNotices()
  OpenInstalledTextFile("THIRD_PARTY_NOTICES.txt", "Third-Party Notices")
EndProcedure

Procedure ShowAbout()
  Protected aboutText.s

  aboutText = "Coin-Flip Deviation Simulator " + #ProgramVersion$ + #LF$ +
              "PureBasic x64 | Multithreaded | GUI" + #LF$ +
              "" + #LF$ +
              "Overview" + #LF$ +
              "--------" + #LF$ +
              "This application analyzes deviation behavior in repeated fair-coin trials." + #LF$ +
              "Each sample computes |Heads - n/2| for a configured sample size n." + #LF$ +
              "" + #LF$ +
              "Computation Paths" + #LF$ +
              "-----------------" + #LF$ +
              "- BIT-EXACT path: random bit generation + high-performance popcount kernels" + #LF$ +
              "- BINOMIAL path: exact/approximate Binomial(n, 0.5) samplers" + #LF$ +
              "" + #LF$ +
              "Engineering Focus" + #LF$ +
              "-----------------" + #LF$ +
              "- Deterministic UI behavior during long-running workloads" + #LF$ +
              "- Persistent worker-pool lifecycle" + #LF$ +
              "- Buffered binary output for high throughput" + #LF$ +
              "- DPI-aware plotting and resizable layout" + #LF$ +
              "" + #LF$ +
              "Output Format" + #LF$ +
              "-------------" + #LF$ +
              "Coinflip_" + #ProgramVersion$ + ".data" + #LF$ +
              "Raw little-endian WORD stream (2 bytes per sample)." + #LF$ +
              "" + #LF$ +
              "Build Notes" + #LF$ +
              "-----------" + #LF$ +
              "- Target: Windows x64" + #LF$ +
              "- Enable PureBasic Thread Safe runtime" + #LF$ +
              "- Compile without debugger for benchmark-grade performance" + #LF$ +
              "" + #LF$ +
              "Author: John Torset" + #LF$ +
              "Program version: " + #ProgramVersion$

  ShowTextDialog("About", aboutText)
EndProcedure

Procedure UpdateViewMenuChecks()
  If IsMenu(0) = 0 : ProcedureReturn : EndIf

  SetMenuItemState(0, #Menu_ViewScale50,  Bool(gViewScalePct = 50))
  SetMenuItemState(0, #Menu_ViewScale75,  Bool(gViewScalePct = 75))
  SetMenuItemState(0, #Menu_ViewScale100, Bool(gViewScalePct = 100))
  SetMenuItemState(0, #Menu_ViewScale125, Bool(gViewScalePct = 125))
  SetMenuItemState(0, #Menu_ViewScale150, Bool(gViewScalePct = 150))
EndProcedure

Procedure ApplyViewScale(percent.i)
  gViewScalePct = NormalizeViewScale(percent)
  EnsureUiFontsForScale()
  UpdateViewMenuChecks()

  If IsWindow(#WinMain)
    ApplyLayout()
    UpdateMainWindowTitle()
    DrawProgressCanvas(uiLastProgressPercent, #True)
    gNeedPlotRedraw = 1
    UpdateDistributionPlot()
  EndIf

  SaveViewPreference()
EndProcedure

Procedure BuildMenuBar()
  If CreateMenu(0, WindowID(#WinMain))
    MenuTitle("Run")
      MenuItem(#Menu_RunStart, "Start")
      MenuItem(#Menu_RunStop,  "Stop")
      MenuItem(#Menu_RunReset, "Reset")
    MenuTitle("View")
      MenuItem(#Menu_ViewScale50,  "50%")
      MenuItem(#Menu_ViewScale75,  "75%")
      MenuItem(#Menu_ViewScale100, "100%")
      MenuItem(#Menu_ViewScale125, "125%")
      MenuItem(#Menu_ViewScale150, "150%")
    MenuTitle("Help")
      MenuItem(#Menu_HelpManual, "User Manual...")
      MenuItem(#Menu_HelpReadme, "README...")
      MenuItem(#Menu_HelpLicense, "License...")
      MenuItem(#Menu_HelpThirdParty, "Third-Party Notices...")
      MenuItem(#Menu_HelpAbout, "About...")
    UpdateViewMenuChecks()
  EndIf
EndProcedure

; Right-click context menus.
Procedure BuildPopupMenus()
  ; Popup menu id 1 is reserved for the log right-click menu.
  If CreatePopupMenu(1)
    MenuItem(#Menu_LogCopy, "Copy")
  EndIf
  ; Popup menu id 2 is reserved for the analysis dialog text.
  If CreatePopupMenu(2)
    MenuItem(#Menu_AnalysisCopy, "Copy")
  EndIf
EndProcedure

Procedure ResetToDefaults()
  ; Restore default settings from constants and clear progress fields.
  BeginUiRedrawBatch()
  SetGadgetText(#G_Instances, Str(#INSTANCES_TO_SIMULATE))
  SetGadgetText(#G_Runs, Str(#SIMULATION_RUNS))
  SetGadgetText(#G_Flips, Str(#FLIPS_NEEDED))
  SetGadgetText(#G_BufferMiB, Str(#BUFFER_SIZE / (1024*1024)))
  SetGadgetText(#G_LocalBatch, Str(#LOCAL_BATCH_SAMPLES))

  SetGadgetState(#G_SamplerMode, #SAMPLER_MODE)
  SetGadgetState(#G_BinomMethod, 0)
  SyncConfigurationSelectionCache()
  SetGadgetText(#G_BinomK, Str(#BINOMIAL_CLT_K))
  SetGadgetState(#G_ForceKernel, #FORCE_KERNEL)

  SetGadgetState(#G_SaveToFile, #SAVE_TO_FILE)
  SetGadgetText(#G_OutputPath, GetDefaultOutputFilePath())

  SetGadgetState(#G_ThreadPolicy, 0)
  SetGadgetText(#G_CustomThreads, Str(GetCpuCountCached() * GetCpuCountCached()))

  configuredPlotThreshold = #PLOT_THRESHOLD
  SetGadgetText(#G_PlotThreshold, Str(configuredPlotThreshold))
  lastPlotThresholdText = GetGadgetText(#G_PlotThreshold)

  loadedDataIsActive = 0
  loadedDataFilePath = ""

  ApplyConfigurationUIRules()
  ApplyPlotUIRules()
  UpdateDerivedInfo()

  progressPercent = 0
  nextThroughputLogMillis = 0
  flipsPerMillisecond = 0.0
  estimatedSecondsRemaining = 0.0
  maxDeviationAbsoluteOverall = 0
  maxDeviationPercentOverall = 0.0
  stopRequested = 0
  resetAfterStop = 0

  DrawProgressCanvas(0, #True)
  SetPlotStatusLine("Ready", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0, #True)

  ; Show a meaningful plot immediately (no disk I/O)
  LoadEmbeddedDeviationData()
  EndUiRedrawBatch()

  LogLine("Back to defaults.")
EndProcedure

Procedure RequestReset()
  If simulationIsRunning
    resetAfterStop = 1
    StopSimulation()
    LogLine("Reset queued (will apply after stop).")
  Else
    loadedDataIsActive = 0
    loadedDataFilePath = ""
    ResetToDefaults()
  EndIf
EndProcedure

; =============================================================================
; Live bell-curve plot support (based on DesktopCoinFlip.py)
; =============================================================================

Procedure ResetDeviationStats()
  ; Clear live stats shown in the distribution plot.
  deviationStatsCount = 0
  deviationStatsMean  = 0.0
  deviationStatsM2    = 0.0
  deviationStatsCountAtOrAboveThreshold = 0
  deviationStatsMaxValue = 0
  ResetPlotAboveThreshold()

EndProcedure

; ------------------------------------------------------------------------------
; Plot tick storage: keep the actual deviation values >= threshold (for blue tick marks)
; Note: Intended for rare events with a high threshold. Storage is capped.
; ------------------------------------------------------------------------------
Procedure ResetPlotAboveThreshold()
  plotAboveThresholdUsed = 0
  plotAboveThresholdTruncated = 0
EndProcedure

Procedure AppendPlotAboveValue(value.i)
  ; Caller is responsible for holding ioMutex if appending during a live run.
  If plotAboveThresholdUsed < #PLOT_ABOVE_TICKS_MAX
    If plotAboveThresholdUsed > ArraySize(plotAboveThresholdValues())
      Protected newSize.i = plotAboveThresholdUsed * 2 + 1024
      If newSize < 1024 : newSize = 1024 : EndIf
      If newSize > #PLOT_ABOVE_TICKS_MAX : newSize = #PLOT_ABOVE_TICKS_MAX : EndIf
      ReDim plotAboveThresholdValues.w(newSize - 1)
    EndIf
    plotAboveThresholdValues(plotAboveThresholdUsed) = value & $FFFF
    plotAboveThresholdUsed + 1
  Else
    plotAboveThresholdTruncated = 1
  EndIf
EndProcedure

Procedure AppendPlotAboveValues(*vals, count.i)
  Protected i.i, v.i
  If *vals = 0 Or count <= 0
    ProcedureReturn
  EndIf
  For i = 0 To count - 1
    v = PeekW(*vals + (i * 2)) & $FFFF
    AppendPlotAboveValue(v)
  Next
EndProcedure

Procedure MergeDeviationStats(batchCount.q, batchMean.d, batchM2.d, batchCountAboveThreshold.q, batchMaxValue.w)
  ; Merge one worker thread's batch stats into the global stats.
  ; Uses a parallel Welford merge (stable for very large sample counts).
  Protected total.q, delta.d

  If batchCount <= 0
    ProcedureReturn
  EndIf

  ; Track max value seen so far (highest deviation)
  If batchMaxValue > deviationStatsMaxValue
    deviationStatsMaxValue = batchMaxValue
  EndIf

  deviationStatsCountAtOrAboveThreshold + batchCountAboveThreshold

  If deviationStatsCount = 0
    deviationStatsCount = batchCount
    deviationStatsMean  = batchMean
    deviationStatsM2    = batchM2
    ProcedureReturn
  EndIf

  total = deviationStatsCount + batchCount
  delta = batchMean - deviationStatsMean

  deviationStatsMean = deviationStatsMean + delta * (batchCount / total)
  deviationStatsM2   = deviationStatsM2 + batchM2 + delta * delta * (deviationStatsCount * batchCount / total)
  deviationStatsCount = total
EndProcedure

; ============================================================================
; Plot drawing helpers (thick lines / thick frame)
; ============================================================================
Procedure DrawThickLineXY(x1.i, y1.i, x2.i, y2.i)
  ; Draw a "thick" line by painting several parallel lines (small offsets).
  ; Fast enough for the plot and avoids DPI artifacts.
  Protected r.i = (#PLOT_LINE_THICKNESS - 1) / 2
  Protected ox.i, oy.i
  If r <= 0
    LineXY(x1, y1, x2, y2)
  Else
    For ox = -r To r
      For oy = -r To r
        LineXY(x1 + ox, y1 + oy, x2 + ox, y2 + oy)
      Next
    Next
  EndIf
EndProcedure

Procedure DrawThickFrame(x.i, y.i, w.i, h.i)
  ; Draw a thicker rectangle outline by drawing nested frames.
  Protected i.i
  DrawingMode(#PB_2DDrawing_Outlined)
  For i = 0 To #PLOT_LINE_THICKNESS - 1
    Box(x + i, y + i, w - (2 * i), h - (2 * i))
  Next
EndProcedure

Procedure DrawDashedVLine(x.i, y1.i, y2.i, dashLen.i, gapLen.i)
  Protected y.i = y1
  Protected yEnd.i
  While y < y2
    yEnd = y + dashLen
    If yEnd > y2 : yEnd = y2 : EndIf
    DrawThickLineXY(x, y, x, yEnd)
    y + dashLen + gapLen
  Wend
EndProcedure

Procedure DrawDistributionPlot(mean.d, stdDev.d, maxValue.q, sampleCount.q, countAboveThreshold.q, *aboveVals, aboveCount.i, aboveTruncated.i)
  ; Draw a simplified version of DesktopCoinFlip.py:
  ; - Bell curve based on running mean/std-dev
  ; - Vertical dashed lines at maxValue (green) and threshold (red)
  ; - A stats box (placed in the upper half, above the blue reference line)
  ;
  ; DPI / resize correctness:
  ; Query the real canvas buffer size, draw into an off-screen image, then blit
  ; the completed frame to the canvas. This prevents flicker during clear/redraw.

  If IsGadget(#G_PlotCanvas) = 0 : ProcedureReturn : EndIf
  If GadgetType(#G_PlotCanvas) <> #PB_GadgetType_Canvas : ProcedureReturn : EndIf

  Protected w.i
  Protected h.i
  If StartDrawing(CanvasOutput(#G_PlotCanvas))
    w = OutputWidth()
    h = OutputHeight()
    StopDrawing()
  EndIf
  If w < 1 : w = 1 : EndIf
  If h < 1 : h = 1 : EndIf

  Protected bufferImage.i = CreateImage(#PB_Any, w, h, 32)
  If bufferImage = 0 : ProcedureReturn : EndIf

  If StartDrawing(ImageOutput(bufferImage))
    If gFontUi : DrawingFont(FontID(gFontUi)) : EndIf
    ; Always clear the full canvas first (prevents artifacts on resize).
    DrawingMode(#PB_2DDrawing_Default)
    Box(0, 0, w, h, RGB(255, 255, 255))
    ; Plot padding (room for title + labels + margins)
    ; Keep left and right padding identical so the plot is visually centered.
    ; A larger left margin makes the plot start too far right.
    Protected titleText.s = "Data Points (>= " + Str(configuredPlotThreshold) + ") and Bell Curve"
    Protected titleY.i = 4
    Protected titleBandH.i = TextHeight(titleText) + 8
    Protected lrPad.i = 10
    Protected left.i  = lrPad
    Protected right.i = lrPad
    Protected top.i = titleY + titleBandH
    If top < 26 : top = 26 : EndIf
    Protected bottom.i = 22

    Protected plotW.i = w - left - right
    Protected plotH.i = h - top - bottom

    ; Reserve enough space at the bottom so the bell-curve tail never overlaps the X-axis tick labels.
    ; Tick labels sit just above the bottom frame line; innerPadBottom includes tick height + text height.
    Protected tickLabelBand.i = #PLOT_TICK_HEIGHT + TextHeight("0") + 6
    ; --------------------------------------------------------------------------
    ; Inner drawing area (padding inside the frame)
    ; --------------------------------------------------------------------------
    ; The frame uses (left/top/plotW/plotH). To keep the bell curve from touching
    ; the frame borders, draw the curve and curve-dependent markers inside a
    ; slightly smaller vertical range:
    ;   - innerPadTop:    space above the peak (prevents touching the top border)
    ;   - innerPadBottom: space below the curve baseline (prevents touching bottom)
    ;
    ; Padding is a mix of:
    ;   - fixed minimum pixels (#PLOT_CURVE_PAD_*_MIN)
    ;   - a fraction of plot height (#PLOT_CURVE_PAD_FRAC)
    ;
    Protected innerPadTop.i    = #PLOT_CURVE_PAD_TOP_MIN
    Protected innerPadBottom.i = #PLOT_CURVE_PAD_BOTTOM_MIN
    Protected fracPad.i        = Int(plotH * #PLOT_CURVE_PAD_FRAC)
    If fracPad > innerPadTop    : innerPadTop = fracPad : EndIf
    If fracPad > innerPadBottom : innerPadBottom = fracPad : EndIf
    If tickLabelBand > innerPadBottom : innerPadBottom = tickLabelBand : EndIf
    ; Keep padding sane if the window is extremely small.
    If innerPadTop + innerPadBottom > plotH - 20
      innerPadTop = 10
      innerPadBottom = 10
    EndIf
    Protected innerH.i = plotH - innerPadTop - innerPadBottom
    If innerH < 20 : innerH = plotH : innerPadTop = 0 : innerPadBottom = 0 : EndIf

    If plotW < 60 Or plotH < 60
      StopDrawing()
      PresentBufferedCanvasImage(#G_PlotCanvas, bufferImage)
      ProcedureReturn
    EndIf

    ; Title (top-left)
    DrawingMode(#PB_2DDrawing_Transparent)
    FrontColor(RGB(0, 0, 0))
    DrawText(left, titleY, titleText)

    ; Status note (top-right)
    DrawingMode(#PB_2DDrawing_Transparent)
    FrontColor(RGB(70, 70, 70))
    If simulationIsRunning And liveGraphEnabled = 0
      DrawText(w - right - TextWidth("Live graph disabled (plot frozen for speed)") , titleY, "Live graph disabled (plot frozen for speed)")
    ElseIf loadedDataIsActive And loadedDataFilePath <> ""
      DrawText(w - right - TextWidth("Loaded: " + GetFilePart(loadedDataFilePath)), titleY, "Loaded: " + GetFilePart(loadedDataFilePath))
    EndIf

    ; Frame (thick)
    FrontColor(RGB(0, 0, 0))
    DrawThickFrame(left, top, plotW, plotH)

    ; Note: The curve is drawn inside (top+innerPadTop) .. (top+innerPadTop+innerH),
    ; while the frame uses the full plotH. This creates a clean margin to the borders.

    ; Not enough data yet?
    If sampleCount < 2 Or stdDev <= 0.0
      DrawingMode(#PB_2DDrawing_Transparent)
      FrontColor(RGB(90, 90, 90))
      DrawText(left + 10, top + 10, "Waiting for enough samples to estimate mean and std dev...")
      StopDrawing()
      PresentBufferedCanvasImage(#G_PlotCanvas, bufferImage)
      ProcedureReturn
    EndIf

    ; Determine x range (0 .. max(threshold, maxValue)) with enough right-side room for labels
    Protected xMin.d = 0.0
    Protected xMax.d = maxValue
    If xMax < configuredPlotThreshold : xMax = configuredPlotThreshold : EndIf
    If xMax < 1 : xMax = 1 : EndIf

    ; Ensure the green max-value label fits inside the right border:
    ; Expand xMax so the maxValue vertical line is far enough from the right edge.
    Protected maxLabelW.i = TextWidth(Str(maxValue))
    Protected needRightPx.i = maxLabelW + 12  ; 6 px offset + small padding
    If needRightPx < 20 : needRightPx = 20 : EndIf
    If plotW > 50
      Protected allowedFrac.d = 1.0 - (needRightPx / plotW)
      If allowedFrac < 0.80 : allowedFrac = 0.80 : EndIf
      Protected reqXMax.d = (maxValue - xMin) / allowedFrac + xMin
      If reqXMax > xMax : xMax = reqXMax : EndIf
    EndIf

    ; Small aesthetic margin after all adjustments
    xMax = xMax * 1.01

    ; Normal PDF peak for scaling (peak occurs at mean)
    Protected pi.d = 3.141592653589793
    Protected pdfPeak.d = 1.0 / (stdDev * Sqr(2.0 * pi))
    If pdfPeak <= 0.0 : pdfPeak = 1.0 : EndIf

    ; Draw bell curve (orange)
    DrawingMode(#PB_2DDrawing_Default)
    FrontColor(RGB(255, 165, 0))

    ; Curve sampling resolution:
    ; The X range can be large (up to threshold/max), but the peak is near the mean.
    ; With too few steps, the sampled polyline peak can sit noticeably below the
    ; true peak, and the "hanging" mean/+/-1 sigma markers will appear to start above
    ; the drawn curve. Use a higher step count tied to the
    ; plot width (and clamp to a reasonable range).
    Protected steps.i = plotW * 4
    If steps < 800  : steps = 800  : EndIf
    If steps > 6000 : steps = 6000 : EndIf

    Protected i.i
    Protected x.d, y.d
    Protected px.i, py.i
    Protected lastX.i = -1, lastY.i = -1

    For i = 0 To steps
      x = xMin + (xMax - xMin) * (i / steps)
      y = (1.0 / (stdDev * Sqr(2.0 * pi))) * Exp(-((x - mean) * (x - mean)) / (2.0 * stdDev * stdDev))

      px = left + Int((x - xMin) / (xMax - xMin) * plotW)
      ; Map PDF value to pixels inside the padded inner area (prevents border touch)
      py = top + innerPadTop + innerH - Int((y / pdfPeak) * innerH)

      If lastX >= 0
        DrawThickLineXY(lastX, lastY, px, py)
      EndIf
      lastX = px
      lastY = py
    Next

    ; Reference horizontal line (blue), roughly matching the Python example
    FrontColor(RGB(0, 0, 200))
    Protected refY.i = top + Int(plotH * 0.60)

    ; Keep the reference line within the visible canvas (plotH may be larger than h for better filling).
    If refY < top + 20 : refY = top + 20 : EndIf
    If refY > (top + h - bottom - 2) : refY = (top + h - bottom - 2) : EndIf

    ; Mean and +/-1 sigma "hanging" lines (black):
    ; Draw from the bell-curve point (orange curve) DOWN to the blue reference line.
    ; This visually shows where mean and +/-1 sigma sit on the distribution.
    Protected meanPix.i     = left + Int((mean - xMin) / (xMax - xMin) * plotW)
    Protected sdLeftVal.d   = mean - stdDev
    Protected sdRightVal.d  = mean + stdDev
    If sdLeftVal < xMin : sdLeftVal = xMin : EndIf
    If sdRightVal > xMax : sdRightVal = xMax : EndIf
    Protected sdLeftPix.i   = left + Int((sdLeftVal - xMin) / (xMax - xMin) * plotW)
    Protected sdRightPix.i  = left + Int((sdRightVal - xMin) / (xMax - xMin) * plotW)

    ; Compute the curve Y at those X positions (using the same PDF scaling as the drawn curve).
    ; With the higher step count above, the drawn polyline closely matches this analytic PDF,
    ; so the marker tops visually touch the orange curve as intended.
    Protected yMean.d    = pdfPeak
    Protected ySdLeft.d  = (1.0 / (stdDev * Sqr(2.0 * pi))) * Exp(-((sdLeftVal  - mean) * (sdLeftVal  - mean)) / (2.0 * stdDev * stdDev))
    Protected ySdRight.d = (1.0 / (stdDev * Sqr(2.0 * pi))) * Exp(-((sdRightVal - mean) * (sdRightVal - mean)) / (2.0 * stdDev * stdDev))

    Protected meanY.i    = top + plotH - Int((yMean    / pdfPeak) * plotH)
    Protected sdLeftY.i  = top + plotH - Int((ySdLeft  / pdfPeak) * plotH)
    Protected sdRightY.i = top + plotH - Int((ySdRight / pdfPeak) * plotH)

    ; Clamp to frame
    If meanPix < left : meanPix = left : EndIf
    If meanPix > left + plotW : meanPix = left + plotW : EndIf
    If sdLeftPix < left : sdLeftPix = left : EndIf
    If sdLeftPix > left + plotW : sdLeftPix = left + plotW : EndIf
    If sdRightPix < left : sdRightPix = left : EndIf
    If sdRightPix > left + plotW : sdRightPix = left + plotW : EndIf

    If meanY < top : meanY = top : EndIf
    If meanY > top + plotH : meanY = top + plotH : EndIf
    If sdLeftY < top : sdLeftY = top : EndIf
    If sdLeftY > top + plotH : sdLeftY = top + plotH : EndIf
    If sdRightY < top : sdRightY = top : EndIf
    If sdRightY > top + plotH : sdRightY = top + plotH : EndIf

    FrontColor(RGB(0, 0, 0))
    DrawingMode(#PB_2DDrawing_Default)

    ; Only draw "hanging" downwards (curve point above the blue reference line).
    ; Thick lines use +/-radius pixel offsets, so shift the
    ; starting Y down by radius so the topmost painted pixel aligns with the curve point.
    Protected thickRadius.i = (#PLOT_LINE_THICKNESS - 1) / 2

    If meanY + thickRadius < refY
      DrawThickLineXY(meanPix, meanY + thickRadius, meanPix, refY)
    EndIf

    If sdLeftY + thickRadius < refY
      DrawThickLineXY(sdLeftPix, sdLeftY + thickRadius, sdLeftPix, refY)
    EndIf

    If sdRightY + thickRadius < refY
      DrawThickLineXY(sdRightPix, sdRightY + thickRadius, sdRightPix, refY)
    EndIf

    DrawThickLineXY(left, refY, left + plotW, refY)

    ; Dark blue tick marks for each data point >= threshold (drawn on the midline).
    ; Uses the stored deviation values (rare events) captured during the run or load.
    If aboveCount > 0 And *aboveVals
      FrontColor(RGB(0, 0, 120))
      DrawingMode(#PB_2DDrawing_Default)
      Protected tickHalfH.i = #PLOT_ABOVE_TICK_HALF_H
      Protected *pTick = *aboveVals
      Protected j.i, vTick.i, xTick.i

      For j = 0 To aboveCount - 1
        vTick = PeekW(*pTick) & $FFFF
        *pTick + 2

        xTick = left + Int((vTick - xMin) / (xMax - xMin) * plotW)
        If xTick < left : xTick = left : EndIf
        If xTick > left + plotW : xTick = left + plotW : EndIf

        LineXY(xTick, refY - tickHalfH, xTick, refY + tickHalfH)
      Next
    EndIf

    ; Vertical dashed lines: threshold (red) and max (green)
    Protected xThresholdPix.i = left + Int((configuredPlotThreshold - xMin) / (xMax - xMin) * plotW)
    Protected xMaxPix.i       = left + Int((maxValue - xMin) / (xMax - xMin) * plotW)

    ; Clamp dashed line draw range to the visible canvas to avoid overdraw.
    Protected y1.i = top
    Protected y2.i = top + plotH
    Protected yMaxVisible.i = h - bottom
    If y2 > yMaxVisible : y2 = yMaxVisible : EndIf
    If y2 < y1 : y2 = y1 : EndIf

; Bottom axis tick marks (every #PLOT_TICK_STEP)
    ; Ticks are drawn on the bottom frame border. The bell curve baseline is
    ; slightly above this border due to innerPadBottom, so the curve never sits on the frame.
; Drawn on the bottom border line, with labels centered above each tick.
FrontColor(RGB(0, 0, 0))
DrawingMode(#PB_2DDrawing_Default)
Protected tickValue.i, tickX.i
Protected tickY1.i = y2
Protected tickY2.i = y2 - #PLOT_TICK_HEIGHT
Protected tickText.s, tickTextX.i, tickTextY.i
tickTextY = tickY2 - TextHeight("0") - 2

For tickValue = 0 To Int(xMax) Step #PLOT_TICK_STEP
  tickX = left + Int((tickValue - xMin) / (xMax - xMin) * plotW)

  ; tick mark
  DrawThickLineXY(tickX, tickY1, tickX, tickY2)

  ; centered label
  DrawingMode(#PB_2DDrawing_Transparent)
  tickText = Str(tickValue)
  tickTextX = tickX - (TextWidth(tickText) / 2)
  If tickTextX < left : tickTextX = left : EndIf
  If tickTextX > (left + plotW - TextWidth(tickText)) : tickTextX = (left + plotW - TextWidth(tickText)) : EndIf
  DrawText(tickTextX, tickTextY, tickText)
  DrawingMode(#PB_2DDrawing_Default)
Next

    ; Threshold line (red)
    FrontColor(RGB(200, 0, 0))
    DrawDashedVLine(xThresholdPix, y1, y2, 6, 4)

    ; Max line (green)
    FrontColor(RGB(0, 140, 0))
    DrawDashedVLine(xMaxPix, y1, y2, 6, 4)

    ; Labels near the top
    DrawingMode(#PB_2DDrawing_Transparent)
    Protected yLabel.i = top + 12

    FrontColor(RGB(0, 140, 0))
    Protected maxLabelStr.s = Str(maxValue)
    Protected maxLabelX.i = xMaxPix + 6
    If maxLabelX + TextWidth(maxLabelStr) > left + plotW - 2
      maxLabelX = left + plotW - 2 - TextWidth(maxLabelStr)
    EndIf
    If maxLabelX < left + 2 : maxLabelX = left + 2 : EndIf
    DrawText(maxLabelX, yLabel, maxLabelStr)

    FrontColor(RGB(200, 0, 0))
    Protected thrLabelStr.s = Str(configuredPlotThreshold)
    Protected thrLabelX.i = xThresholdPix - 6 - TextWidth(thrLabelStr)
    If thrLabelX < left + 2 : thrLabelX = left + 2 : EndIf
    If thrLabelX + TextWidth(thrLabelStr) > left + plotW - 2
      thrLabelX = left + plotW - 2 - TextWidth(thrLabelStr)
    EndIf
    DrawText(thrLabelX, yLabel, thrLabelStr)

    ; Stats box
    Protected stdFromMeanMax.d, stdFromMeanThreshold.d
    If stdDev > 0.0
      stdFromMeanMax = (maxValue - mean) / stdDev
      stdFromMeanThreshold = (configuredPlotThreshold - mean) / stdDev
    Else
      stdFromMeanMax = 0.0
      stdFromMeanThreshold = 0.0
    EndIf

    Protected freqRatio.d
    If countAboveThreshold > 0
      freqRatio = sampleCount / countAboveThreshold
    Else
      freqRatio = 0.0
    EndIf

    Protected Dim statsLine.s(7)
    statsLine(0) = "Total # of Data Points: " + FormatNumber(sampleCount, 0, ".", ",")
    statsLine(1) = "# of Data Points at or above " + Str(configuredPlotThreshold) + ": " + FormatNumber(countAboveThreshold, 0, ".", ",")
    statsLine(2) = "Mean: " + FormatNumber(mean, 2)
    statsLine(3) = "Std Dev: " + FormatNumber(stdDev, 2)
    statsLine(4) = "Max Value: " + Str(maxValue)
    statsLine(5) = Str(maxValue) + " is " + FormatNumber(stdFromMeanMax, 2) + " Std Dev from Mean"
    statsLine(6) = Str(configuredPlotThreshold) + " is " + FormatNumber(stdFromMeanThreshold, 2) + " Std Dev from Mean"
    statsLine(7) = "Frequency at or above " + Str(configuredPlotThreshold) + " = 1 : " + FormatNumber(freqRatio, 0, ".", ",")

    DrawingMode(#PB_2DDrawing_Default)
    Protected lineH.i = TextHeight("A")
    Protected lineCount.i = ArraySize(statsLine()) + 1
    Protected maxTextW.i = 0
    Protected tw.i

    ; Compute a tight stats box width based on the longest line (plus padding).
    ; This keeps the box readable without wasting horizontal space.
    For i = 0 To ArraySize(statsLine())
      tw = TextWidth(statsLine(i))
      If tw > maxTextW : maxTextW = tw : EndIf
    Next

    Protected boxW.i = maxTextW + 12  ; 6 px padding on each side
    Protected boxH.i = (lineH * lineCount) + 8

    If boxW > plotW - 12 : boxW = plotW - 12 : EndIf
    If boxW < 220 : boxW = 220 : EndIf

    ; Place the stats box in the upper half, centered horizontally, above the blue reference line.
; Place the stats box horizontally at a configurable fraction of the plot width.
; #PLOT_STATS_CENTER_X_FRAC = 0.5 -> centered, 0.333... -> one-third from the left.
Protected boxCenterX.i = left + Int(plotW * #PLOT_STATS_CENTER_X_FRAC) + #PLOT_STATS_OFFSET_X
Protected boxX.i = boxCenterX - (boxW / 2)
If boxX < left + 6 : boxX = left + 6 : EndIf
If boxX > left + plotW - boxW - 6 : boxX = left + plotW - boxW - 6 : EndIf
    Protected upperTop.i = top + 10
    Protected upperBottom.i = refY - 10
    Protected minBoxY.i = top + 6
    Protected maxBoxY.i = top + plotH - boxH - 6
    Protected boxY.i

    If upperBottom <= upperTop + boxH
      boxY = upperTop
    Else
      boxY = upperTop + (upperBottom - upperTop - boxH) / 2
    EndIf
    ; Final clamp: keep the stats panel inside the plot frame even when the
    ; graph is short or the blue reference line leaves little upper-half space.
    If maxBoxY < minBoxY : maxBoxY = minBoxY : EndIf
    If boxY < minBoxY : boxY = minBoxY : EndIf
    If boxY > maxBoxY : boxY = maxBoxY : EndIf

    Box(boxX, boxY, boxW, boxH, RGB(245, 245, 245))
    DrawingMode(#PB_2DDrawing_Outlined)
    Box(boxX, boxY, boxW, boxH, RGB(200, 200, 200))

    DrawingMode(#PB_2DDrawing_Transparent)
    FrontColor(RGB(0, 0, 0))
    For i = 0 To ArraySize(statsLine())
      DrawText(boxX + 6, boxY + 4 + i * lineH, statsLine(i))
    Next

    ; Grey-out overlay when Live graph is OFF.
    ; This keeps the plot readable but clearly indicates that live updates are disabled.
    If liveGraphEnabled = 0
      DrawingMode(#PB_2DDrawing_AlphaBlend)
      Box(left, top, plotW, plotH, RGBA(220, 220, 220, 120))
    EndIf

    StopDrawing()
    PresentBufferedCanvasImage(#G_PlotCanvas, bufferImage)
  Else
    FreeImage(bufferImage)
  EndIf
EndProcedure

Procedure UpdateDistributionPlot()
  ; Called by the GUI timer. Copy stats under lock and redraw the canvas.
  Protected mean.d, stdDev.d
  Protected count.q, countAbove.q
  Protected maxValue.q
  Protected variance.d

  Protected aboveCount.i, aboveTrunc.i
  Protected *aboveCopy
  If ioMutex
    LockMutex(ioMutex)
      count = deviationStatsCount
      mean  = deviationStatsMean
      countAbove = deviationStatsCountAtOrAboveThreshold
      maxValue = deviationStatsMaxValue
      aboveCount = plotAboveThresholdUsed
      aboveTrunc = plotAboveThresholdTruncated
      If aboveCount > 0
        *aboveCopy = AllocateMemory(aboveCount * 2)
        If *aboveCopy
          CopyMemory(@plotAboveThresholdValues(), *aboveCopy, aboveCount * 2)
        Else
          aboveCount = 0
        EndIf
      EndIf
      If deviationStatsCount > 0
        variance = deviationStatsM2 / deviationStatsCount  ; population variance, like NumPy std()
      Else
        variance = 0.0
      EndIf
    UnlockMutex(ioMutex)
  Else
    ; Before the first run starts, ioMutex may not exist yet.
    count = deviationStatsCount
    mean  = deviationStatsMean
    countAbove = deviationStatsCountAtOrAboveThreshold
    maxValue = deviationStatsMaxValue
      aboveCount = plotAboveThresholdUsed
      aboveTrunc = plotAboveThresholdTruncated
      If aboveCount > 0
        *aboveCopy = AllocateMemory(aboveCount * 2)
        If *aboveCopy
          CopyMemory(@plotAboveThresholdValues(), *aboveCopy, aboveCount * 2)
        Else
          aboveCount = 0
        EndIf
      EndIf
    If deviationStatsCount > 0
      variance = deviationStatsM2 / deviationStatsCount
    Else
      variance = 0.0
    EndIf
  EndIf

  If variance > 0.0
    stdDev = Sqr(variance)
  Else
    stdDev = 0.0
  EndIf

  DrawDistributionPlot(mean, stdDev, maxValue, count, countAbove, *aboveCopy, aboveCount, aboveTrunc)
  If *aboveCopy
    FreeMemory(*aboveCopy)
    *aboveCopy = 0
  EndIf
EndProcedure

Procedure ApplyLayout()
  ; Recompute all gadget rectangles based on current window size.
  Protected viewportW.i = WindowWidth(#WinMain, #PB_Window_InnerCoordinate)
  Protected viewportH.i = WindowHeight(#WinMain, #PB_Window_InnerCoordinate)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; PB's inner height includes the menu band here; Win32's client rect matches
    ; the actual coordinate space available to child gadgets.
    Protected winClient.WORKAREA_RECT
    If GetClientRect_(WindowID(#WinMain), @winClient)
      viewportW = PhysToPB_X(winClient\right - winClient\left)
      viewportH = PhysToPB_Y(winClient\bottom - winClient\top)
    EndIf
  CompilerEndIf
  If viewportW < 1 : viewportW = 1 : EndIf
  If viewportH < 1 : viewportH = 1 : EndIf

  Protected layoutViewportW.i = viewportW
  Protected layoutViewportH.i = viewportH
  ; Leave a one-unit guard against DPI rounding on the native ScrollArea frame.
  If layoutViewportW > 1 : layoutViewportW - 1 : EndIf
  If layoutViewportH > 1 : layoutViewportH - 1 : EndIf

  Protected oldScrollX.i = GetGadgetAttribute(#G_MainScroll, #PB_ScrollArea_X)
  Protected oldScrollY.i = GetGadgetAttribute(#G_MainScroll, #PB_ScrollArea_Y)

  Protected edgePadW.i = UiScaleXInt(#SCROLLAREA_EDGE_PAD)
  Protected edgePadH.i = UiScaleYInt(#SCROLLAREA_EDGE_PAD)
  Protected marginX.i = UiScaleXInt(#MARGIN)
  Protected marginY.i = UiScaleYInt(#MARGIN)
  Protected gapX.i = UiScaleXInt(#GAP_X)
  Protected gapY.i = UiScaleYInt(#GAP_Y)
  Protected titleH.i = UiScaleYInt(#TITLE_H)
  Protected rowH.i = UiScaleYInt(#ROW_H)
  Protected btnH.i = UiScaleYInt(#BTN_H)
  Protected smallBtnH.i = UiScaleYInt(#SMALLBTN_H)
  Protected inputW.i = UiScaleXInt(#INPUT_W)
  Protected browseW.i = UiScaleXInt(#BROWSE_W)
  Protected rightMinW.i = UiScaleXInt(#RIGHT_MIN_W)
  Protected logBtnW.i = UiScaleXInt(#LOG_BTN_W)
  Protected appendLogW.i = UiScaleXInt(76)
  Protected plotInfoLabelH.i = UiScaleYInt(#PLOTINFO_LABEL_H)
  Protected plotBarH.i = plotInfoLabelH + UiScaleYInt(2) + rowH
  Protected col1BaseW.i = UiScaleXInt(#COL1_W)
  Protected col2BaseW.i = UiScaleXInt(#COL2_W)
  Protected col1MinW.i = UiScaleXInt(#COL1_MIN_W)
  Protected col2MinW.i = UiScaleXInt(#COL2_MIN_W)
  Protected progH.i = UiScaleYInt(#PROG_H)
  Protected progLineGap.i = UiScaleYInt(#PROG_LINE_GAP)
  Protected plotCheckW.i = UiScaleXInt(#PLOT_CHECK_W)
  Protected plotLoadW.i = UiScaleXInt(#PLOT_LOAD_W)
  Protected plotThrLabelW.i = UiScaleXInt(#PLOT_THR_LABEL_W)
  Protected plotThrInputW.i = UiScaleXInt(#PLOT_THR_INPUT_W)
  Protected plotStatusMinW.i = UiScaleXInt(#PLOT_STATUS_MIN_W)
  Protected minLabelW.i = UiScaleXInt(#MIN_LABEL_W)
  Protected logMinH.i = UiScaleYInt(#LOG_MIN_H)
  Protected plotMinH.i = UiScaleYInt(#PLOT_MIN_HEIGHT)

  ; Keep layout math in PureBasic units. The scroll area loses a few usable pixels
  ; to its border, and scrollbars lose space only when they are actually needed.
  Protected viewportClientW.i = layoutViewportW - edgePadW
  Protected viewportClientH.i = layoutViewportH - edgePadH
  If viewportClientW < 1 : viewportClientW = 1 : EndIf
  If viewportClientH < 1 : viewportClientH = 1 : EndIf

  Protected minContentW.i = GetScaledMinimumContentWidth()

  Protected clientX.i = marginX
  Protected clientY.i = marginY

  ; ------------------------------------------------------------
  ; Vertical allocation:
  ;   Top: 3 columns (settings | policy | buttons+log)
  ;   Bottom: plot bar (controls + status) + plot canvas
  ; ------------------------------------------------------------
  If plotBarH < 0 : plotBarH = 0 : EndIf

  Protected minTopH.i = GetScaledMinimumTopHeight()

  ; Allocate vertical space:
  ; - Top area uses its minimum required height (minTopH).
  ; - Any extra height is given to the plot canvas (reduces unused blank space).
  Protected gapsH.i = gapY + plotBarH + gapY
  Protected minContentH.i = GetScaledMinimumContentHeight()

  Protected scrollBarW.i = 16
  Protected scrollBarH.i = 16
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    scrollBarW = PhysToPB_X(GetSystemMetrics_(#SM_CXVSCROLL))
    scrollBarH = PhysToPB_Y(GetSystemMetrics_(#SM_CYHSCROLL))
  CompilerEndIf
  If scrollBarW < 1 : scrollBarW = 16 : EndIf
  If scrollBarH < 1 : scrollBarH = 16 : EndIf

  Protected needHScroll.i = 0
  Protected needVScroll.i = 0
  If minContentW > viewportClientW : needHScroll = 1 : EndIf
  If minContentH > viewportClientH : needVScroll = 1 : EndIf
  If needVScroll And minContentW > viewportClientW - scrollBarW : needHScroll = 1 : EndIf
  If needHScroll And minContentH > viewportClientH - scrollBarH : needVScroll = 1 : EndIf

  Protected visibleContentW.i = viewportClientW
  Protected visibleContentH.i = viewportClientH
  If needVScroll : visibleContentW - scrollBarW : EndIf
  If needHScroll : visibleContentH - scrollBarH : EndIf
  If visibleContentW < 1 : visibleContentW = 1 : EndIf
  If visibleContentH < 1 : visibleContentH = 1 : EndIf

  Protected contentW.i = visibleContentW
  If contentW < minContentW : contentW = minContentW : EndIf
  Protected contentH.i = visibleContentH
  If contentH < minContentH : contentH = minContentH : EndIf

  Protected maxScrollX.i = contentW - visibleContentW
  Protected maxScrollY.i = contentH - visibleContentH
  If maxScrollX < 0 : maxScrollX = 0 : EndIf
  If maxScrollY < 0 : maxScrollY = 0 : EndIf
  If oldScrollX > maxScrollX : oldScrollX = maxScrollX : EndIf
  If oldScrollY > maxScrollY : oldScrollY = maxScrollY : EndIf
  If oldScrollX < 0 : oldScrollX = 0 : EndIf
  If oldScrollY < 0 : oldScrollY = 0 : EndIf

  BeginUiRedrawBatch()

  ResizeGadget(#G_MainScroll, 0, 0, layoutViewportW, layoutViewportH)

  Protected clientW.i = contentW - (marginX * 2)
  Protected clientH.i = contentH - (marginY * 2)
  If clientW < 1 : clientW = 1 : EndIf
  If clientH < 1 : clientH = 1 : EndIf
  clientX = marginX
  clientY = marginY

  ; The ScrollAreaGadget owns both native scrollbars. Keep the full inner size
  ; here so the horizontal and vertical bars match in look and behavior.
  SetGadgetAttribute(#G_MainScroll, #PB_ScrollArea_InnerWidth, contentW)
  SetGadgetAttribute(#G_MainScroll, #PB_ScrollArea_InnerHeight, contentH)
  SetGadgetAttribute(#G_MainScroll, #PB_ScrollArea_X, oldScrollX)
  SetGadgetAttribute(#G_MainScroll, #PB_ScrollArea_Y, oldScrollY)

  Protected availableForPlot.i = clientH - (minTopH + gapsH)

  Protected plotCanvasH.i
  Protected topH.i

  If availableForPlot >= plotMinH
    topH = minTopH
    plotCanvasH = availableForPlot
  Else
    plotCanvasH = availableForPlot
    If plotCanvasH < 0 : plotCanvasH = 0 : EndIf
    topH = clientH - (plotCanvasH + gapsH)
    If topH < 0 : topH = 0 : EndIf
  EndIf

  Protected topX.i = clientX
  Protected topY.i = clientY
  Protected topW.i = clientW

  ; ------------------------------------------------------------
  ; Horizontal allocation: 3 columns
  ; ------------------------------------------------------------
  Protected colGap.i = gapX

  ; Keep column 1 and 2 fixed (preferred widths). Column 3 absorbs horizontal resize.
  Protected col1W.i = col1BaseW
  Protected col2W.i = col2BaseW
  If col1W < col1MinW : col1W = col1MinW : EndIf
  If col2W < col2MinW : col2W = col2MinW : EndIf

  Protected col3W.i = topW - col1W - col2W - (colGap * 2)

  ; If the window is too narrow, shrink col2 then col1 (down to their minima).
  If col3W < rightMinW
    col3W = rightMinW
    col2W = topW - col1W - col3W - (colGap * 2)
    If col2W < col2MinW
      col2W = col2MinW
      col1W = topW - col2W - col3W - (colGap * 2)
      If col1W < col1MinW
        col1W = col1MinW
        col3W = topW - col1W - col2W - (colGap * 2)
        If col3W < rightMinW : col3W = rightMinW : EndIf
      EndIf
    EndIf
  EndIf

  Protected col1X.i = topX
  Protected col2X.i = col1X + col1W + colGap
  Protected col3X.i = col2X + col2W + colGap
  Protected colY.i  = topY

  ; ------------------------------------------------------------
  ; Column 1 (settings + sampler + binomial)
  ; ------------------------------------------------------------
  Protected inputW1.i = inputW
  Protected labelX1.i = col1X + inputW1 + gapX
  Protected labelW1.i = col1W - inputW1 - gapX
  If labelW1 < minLabelW : labelW1 = minLabelW : EndIf

  Protected y1.i = colY

  ResizeGadget(#G_LblSettings, col1X, y1, col1W, titleH) : y1 + titleH + gapY

  ResizeGadget(#G_Instances,    col1X, y1, inputW1, rowH)
  ResizeGadget(#G_LblInstances, labelX1, y1, labelW1, rowH) : y1 + rowH + gapY

  ResizeGadget(#G_Runs,    col1X, y1, inputW1, rowH)
  ResizeGadget(#G_LblRuns, labelX1, y1, labelW1, rowH) : y1 + rowH + gapY

  ResizeGadget(#G_Flips,    col1X, y1, inputW1, rowH)
  ResizeGadget(#G_LblFlips, labelX1, y1, labelW1, rowH) : y1 + rowH + gapY

  ResizeGadget(#G_BufferMiB,    col1X, y1, inputW1, rowH)
  ResizeGadget(#G_LblBufferMiB, labelX1, y1, labelW1, rowH) : y1 + rowH + gapY

  ResizeGadget(#G_LocalBatch,    col1X, y1, inputW1, rowH)
  ResizeGadget(#G_LblLocalBatch, labelX1, y1, labelW1, rowH) : y1 + rowH + gapY

  ResizeGadget(#G_LblSamplerHeader, col1X, y1, col1W, titleH) : y1 + titleH + gapY
  ResizeGadget(#G_SamplerMode, col1X, y1, col1W, rowH) : y1 + rowH + gapY

  ResizeGadget(#G_LblBinomHeader, col1X, y1, col1W, titleH) : y1 + titleH + gapY
  ResizeGadget(#G_BinomMethod, col1X, y1, col1W, rowH) : y1 + rowH + gapY

  ResizeGadget(#G_BinomK,    col1X, y1, inputW1, rowH)
  ResizeGadget(#G_LblBinomK, labelX1, y1, labelW1, rowH) : y1 + rowH + gapY

  ; ------------------------------------------------------------
  ; Column 2 (kernel + save + threads + derived)
  ; ------------------------------------------------------------
  Protected inputW2.i = inputW
  Protected labelX2.i = col2X + inputW2 + gapX
  Protected labelW2.i = col2W - inputW2 - gapX
  If labelW2 < minLabelW : labelW2 = minLabelW : EndIf

  Protected y2.i = colY

  ResizeGadget(#G_LblKernelHeader, col2X, y2, col2W, titleH) : y2 + titleH + gapY
  ResizeGadget(#G_ForceKernel, col2X, y2, col2W, rowH) : y2 + rowH + gapY

  ResizeGadget(#G_SaveToFile, col2X, y2, col2W, rowH) : y2 + rowH + gapY

  ResizeGadget(#G_OutputPath, col2X, y2, col2W - browseW - gapX, rowH)
  ResizeGadget(#G_BrowsePath, col2X + col2W - browseW, y2, browseW, rowH) : y2 + rowH + gapY

  ResizeGadget(#G_LblThreadHeader, col2X, y2, col2W, titleH) : y2 + titleH + gapY
  ResizeGadget(#G_ThreadPolicy, col2X, y2, col2W, rowH) : y2 + rowH + gapY

  ResizeGadget(#G_CustomThreads,    col2X, y2, inputW2, rowH)
  ResizeGadget(#G_LblCustomThreads, labelX2, y2, labelW2, rowH) : y2 + rowH + gapY

  ResizeGadget(#G_Derived, col2X, y2, col2W, (rowH * #DERIVED_ROWS)) : y2 + (rowH * #DERIVED_ROWS) + gapY

  ResizeGadget(#G_SepLine, 0, 0, 1, 1)

  ; Legacy progress text lines are hidden; progress now lives next to Start/Stop/Reset.
  ResizeGadget(#G_Prog2, 0, 0, 1, 1)
  ResizeGadget(#G_Prog3, 0, 0, 1, 1)
  ResizeGadget(#G_Prog4, 0, 0, 1, 1)

  ; ------------------------------------------------------------
  ; Column 3 (Start/Stop/Reset + progress bar, then log)
  ; ------------------------------------------------------------
  Protected y3.i = colY

  Protected btnGap.i = UiScaleXInt(6)
  Protected btnW.i = UiScaleXInt(70)
  Protected usedW.i = (btnW * 3) + (btnGap * 3) ; includes gap between Reset and progress
  Protected progW.i = col3W - usedW

  If progW < UiScaleXInt(80)
    btnW = (col3W - (btnGap * 3) - UiScaleXInt(80)) / 3
    If btnW < UiScaleXInt(60) : btnW = UiScaleXInt(60) : EndIf
    usedW = (btnW * 3) + (btnGap * 3)
    progW = col3W - usedW
    If progW < UiScaleXInt(60) : progW = UiScaleXInt(60) : EndIf
  EndIf

  ResizeGadget(#G_Start, col3X, y3, btnW, btnH)
  ResizeGadget(#G_Stop,  col3X + btnW + btnGap, y3, btnW, btnH)
  ResizeGadget(#G_Reset, col3X + (btnW + btnGap) * 2, y3, btnW, btnH)

  Protected progX.i = col3X + (btnW + btnGap) * 3
  Protected progY.i = y3 + (btnH - progH) / 2
  ResizeGadget(#G_Progress, progX, progY, progW, progH)
  y3 + btnH + gapY

  Protected logActionsW.i = (5 * logBtnW) + appendLogW + (5 * gapX)
  Protected logActionX.i = col3X + col3W - logActionsW
  Protected headerLabelW.i = col3W - logActionsW - gapX
  If headerLabelW < minLabelW : headerLabelW = minLabelW : EndIf

  ResizeGadget(#G_LblLogHeader, col3X, y3 + 2, headerLabelW, titleH)
  ResizeGadget(#G_LoadLog,     logActionX, y3, logBtnW, smallBtnH) : logActionX + logBtnW + gapX
  ResizeGadget(#G_SaveLog,     logActionX, y3, logBtnW, smallBtnH) : logActionX + logBtnW + gapX
  ResizeGadget(#G_AppendFiles, logActionX, y3, appendLogW, smallBtnH) : logActionX + appendLogW + gapX
  ResizeGadget(#G_AnalyseLog,  logActionX, y3, logBtnW, smallBtnH) : logActionX + logBtnW + gapX
  ResizeGadget(#G_ClearLog,    logActionX, y3, logBtnW, smallBtnH) : logActionX + logBtnW + gapX
  ResizeGadget(#G_CopyLog,     logActionX, y3, logBtnW, smallBtnH)

  Protected logY.i = y3 + smallBtnH + gapY
  Protected logH.i = (topY + topH) - logY
  If logH < logMinH : logH = logMinH : EndIf
  ResizeGadget(#G_Log, col3X, logY, col3W, logH)

  ; ------------------------------------------------------------
  ; Bottom: plot bar + plot canvas
  ; ------------------------------------------------------------
  Protected plotBarX.i = clientX
  Protected plotBarY.i = topY + topH + gapY
  Protected plotW.i = clientW

  If plotBarH > 0
    ; Two-line plot bar:
    ;   - a small label above the status line (ETA/Throughput/Max)
    ;   - the status line aligned with the Live graph / Load data controls
    Protected labelH.i  = plotInfoLabelH
    Protected statusY.i = plotBarY + labelH + UiScaleYInt(2)

    ; Keep the plot bar compact and stable across window sizes:
    ; [Live graph] [Load data...] [Threshold: ____] [Status label + status line]
    Protected checkW.i = plotCheckW
    Protected loadW.i = plotLoadW
    Protected thrLabelW.i = plotThrLabelW
    Protected thrInputW.i = plotThrInputW
    Protected fixedW.i = checkW + gapX + loadW + gapX + thrLabelW + gapX + thrInputW + gapX
    Protected plotInfoW.i = plotW - fixedW

    ; Narrow-window fallback: shrink control widths before status text collapses.
    If plotInfoW < plotStatusMinW
      checkW = UiScaleXInt(150) : loadW = UiScaleXInt(96) : thrLabelW = UiScaleXInt(64) : thrInputW = UiScaleXInt(80)
      fixedW = checkW + gapX + loadW + gapX + thrLabelW + gapX + thrInputW + gapX
      plotInfoW = plotW - fixedW
    EndIf
    If plotInfoW < 10 : plotInfoW = 10 : EndIf

    Protected loadX.i = plotBarX + checkW + gapX
    Protected thrLabelX.i = loadX + loadW + gapX
    Protected thrValueX.i = thrLabelX + thrLabelW + gapX
    Protected plotInfoX.i = thrValueX + thrInputW + gapX

    ResizeGadget(#G_LiveGraph,        plotBarX, statusY, checkW, rowH)
    ResizeGadget(#G_LoadData,         loadX, statusY, loadW, rowH)
    ResizeGadget(#G_LblPlotThreshold, thrLabelX, statusY, thrLabelW, rowH)
    ResizeGadget(#G_PlotThreshold,    thrValueX, statusY, thrInputW, rowH)
    ResizeGadget(#G_PlotInfoLabel,    plotInfoX, plotBarY, plotInfoW, labelH)
    ResizeGadget(#G_PlotInfo,         plotInfoX, statusY, plotInfoW, rowH)

    ; Ensure plot bar widgets stay above the plot canvas in Z-order.
    SetWindowPos_(GadgetID(#G_LiveGraph),        0, 0, 0, 0, 0, #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOACTIVATE)
    SetWindowPos_(GadgetID(#G_LoadData),         0, 0, 0, 0, 0, #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOACTIVATE)
    SetWindowPos_(GadgetID(#G_LblPlotThreshold), 0, 0, 0, 0, 0, #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOACTIVATE)
    SetWindowPos_(GadgetID(#G_PlotThreshold),    0, 0, 0, 0, 0, #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOACTIVATE)
    SetWindowPos_(GadgetID(#G_PlotInfoLabel),    0, 0, 0, 0, 0, #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOACTIVATE)
    SetWindowPos_(GadgetID(#G_PlotInfo),         0, 0, 0, 0, 0, #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOACTIVATE)

  Else
    ResizeGadget(#G_LiveGraph,        0, 0, 1, 1)
    ResizeGadget(#G_LoadData,         0, 0, 1, 1)
    ResizeGadget(#G_LblPlotThreshold, 0, 0, 1, 1)
    ResizeGadget(#G_PlotThreshold,    0, 0, 1, 1)
    ResizeGadget(#G_PlotInfoLabel,    0, 0, 1, 1)
    ResizeGadget(#G_PlotInfo,         0, 0, 1, 1)
  EndIf

  Protected plotCanvasY.i = plotBarY + plotBarH + gapY
  Protected plotCanvasH2.i = (clientY + clientH) - plotCanvasY
  If plotCanvasH2 < 0 : plotCanvasH2 = 0 : EndIf
  ResizeGadget(#G_PlotCanvas, clientX, plotCanvasY, plotW, plotCanvasH2)

  EndUiRedrawBatch()

  ; Redraw the progress bar after size/layout changes (Canvas does not auto-scale).
  DrawProgressCanvas(uiLastProgressPercent, #True)
  DrawPlotStatusCanvas(lastPlotStatusText, #True)
  DrawDerivedCanvas(uiDerivedCanvas\text, #True)
  DrawSepCanvas(uiSepCanvas\text, #True)
EndProcedure

Procedure ResizeUI()
  ; Compatibility wrapper for existing call sites.
  ApplyLayout()
EndProcedure

Procedure HandleFatal()
  Protected msg.s = fatalErrorMessage
  If msg = "" : msg = "Unknown fatal error." : EndIf
  LogLine("FATAL: " + msg)
  MessageRequester("Fatal error", msg, #PB_MessageRequester_Error)
  stopRequested = 1
  fatalErrorFlag = 0
EndProcedure

; =============================================================================
; Worker pool helpers
; =============================================================================

; Create (or rebuild) the worker pool if needed.
; Returns: 1 = OK, 0 = failed
Procedure.i EnsureWorkerPool(requestedCount.i)
  Protected i.i
  Protected createdCount.i
  Protected nowMs.q, nextUiMs.q

  If requestedCount < 1 : requestedCount = 1 : EndIf
  If requestedCount > #POOL_MAX_THREADS : requestedCount = #POOL_MAX_THREADS : EndIf

  ; Pool already matches the requested size
  If workerPoolCreated And workerPoolThreadCount = requestedCount And poolRunSemaphore And poolGoSemaphore And poolReadyAllSem And poolReadyMutex And poolTicketMutex
    ProcedureReturn 1
  EndIf

  ; Shut down existing pool (if any)
  If workerPoolCreated And poolRunSemaphore

    poolQuitFlag = 1

    ; Wake workers waiting for a run ticket
    For i = 0 To workerPoolThreadCount - 1
      SignalSemaphore(poolRunSemaphore)
    Next

    ; Also wake any workers that might be waiting at the GO barrier
    If poolGoSemaphore
      For i = 0 To workerPoolThreadCount - 1
        SignalSemaphore(poolGoSemaphore)
      Next
    EndIf

    ; Join
    For i = 0 To workerPoolThreadCount - 1
      If workerPoolThreadID(i)
        WaitThread(workerPoolThreadID(i))
        workerPoolThreadID(i) = 0
      EndIf
    Next

    ; Drain barrier semaphores (avoid leftover signals if pool is rebuilt)
    If poolGoSemaphore
      While TrySemaphore(poolGoSemaphore) : Wend
    EndIf
    If poolReadyAllSem
      While TrySemaphore(poolReadyAllSem) : Wend
    EndIf

    poolQuitFlag = 0
    workerPoolCreated = 0
    workerPoolThreadCount = 0
  EndIf

  ; Create semaphore/mutex objects if needed (once)
  If poolRunSemaphore = 0
    poolRunSemaphore = CreateSemaphore(0)
    If poolRunSemaphore = 0
      MessageRequester("Error", "CreateSemaphore() failed (worker pool).", #PB_MessageRequester_Error)
      ProcedureReturn 0
    EndIf
  EndIf

  If poolGoSemaphore = 0
    poolGoSemaphore = CreateSemaphore(0)
    If poolGoSemaphore = 0
      MessageRequester("Error", "CreateSemaphore() failed (pool GO).", #PB_MessageRequester_Error)
      ProcedureReturn 0
    EndIf
  EndIf

  If poolReadyAllSem = 0
    poolReadyAllSem = CreateSemaphore(0)
    If poolReadyAllSem = 0
      MessageRequester("Error", "CreateSemaphore() failed (pool READY).", #PB_MessageRequester_Error)
      ProcedureReturn 0
    EndIf
  EndIf

  If poolReadyMutex = 0
    poolReadyMutex = CreateMutex()
    If poolReadyMutex = 0
      MessageRequester("Error", "CreateMutex() failed (pool READY).", #PB_MessageRequester_Error)
      ProcedureReturn 0
    EndIf
  EndIf

  If poolTicketMutex = 0
    poolTicketMutex = CreateMutex()
    If poolTicketMutex = 0
      MessageRequester("Error", "CreateMutex() failed (worker pool).", #PB_MessageRequester_Error)
      ProcedureReturn 0
    EndIf
  EndIf

  workerPoolThreadCount = requestedCount
  createdCount = 0

  ; Throttled UI updates while building the pool (thread creation can be slow at large counts)
  nowMs = ElapsedMilliseconds()
  nextUiMs = nowMs + 1000

  If IsGadget(#G_PlotInfo)
    DrawPlotStatusCanvas("Creating worker pool... 0 / " + Str(workerPoolThreadCount), #True)
    While WindowEvent() : Wend
  EndIf

  For i = 0 To workerPoolThreadCount - 1
    workerPoolThreadID(i) = CreateThread(@CoinFlipWorkerLoop(), i)
    If workerPoolThreadID(i) = 0
      MessageRequester("Error", "CreateThread() failed while building the worker pool at thread " + Str(i) + ".", #PB_MessageRequester_Error)
      poolQuitFlag = 1
      ; Wake and join any threads already created.
      For createdCount = 0 To i - 1
        SignalSemaphore(poolRunSemaphore)
      Next
      If poolGoSemaphore
        For createdCount = 0 To i - 1
          SignalSemaphore(poolGoSemaphore)
        Next
      EndIf
      For createdCount = 0 To i - 1
        If workerPoolThreadID(createdCount)
          WaitThread(workerPoolThreadID(createdCount))
          workerPoolThreadID(createdCount) = 0
        EndIf
      Next
      poolQuitFlag = 0
      workerPoolCreated = 0
      workerPoolThreadCount = 0
      ProcedureReturn 0
    EndIf

    If IsGadget(#G_PlotInfo) And ElapsedMilliseconds() >= nextUiMs
      DrawPlotStatusCanvas("Creating worker pool... " + Str(i + 1) + " / " + Str(workerPoolThreadCount), #True)
      nextUiMs = ElapsedMilliseconds() + 1000
      While WindowEvent() : Wend
    EndIf
  Next

  workerPoolCreated = 1

  If IsGadget(#G_PlotInfo)
    DrawPlotStatusCanvas("Worker pool ready: " + Str(workerPoolThreadCount) + " threads", #True)
    While WindowEvent() : Wend
  EndIf

  ProcedureReturn 1
EndProcedure

; Shut down the worker pool cleanly (used on program exit).
Procedure ShutdownWorkerPool()
  Protected i.i

  If workerPoolCreated And poolRunSemaphore
    poolQuitFlag = 1
    For i = 0 To workerPoolThreadCount - 1
      SignalSemaphore(poolRunSemaphore)
    Next

    ; Also wake any workers that might be waiting at the GO barrier
    If poolGoSemaphore
      For i = 0 To workerPoolThreadCount - 1
        SignalSemaphore(poolGoSemaphore)
      Next
    EndIf
    For i = 0 To workerPoolThreadCount - 1
      If workerPoolThreadID(i)
        WaitThread(workerPoolThreadID(i))
        workerPoolThreadID(i) = 0
      EndIf
    Next

    poolQuitFlag = 0
    workerPoolCreated = 0
    workerPoolThreadCount = 0
  EndIf
EndProcedure

Procedure StartSimulation()
  Protected baseRandomSeed.q
  Protected i.i
  Protected bufMiB.q
  Protected plannedFlips.q
  Protected kernelName.s

  If simulationIsRunning
    ProcedureReturn
  EndIf

  stopRequested = 0
  fatalErrorFlag = 0
  fatalErrorMessage = ""
  workerThreadsFinished = 0

  resetAfterStop = 0
  ; Read settings
  configuredInstancesPerWorkBlock = ParseIntQFromGadget(#G_Instances, #INSTANCES_TO_SIMULATE)
  configuredWorkBlocksPerThread      = ParseIntQFromGadget(#G_Runs, #SIMULATION_RUNS)
  configuredFlipsPerSample         = ParseIntQFromGadget(#G_Flips, #FLIPS_NEEDED)

  If configuredInstancesPerWorkBlock < 1 : configuredInstancesPerWorkBlock = 1 : EndIf
  If configuredWorkBlocksPerThread < 1 : configuredWorkBlocksPerThread = 1 : EndIf
  If configuredFlipsPerSample < 1 : configuredFlipsPerSample = 1 : EndIf

  bufMiB = ParseIntQFromGadget(#G_BufferMiB, 100)
  If bufMiB < 1 : bufMiB = 1 : EndIf
  configuredOutputBufferSizeBytes = bufMiB * 1024 * 1024
  configuredOutputBufferWordCount = configuredOutputBufferSizeBytes / 2
  If configuredOutputBufferWordCount < 1 : configuredOutputBufferWordCount = 1 : EndIf

  configuredLocalBatchSamples = ParseIntQFromGadget(#G_LocalBatch, #LOCAL_BATCH_SAMPLES)
  If configuredLocalBatchSamples < 1 : configuredLocalBatchSamples = 1 : EndIf
  If configuredLocalBatchSamples > 65535 : configuredLocalBatchSamples = 65535 : EndIf

  configuredSamplerMode = GetGadgetState(#G_SamplerMode)
  If configuredSamplerMode < 0 : configuredSamplerMode = #SAMPLER_MODE : EndIf
  If configuredSamplerMode > 1 : configuredSamplerMode = #SAMPLER_MODE : EndIf

  configuredBinomialMethod = GetGadgetState(#G_BinomMethod)
  If configuredBinomialMethod < 0 Or configuredBinomialMethod > 3 : configuredBinomialMethod = 0 : EndIf

  configuredBinomialCltK = ParseIntQFromGadget(#G_BinomK, #BINOMIAL_CLT_K)
  If configuredBinomialCltK < 1 : configuredBinomialCltK = 1 : EndIf

  configuredKernelPolicy = GetGadgetState(#G_ForceKernel)

  isFileOutputEnabled = GetGadgetState(#G_SaveToFile)

  configuredThreadPolicy = GetGadgetState(#G_ThreadPolicy)
  Protected cpuCount.q = GetCpuCountCached()
  configuredCustomThreadCount = ParseIntQFromGadget(#G_CustomThreads, cpuCount * cpuCount)
  workerThreadCount = ResolveThreadCount(configuredThreadPolicy, configuredCustomThreadCount)

  ; Ensure worker pool matches the requested thread count before starting
  If EnsureWorkerPool(workerThreadCount) = 0
    FatalError("Failed to create worker pool (" + Str(workerThreadCount) + " threads).")
    ProcedureReturn
  EndIf

  workerThreadsTotal = workerThreadCount
  ; Pre-compute sigma and a rough 'expected max' for this many samples
  totalSamplesPlanned = workerThreadCount * configuredInstancesPerWorkBlock * configuredWorkBlocksPerThread
  sigmaHeads = Sqr(configuredFlipsPerSample * 0.25)
  ; Extreme-value rule of thumb for Max |deviation| over N samples:
  ; Treat |.| as two-sided => use M = 2*N. Use Gumbel-corrected normal max.
  If totalSamplesPlanned > 1
    Protected.d M = 2.0 * totalSamplesPlanned
    Protected.d a = Sqr(2.0 * Log(M))
    Protected.d b = a - (Log(Log(M)) + Log(4.0 * #PI_D)) / (2.0 * a)
    Protected.d scale = 1.0 / a
    Protected.d gamma = 0.5772156649015329 ; Euler-Mascheroni
    expectedMaxSigmaMean = b + gamma * scale
    expectedMaxSigmaP05   = b + (-Log(-Log(0.05))) * scale
    expectedMaxSigmaP95   = b + (-Log(-Log(0.95))) * scale
  Else
    expectedMaxSigmaMean = 0.0 : expectedMaxSigmaP05 = 0.0 : expectedMaxSigmaP95 = 0.0
  EndIf
  expectedMaxDeviationMeanHeads = expectedMaxSigmaMean * sigmaHeads
  expectedMaxDeviationP05Heads   = expectedMaxSigmaP05 * sigmaHeads
  expectedMaxDeviationP95Heads   = expectedMaxSigmaP95 * sigmaHeads

  ; CLT method has bounded tails: Z is bounded by +/-sqrt(3*K)
  If configuredSamplerMode = 1 And configuredBinomialMethod = 2
    sigmaTailCap = Sqr(3.0 * configuredBinomialCltK)
  Else
    sigmaTailCap = 0.0
  EndIf

  ; Resize output buffer
  ReDim outputDeviationWords.w(configuredOutputBufferWordCount - 1)
  outputDeviationWordsUsed = 0

  ; Reset shared progress
  completedWorkBlockCount = 0
  totalSamplesWritten = 0
  maxDeviationAbsoluteOverall = 0
  maxDeviationPercentOverall = 0.0
  flipsPerMillisecond = 0.0
  liveFlipsPerMillisecond = -1.0
  estimatedSecondsRemaining = -1.0
  nextThroughputLogMillis = 0
  throughputWindowPrevMillis = 0
  throughputWindowPrevSamples = 0
  throughputWindowEWMAFlipsPerMs = -1.0
  throughputWindowInitialized = 0
  progressPercent = 0

  ; Plot / distribution stats:
  ; - Live graph enabled: start fresh for the current run (clear old plot + loaded-file flag).
  ; - Live graph disabled (speed mode): keep the existing plot and loaded-file info visible.
  liveGraphEnabled = GetGadgetState(#G_LiveGraph)
  runLiveGraphEnabled = liveGraphEnabled

  If runLiveGraphEnabled
    loadedDataIsActive = 0
    loadedDataFilePath = ""
    ResetDeviationStats()
  EndIf

  ; Mutex
  If ioMutex = 0
    ioMutex = CreateMutex()
    fileMutex = CreateMutex()
  EndIf

  ; Kernel detection
  SetKernelModeFromForce()
  If kernelSelectionWarning <> ""
    LogLine(kernelSelectionWarning)
  EndIf

  ; Seed RNG
  If OpenCryptRandom()
    RandomSeed(CryptRandom($7FFFFFFF))
    baseRandomSeed = (CryptRandom($7FFFFFFF) << 32) + CryptRandom($7FFFFFFF)
  Else
    RandomSeed(Val(Str(Date())))
    baseRandomSeed = (Date() << 32) ! $A5A5A5A5A5A5A5A5
  EndIf

  For i = 0 To workerThreadCount - 1
    perThreadRngState(i) = InitThreadRngState(baseRandomSeed, i)
    rngSpare(i) = 0
    rngHasSpare(i) = 0
  Next

  ; Pre-init exact binomial engines (one-time tables for this n)
  If configuredSamplerMode = 1
    Select configuredBinomialMethod
      Case 0
        InitBinomialHalf_BTPE(configuredFlipsPerSample)
      Case 1
        InitBinomialHalf_BTRD(configuredFlipsPerSample)
      Case 3
        InitBinomialHalf_CPython(configuredFlipsPerSample)
    EndSelect
  EndIf

  ; Output file
  outputFilePath = Trim(GetGadgetText(#G_OutputPath))
  If outputFilePath = ""
    outputFilePath = GetDefaultOutputFilePath()
    SetGadgetText(#G_OutputPath, outputFilePath)
  EndIf

  If isFileOutputEnabled
    outputFile = CreateFile(#PB_Any, outputFilePath)
    If outputFile = 0
      MessageRequester("Error", "Failed to create output file." + #LF$ + ErrorMessage(), #PB_MessageRequester_Error)
      ProcedureReturn
    EndIf
  Else
    outputFile = 0
  EndIf

  ; Start
  simulationIsRunning = 1
  ApplyRunControlUI(#True)
  SetPlotStatusLine("Running", 0, -1.0, -1.0, -1.0, 0, 0.0, 0.0, #True)
  DrawProgressCanvas(0, #True)
  LogLine("---- Run " + #ProgramVersion$ + " ----")
  LogLine("System: " + ShortLogText(GetWindowsVersionString(), 80))
  LogLine("CPU: " + ShortLogText(GetCpuBrandString(), 80))
  plannedFlips = totalSamplesPlanned * configuredFlipsPerSample
  LogLine("Plan: " + FormatNumber(totalSamplesPlanned, 0, ".", ",") + " samples | " + FormatNumber(configuredFlipsPerSample, 0, ".", ",") + " cf/sample | threads " + Str(workerThreadCount))
  LogLine("Plan cf: " + FormatNumber(plannedFlips, 0, ".", ",") + " | " + FormatNamedCoinFlips(plannedFlips))

  If isFileOutputEnabled
    LogLine("Output: " + GetFilePart(outputFilePath) + " | 2 bytes/sample")
  Else
    LogLine("Output: off")
  EndIf
  If runLiveGraphEnabled
    LogLine("Graph: selected")
  Else
    LogLine("Graph: not selected")
  EndIf

  If sigmaHeads > 0.0
    If expectedMaxSigmaMean > 0.0
      LogLine("Stats: 1s=" + FormatNumber(sigmaHeads, 1) + " heads | expected max " + FormatNumber(expectedMaxSigmaMean, 2) + "s (" + FormatNumber(expectedMaxSigmaP05, 2) + ".." + FormatNumber(expectedMaxSigmaP95, 2) + "s)")
    Else
      LogLine("Stats: 1s=" + FormatNumber(sigmaHeads, 1) + " heads")
    EndIf
  EndIf

  If configuredSamplerMode = 0
    ; BIT-EXACT: generate random bits and count heads (real flip simulation)
    Select activeKernelSupportLevel
      Case 4 : kernelName = "AVX-512 VPOPCNTQ"
      Case 3 : kernelName = "AVX2 popcount"
      Case 2 : kernelName = "AVX popcount"
      Case 1 : kernelName = "POPCNT"
      Default: kernelName = "SWAR"
    EndSelect
    LogLine("Mode: BIT-EXACT | " + kernelName + kernelSelectionSuffix)
  Else
    ; BINOMIAL: sample number of heads directly (no bitstreams)
    Select configuredBinomialMethod
      Case 0
        LogLine("Mode: BINOMIAL | BTPE exact")
      Case 1
        LogLine("Mode: BINOMIAL | BTRD exact")
      Case 2
        If sigmaTailCap > 0.0
          LogLine("Mode: BINOMIAL | CLT K=" + Str(configuredBinomialCltK) + " | tail cap +/-" + FormatNumber(sigmaTailCap, 2) + "s")
        Else
          LogLine("Mode: BINOMIAL | CLT K=" + Str(configuredBinomialCltK))
        EndIf
      Case 3
        LogLine("Mode: BINOMIAL | CPython exact")
      Default
        LogLine("Mode: BINOMIAL | BTPE exact")
    EndSelect
  EndIf

  ; ---------------------------------------------------------------------------
  ; Accurate start timing (barrier):
  ; 1) Wake exactly poolActiveThreadCount workers on poolRunSemaphore
  ; 2) Each worker arms at the start line and increments poolReadyCount
  ; 3) When all are armed, main thread takes simulationStartMillis
  ; 4) Main thread signals poolGoSemaphore to release the hot loops
  ; ---------------------------------------------------------------------------

  poolActiveThreadCount = workerThreadCount

  ; Drain barrier semaphores (safety: avoid leftover signals).
  If poolGoSemaphore
    While TrySemaphore(poolGoSemaphore) : Wend
  EndIf
  If poolReadyAllSem
    While TrySemaphore(poolReadyAllSem) : Wend
  EndIf

  ; Reset ticket + barrier counters
  LockMutex(poolTicketMutex)
  poolRunTicket = 0
  UnlockMutex(poolTicketMutex)

  LockMutex(poolReadyMutex)
  poolReadyCount = 0
  UnlockMutex(poolReadyMutex)

  If IsGadget(#G_PlotInfo)
    SetPlotStatusLine("Starting workers", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0, #True)
    While WindowEvent() : Wend
  EndIf

  ; Wake exactly the number of workers that will participate in this run
  For i = 0 To workerThreadCount - 1
    SignalSemaphore(poolRunSemaphore)
  Next

  ; Wait until all participating workers are armed at the start line
  WaitSemaphore(poolReadyAllSem)

  ; Timestamp as close as possible to actual compute start
  simulationStartMillis = ElapsedMilliseconds()
  nextThroughputLogMillis = simulationStartMillis + #LOG_THROUGHPUT_INTERVAL_MS

  ; Release all armed workers simultaneously
  For i = 0 To workerThreadCount - 1
    SignalSemaphore(poolGoSemaphore)
  Next

  If IsGadget(#G_PlotInfo)
    SetPlotStatusLine("Running", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0, #True)
  EndIf
EndProcedure

Procedure FinalizeSimulation()
  Protected fileSize.q
  Protected elapsed.q
  Protected totalSamples.q
  Protected zFinal.d
  Protected totalFlips.q
  Protected avgFlipsPerMs.d

  If simulationIsRunning = 0
    ProcedureReturn
  EndIf

  ; Thread pool note:
  ; Workers are persistent and reused across runs, so do not WaitThread() here.
  ; At this point workerThreadsFinished >= workerThreadsTotal, so all workers have
  ; completed the run and are back waiting for the next start signal.

  ; Flush remaining buffer / close file
  If isFileOutputEnabled And outputFile
    LockMutex(fileMutex)
      FlushBuffer()
      fileSize = Lof(outputFile)
      CloseFile(outputFile)
      outputFile = 0
    UnlockMutex(fileMutex)
  Else
    fileSize = 0
  EndIf

  elapsed = ElapsedMilliseconds() - simulationStartMillis
  If elapsed < 1 : elapsed = 1 : EndIf

  ; Use actual completed samples for Stop, but the planned count for complete runs.
  ; The no-graph fast path publishes progress coarsely, so this keeps complete-run
  ; speed comparable across graph selected/not selected and all sampler methods.
  LockMutex(ioMutex)
    totalSamples = totalSamplesWritten
  UnlockMutex(ioMutex)

  Protected plannedSamples.q
  plannedSamples = workerThreadCount * configuredInstancesPerWorkBlock * configuredWorkBlocksPerThread
  If stopRequested = 0 And fatalErrorFlag = 0 And workerThreadsFinished >= workerThreadsTotal
    totalSamples = plannedSamples
  EndIf

  totalFlips = totalSamples * configuredFlipsPerSample
  avgFlipsPerMs = totalFlips / elapsed
  If sigmaHeads > 0.0
    zFinal = maxDeviationAbsoluteOverall / sigmaHeads
  Else
    zFinal = 0.0
  EndIf

  If totalSamples < plannedSamples
    LogLine("Finished: stopped early | elapsed " + FormatDuration(elapsed / 1000.0))
    LogLine("Done: " + FormatNumber(totalSamples, 0, ".", ",") + " / " + FormatNumber(plannedSamples, 0, ".", ",") + " samples")
    LogLine("Done cf: " + FormatNumber(totalFlips, 0, ".", ",") + " | " + FormatNamedCoinFlips(totalFlips))
  Else
    LogLine("Finished: complete | elapsed " + FormatDuration(elapsed / 1000.0))
  EndIf

  Protected maxLine.s = "Result: max " + Str(maxDeviationAbsoluteOverall) + " heads | " + FormatNumber(maxDeviationPercentOverall, 3) + "%"
  If sigmaHeads > 0.0
    maxLine + " | " + FormatNumber(zFinal, 2) + "s"
  EndIf
  LogLine(maxLine)
  LogLine("Speed: " + FormatCfMs(avgFlipsPerMs) + " | " + FormatNamedCoinFlipRate(avgFlipsPerMs))

  If sigmaHeads > 0.0
    If configuredSamplerMode = 1 And configuredBinomialMethod = 2 And sigmaTailCap > 0.0
      LogLine("CLT tail cap: +/-" + FormatNumber(sigmaTailCap, 2) + "s")
    EndIf
  EndIf

  If isFileOutputEnabled
    LogLine("Output: " + GetFilePart(outputFilePath) + " | " + FormatNumber(fileSize / (1024.0*1024.0), 2, ".", ",") + " MiB")
  EndIf

  simulationIsRunning = 0
  nextThroughputLogMillis = 0

  DrawProgressCanvas(100, #True)
  SetPlotStatusLine("Finished", 100, -1.0, avgFlipsPerMs, -1.0, maxDeviationAbsoluteOverall, maxDeviationPercentOverall, zFinal, #True)

  ; Final redraw of the distribution plot.
  ; If the user ran in "speed mode" (live graph disabled), this also removes the
  ; "plot frozen" overlay once the run is complete, while still keeping the same curve visible.
  UpdateDistributionPlot()

  ApplyRunControlUI(#False)

  ; If user requested reset while stopping, apply it now (after threads have joined)
  If resetAfterStop
    resetAfterStop = 0
    ResetToDefaults()
  EndIf

  ; If the user clicked the window close button while running and confirmed quit,
  ; close the window now that the run has been safely finalized.
  If quitAfterStop
    quitAfterStop = 0
    ; Some PureBasic versions require PostEvent() to be called with the full 5-parameter signature.
    ; Keep it explicit for maximum compatibility.
    PostEvent(#PB_Event_CloseWindow, #WinMain, 0, 0, 0)
  EndIf
EndProcedure

Procedure StopSimulation()
  If simulationIsRunning
    stopRequested = 1
    LogLine("Stop requested; finishing current batches.")
  EndIf
EndProcedure

Procedure CommitNumericInput(gadget.i)
  If simulationIsRunning
    ProcedureReturn
  EndIf

  Select gadget
    Case #G_CustomThreads
      If GetGadgetState(#G_ThreadPolicy) = 2
        ApplyThreadUIRules()
        UpdateDerivedInfo()
        UpdateDistributionPlot()
        While WindowEvent() : Wend
        If EnsureWorkerPool(workerThreadCount) = 0
          MessageRequester("Error", "Failed to create worker pool (" + Str(workerThreadCount) + " threads).", #PB_MessageRequester_Error)
        EndIf
      EndIf

    Case #G_PlotThreshold
      ApplyPlotUIRules()

    Case #G_Instances, #G_Runs, #G_Flips, #G_BufferMiB, #G_LocalBatch, #G_BinomK
      UpdateDerivedInfo()
  EndSelect
EndProcedure

Procedure BuildGUI()
  ; Create the main window and all gadgets.
  ;
  ; Layout Guide:
  ;   Edit the constants in the "Layout Guide (GUI)" section near the top.

  gBaseTitle = "Coin-Flip Deviation Simulator (GUI) " + #ProgramVersion$
  Protected winW_PB.i = PhysToPB_X(UiScaleXInt(#WIN_W))
  Protected winH_PB.i = PhysToPB_Y(UiScaleYInt(#WIN_H))
  Protected winFlags.i = #PB_Window_SystemMenu | #PB_Window_MinimizeGadget | #PB_Window_SizeGadget | #PB_Window_MaximizeGadget | #PB_Window_Invisible
  If OpenWindow(#WinMain, 0, 0, winW_PB, winH_PB, gBaseTitle, winFlags) = 0
    MessageRequester("Coinflip", "Could not create the main window.", #PB_MessageRequester_Error)
    End
  EndIf
  EnableStableChildRedrawHwnd(WindowID(#WinMain))
  SetWindowCallback(@MainWinCB(), #WinMain)

  ApplyMainWindowScaleBounds()
  ; Set the restored rectangle while hidden, then maximize while hidden before
  ; the first layout. Windows then chooses the correct monitor/work-area
  ; placement without showing a normal-size startup frame.
  SetMainWindowStartupFrame(winW_PB, winH_PB)
  UpdateMainWindowTitle()
  BuildMenuBar()
  BuildPopupMenus()
  EnsureUiFontsForScale()

  ; Create gadgets (positions will be set by ApplyLayout()).
  Protected initialInnerW_PB.i = GetScaledMinimumContentWidth()
  Protected initialInnerH_PB.i = winH_PB
  ScrollAreaGadget(#G_MainScroll, 0, 0, 1, 1, initialInnerW_PB, initialInnerH_PB, 16)
  EnableStableChildRedrawHwnd(GadgetID(#G_MainScroll))

  ButtonGadget(#G_Start, 0, 0, 1, 1, "Start")
  ButtonGadget(#G_Stop,  0, 0, 1, 1, "Stop")
  ButtonGadget(#G_Reset, 0, 0, 1, 1, "Reset")
  DisableGadget(#G_Stop, #True)

  CheckBoxGadget(#G_LiveGraph, 0, 0, 1, 1, "Live graph (slower)")
  SetGadgetState(#G_LiveGraph, 1) : liveGraphEnabled = 1
  ButtonGadget(#G_LoadData, 0, 0, 1, 1, "Load data...")
  TextGadget(#G_LblPlotThreshold, 0, 0, 1, 1, "Threshold:")
  StringGadget(#G_PlotThreshold, 0, 0, 1, 1, Str(configuredPlotThreshold))
  TextGadget(#G_PlotInfoLabel, 0, 0, 1, 1, "Live status:")
  CanvasGadget(#G_PlotInfo, 0, 0, 1, 1)
  ; Live status area: light yellow background with buffered drawing.
  SetGadgetColor(#G_PlotInfoLabel, #PB_Gadget_BackColor, RGB(255,255,192))

  ; Column 1 gadgets
  TextGadget(#G_LblSettings, 0, 0, 1, 1, "Settings")
  StringGadget(#G_Instances, 0, 0, 1, 1, Str(#INSTANCES_TO_SIMULATE))
  TextGadget(#G_LblInstances, 0, 0, 1, 1, "Instances / run-block")

  StringGadget(#G_Runs, 0, 0, 1, 1, Str(#SIMULATION_RUNS))
  TextGadget(#G_LblRuns, 0, 0, 1, 1, "Run-blocks / thread")

  StringGadget(#G_Flips, 0, 0, 1, 1, Str(#FLIPS_NEEDED))
  TextGadget(#G_LblFlips, 0, 0, 1, 1, "Flips / sample (n)")

  StringGadget(#G_BufferMiB, 0, 0, 1, 1, "100")
  TextGadget(#G_LblBufferMiB, 0, 0, 1, 1, "Output buffer (MiB)")

  StringGadget(#G_LocalBatch, 0, 0, 1, 1, Str(#LOCAL_BATCH_SAMPLES))
  TextGadget(#G_LblLocalBatch, 0, 0, 1, 1, "Local batch samples")

  TextGadget(#G_LblSamplerHeader, 0, 0, 1, 1, "Sampler")
  ComboBoxGadget(#G_SamplerMode, 0, 0, 1, 1)
  ClearGadgetItems(#G_SamplerMode)
  AddGadgetItem(#G_SamplerMode, -1, "0 = BIT-EXACT (bitstream + popcount)")
  AddGadgetItem(#G_SamplerMode, -1, "1 = BINOMIAL (sample heads)")
  SetGadgetState(#G_SamplerMode, #SAMPLER_MODE)

  TextGadget(#G_LblBinomHeader, 0, 0, 1, 1, "Binomial method (BINOMIAL only)")
  ComboBoxGadget(#G_BinomMethod, 0, 0, 1, 1)
  ClearGadgetItems(#G_BinomMethod)
  AddGadgetItem(#G_BinomMethod, -1, "0 = BTPE exact (recommended)")
  AddGadgetItem(#G_BinomMethod, -1, "1 = BTRD exact (alternative)")
  AddGadgetItem(#G_BinomMethod, -1, "2 = CLT K approx (slow / bounded)")
  AddGadgetItem(#G_BinomMethod, -1, "3 = CPython exact (BG+BTRS)")
  SetGadgetState(#G_BinomMethod, 0)
  SyncConfigurationSelectionCache()

  StringGadget(#G_BinomK, 0, 0, 1, 1, Str(#BINOMIAL_CLT_K))
  TextGadget(#G_LblBinomK, 0, 0, 1, 1, "CLT K (CLT only)")

  ; Column 2 gadgets
  TextGadget(#G_LblKernelHeader, 0, 0, 1, 1, "Kernel policy (BIT-EXACT only)")
  ComboBoxGadget(#G_ForceKernel, 0, 0, 1, 1)
  ClearGadgetItems(#G_ForceKernel)
    AddGadgetItem(#G_ForceKernel, -1, "0 = SWAR (portable)")
  AddGadgetItem(#G_ForceKernel, -1, "1 = POPCNT")
  AddGadgetItem(#G_ForceKernel, -1, "2 = AVX (128-bit PSHUFB popcount)")
  AddGadgetItem(#G_ForceKernel, -1, "3 = AVX2 (256-bit PSHUFB popcount)")
  AddGadgetItem(#G_ForceKernel, -1, "4 = AVX-512 VPOPCNTQ")
  AddGadgetItem(#G_ForceKernel, -1, "5 = Auto-detect")
  SetGadgetState(#G_ForceKernel, #FORCE_KERNEL)

  CheckBoxGadget(#G_SaveToFile, 0, 0, 1, 1, "Save output file")

  StringGadget(#G_OutputPath, 0, 0, 1, 1, GetDefaultOutputFilePath())
  ButtonGadget(#G_BrowsePath, 0, 0, 1, 1, "...")

  TextGadget(#G_LblThreadHeader, 0, 0, 1, 1, "Thread policy")
  ComboBoxGadget(#G_ThreadPolicy, 0, 0, 1, 1)
  ClearGadgetItems(#G_ThreadPolicy)
  AddGadgetItem(#G_ThreadPolicy, -1, "0 = CPUs^2 (default)")
  AddGadgetItem(#G_ThreadPolicy, -1, "1 = CPUs")
  AddGadgetItem(#G_ThreadPolicy, -1, "2 = Custom")
  SetGadgetState(#G_ThreadPolicy, 0)

  StringGadget(#G_CustomThreads, 0, 0, 1, 1, Str(GetCpuCountCached() * GetCpuCountCached()))
  TextGadget(#G_LblCustomThreads, 0, 0, 1, 1, "Custom threads (<=" + Str(#POOL_MAX_THREADS) + ")")
  DisableGadget(#G_CustomThreads, #True)

  CanvasGadget(#G_Derived, 0, 0, 1, 1)

  CanvasGadget(#G_SepLine, 0, 0, 1, 1)

  CanvasGadget(#G_Progress, 0, 0, 1, 1)

  TextGadget(#G_Prog2, 0, 0, 1, 1, "")
  TextGadget(#G_Prog3, 0, 0, 1, 1, "")
  TextGadget(#G_Prog4, 0, 0, 1, 1, "")
  HideGadget(#G_Prog2, #True)
  HideGadget(#G_Prog3, #True)
  HideGadget(#G_Prog4, #True)

  ; Log panel
  TextGadget(#G_LblLogHeader, 0, 0, 1, 1, "Run Log")
  ButtonGadget(#G_LoadLog, 0, 0, 1, 1, "Load")
  ButtonGadget(#G_SaveLog, 0, 0, 1, 1, "Save")
  CheckBoxGadget(#G_AppendFiles, 0, 0, 1, 1, "Append")
  SetGadgetState(#G_AppendFiles, gAppendLogExports)
  ButtonGadget(#G_AnalyseLog, 0, 0, 1, 1, "Analyse")
  ButtonGadget(#G_ClearLog, 0, 0, 1, 1, "Clear")
  ButtonGadget(#G_CopyLog,  0, 0, 1, 1, "Copy")
  EditorGadget(#G_Log, 0, 0, 1, 1, #PB_Editor_ReadOnly)

  ; Subclass the RichEdit behind EditorGadget so right-click reliably shows a context menu.
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    gLogOldProc = SetWindowLongPtr_(GadgetID(#G_Log), #GWL_WNDPROC, @LogWndProc())
  CompilerEndIf

  ; Plot
  CanvasGadget(#G_PlotCanvas, 0, 0, 1, 1)

  SubclassCommitEditGadgets()

  EnsureUiFontsForScale()

  CloseGadgetList()

  ; Timers / UI rules
  AddWindowTimer(#WinMain, #TIMER_UI, #TIMER_UI_MS)
  AddWindowTimer(#WinMain, #TIMER_PLOT, #TIMER_PLOT_MS)

  ApplyConfigurationUIRules()

  ; Reveal only after Windows has applied the maximized client size. The first
  ; hidden maximize can leave PB's client-size values at the restored size, so
  ; maximize again after reveal while redraw is suspended, then layout once from
  ; the real maximized client rectangle.
  BeginUiRedrawBatch()
  SetWindowState(#WinMain, #PB_Window_Maximize)
  HideWindow(#WinMain, #False)
  SetWindowState(#WinMain, #PB_Window_Maximize)
  ApplyLayout()
  UpdateDerivedInfo()
  SetPlotStatusLine("Ready", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0, #True)
  EndUiRedrawBatch()
  DrawProgressCanvas(uiLastProgressPercent, #True)
  ApplyPlotUIRules()

  ; Tooltips
  GadgetToolTip(#G_Instances, "Samples per run-block per thread. Press Enter or leave the field to update totals.")
  GadgetToolTip(#G_Runs, "Run-blocks per thread. Press Enter or leave the field to update totals.")
  GadgetToolTip(#G_Flips, "Flips per sample (n). Press Enter or leave the field to update totals.")
  GadgetToolTip(#G_BufferMiB, "Output writer buffer size in MiB. Press Enter or leave the field to commit.")
  GadgetToolTip(#G_LocalBatch, "Samples a worker processes before progress updates. Press Enter or leave the field to commit.")
  GadgetToolTip(#G_SamplerMode, "Choose BIT-EXACT (bitstream+popcount) or BINOMIAL (sample heads directly).")
  GadgetToolTip(#G_BinomMethod, "0=BTPE exact, 1=BTRD exact, 2=CLT K approx, 3=CPython exact.")
  GadgetToolTip(#G_BinomK, "CLT K: only used when Binomial method = 2 (CLT). Press Enter or leave the field to commit.")
  GadgetToolTip(#G_ForceKernel, "BIT-EXACT kernel policy (ignored when BINOMIAL).")
  GadgetToolTip(#G_SaveToFile, "Save deviations to a .data file (16-bit clamped).")
  GadgetToolTip(#G_OutputPath, "Output file path (used when Save output file is enabled).")
  GadgetToolTip(#G_BrowsePath, "Choose output file location.")
  GadgetToolTip(#G_ThreadPolicy, "How many worker threads to use.")
  GadgetToolTip(#G_CustomThreads, "Custom thread count. Press Enter or leave the field to rebuild the worker pool.")
  GadgetToolTip(#G_Derived, "Derived run size, output estimate, per-sample flips, and total formula.")
  GadgetToolTip(#G_Start, "Start the simulation.")
  GadgetToolTip(#G_Stop, "Request a graceful stop.")
  GadgetToolTip(#G_Reset, "Reset to defaults. If running, it will stop first, then reset.")
  GadgetToolTip(#G_Progress, "Overall progress (percent complete).")
  GadgetToolTip(#G_LoadLog, "Load a saved log text file into the log window.")
  GadgetToolTip(#G_SaveLog, "Save the current log to a text file.")
  GadgetToolTip(#G_AppendFiles, "When selected, log saves append to existing text files instead of replacing them.")
  GadgetToolTip(#G_AnalyseLog, "Analyse completed runs in the current log.")
  GadgetToolTip(#G_ClearLog, "Clear the log window.")
  GadgetToolTip(#G_CopyLog, "Copy log to the clipboard.")
  GadgetToolTip(#G_Log, "Run log and progress messages.")
  GadgetToolTip(#G_LiveGraph, "Enable/disable live plot updates during a run. Disable for max speed.")
  GadgetToolTip(#G_LoadData, "Load a saved .data file into the plot (only when stopped).")
  GadgetToolTip(#G_PlotThreshold, "Deviation threshold for plot marker and >= threshold counts. Press Enter or leave the field to commit.")
  GadgetToolTip(#G_PlotCanvas, "Deviation distribution plot (bell curve + markers).")
  GadgetToolTip(#G_PlotInfoLabel, "Live status label.")
  GadgetToolTip(#G_PlotInfo, "Live run summary: progress, ETA, throughput, and max deviation.")

EndProcedure

InitDpiScale()
LoadViewPreference()
BuildGUI()

; Initial plot on startup (embedded data, no disk I/O) - render before any heavy thread work
LoadEmbeddedDeviationData()
While WindowEvent() : Wend

; Create the worker pool at startup sized to the current thread policy
If EnsureWorkerPool(workerThreadCount) = 0
  MessageRequester("Error", "Failed to create worker pool (" + Str(workerThreadCount) + " threads).", #PB_MessageRequester_Error)
  End
EndIf

; 'Protected' is only valid inside procedures. Use Define in main scope.
Define ev.i

Repeat
  ev = WaitWindowEvent()

  Select ev

    Case #PB_Event_CloseWindow
      If simulationIsRunning
        If MessageRequester("Quit", "Simulation is running. Stop and exit?", #PB_MessageRequester_YesNo | #PB_MessageRequester_Warning) = #PB_MessageRequester_Yes
          quitAfterStop = 1
          StopSimulation()
          Continue
        Else
          Continue
        EndIf
      Else
        Break
      EndIf

    Case #PB_Event_SizeWindow
      ApplyLayout()
      UpdateMainWindowTitle()
      gNeedPlotRedraw = 1
      ; Redraw plot only when not in interactive move/resize (keeps sizing smooth).
      If gInSizeMove = 0
        ; Update compact live status (progress + ETA + throughput + max deviation).
        UpdateDistributionPlot()
      EndIf

    Case #PB_Event_Timer
  ; Fast UI timer: updates the numbers (progress, ETA, throughput).
  If EventTimer() = #TIMER_UI And simulationIsRunning
    Define nowMs.q = ElapsedMilliseconds()
    Define currentProgress.i = uiLastProgressPercent
    Define currentEta.d = estimatedSecondsRemaining
    Define currentThroughput.d = flipsPerMillisecond
    Define currentLiveThroughput.d = liveFlipsPerMillisecond
    Define currentMaxDeviation.q = maxDeviationAbsoluteOverall
    Define currentMaxPct.d = maxDeviationPercentOverall
    Define currentSamples.q
    Define currentFinished.i
    Define plannedSamples.q
    Define remainingSamples.q
    Define elapsedMs.q
    Define deltaMs.q
    Define deltaSamples.q
    Define instantThroughput.d
    Define zNow.d
    Define haveFreshStats.i = 0

    ; Keep UI responsive under heavy worker contention: skip this tick if mutex is busy.
    If TryLockMutex(ioMutex)
      currentSamples = totalSamplesWritten
      currentMaxDeviation = maxDeviationAbsoluteOverall
      currentMaxPct = maxDeviationPercentOverall
      currentFinished = workerThreadsFinished
      UnlockMutex(ioMutex)

      plannedSamples = totalSamplesPlanned
      If plannedSamples < 1 : plannedSamples = 1 : EndIf

      elapsedMs = nowMs - simulationStartMillis
      If elapsedMs < 1 : elapsedMs = 1 : EndIf

      currentProgress = Int((100.0 * currentSamples) / plannedSamples)
      If currentProgress < 0 : currentProgress = 0 : EndIf
      If currentProgress > 100 : currentProgress = 100 : EndIf

      ; True cumulative throughput from completed work only.
      currentThroughput = (currentSamples * configuredFlipsPerSample) / elapsedMs

      ; Short-window live speed (EWMA of per-tick throughput).
      If throughputWindowPrevMillis > 0 And nowMs > throughputWindowPrevMillis And currentSamples >= throughputWindowPrevSamples
        deltaMs = nowMs - throughputWindowPrevMillis
        deltaSamples = currentSamples - throughputWindowPrevSamples
        If deltaMs > 0
          instantThroughput = (deltaSamples * configuredFlipsPerSample) / deltaMs
          If throughputWindowInitialized = 0
            throughputWindowEWMAFlipsPerMs = instantThroughput
            throughputWindowInitialized = 1
          Else
            throughputWindowEWMAFlipsPerMs + #THROUGHPUT_EWMA_ALPHA_D * (instantThroughput - throughputWindowEWMAFlipsPerMs)
          EndIf
        EndIf
      EndIf
      throughputWindowPrevMillis = nowMs
      throughputWindowPrevSamples = currentSamples

      If throughputWindowInitialized
        currentLiveThroughput = throughputWindowEWMAFlipsPerMs
      Else
        currentLiveThroughput = -1.0
      EndIf

      ; Hide startup transients until enough elapsed time is available.
      If elapsedMs < #THROUGHPUT_MIN_ELAPSED_MS Or currentSamples <= 0
        currentThroughput = -1.0
        currentLiveThroughput = -1.0
        currentEta = -1.0
      Else
        remainingSamples = plannedSamples - currentSamples
        If remainingSamples < 0 : remainingSamples = 0 : EndIf

        If currentThroughput > 0.0
          currentEta = (remainingSamples * configuredFlipsPerSample) / (currentThroughput * 1000.0)
        Else
          currentEta = -1.0
        EndIf
      EndIf

      progressPercent = currentProgress
      flipsPerMillisecond = currentThroughput
      liveFlipsPerMillisecond = currentLiveThroughput
      estimatedSecondsRemaining = currentEta
      uiLastProgressPercent = currentProgress
      haveFreshStats = 1
    EndIf

    If gInSizeMove
      DrawProgressCanvas(uiLastProgressPercent)
    Else
      If haveFreshStats
        DrawProgressCanvas(uiLastProgressPercent)

        If sigmaHeads > 0.0
          zNow = currentMaxDeviation / sigmaHeads
        Else
          zNow = 0.0
        EndIf

        SetPlotStatusLine("Running", currentProgress, currentEta, currentThroughput, currentLiveThroughput, currentMaxDeviation, currentMaxPct, zNow)
      Else
        ; Mutex busy: keep last known UI values (no stalls).
        DrawProgressCanvas(uiLastProgressPercent)
      EndIf
    EndIf

    If haveFreshStats
      MaybeLogPeriodicThroughput(nowMs, currentProgress, currentEta, currentThroughput, currentLiveThroughput)
    EndIf

    If fatalErrorFlag
      HandleFatal()
    EndIf

    If haveFreshStats
      If currentFinished >= workerThreadsTotal
        FinalizeSimulation()
      EndIf
    Else
      If workerThreadsFinished >= workerThreadsTotal
        FinalizeSimulation()
      EndIf
    EndIf
  EndIf

  ; While stopped, refresh threshold-driven plot state as user types (no Enter required).
  If EventTimer() = #TIMER_UI And simulationIsRunning = 0
    Define thresholdText.s = GetGadgetText(#G_PlotThreshold)
    If thresholdText <> lastPlotThresholdText
      lastPlotThresholdText = thresholdText

      Define pendingThreshold.q = ParseIntQFromString(thresholdText, -1)
      If pendingThreshold >= 0
        pendingThreshold = ClampQ(pendingThreshold, 0, 65535)
        If pendingThreshold <> configuredPlotThreshold
          configuredPlotThreshold = pendingThreshold
          UpdateDistributionPlot()
        EndIf
      EndIf
    EndIf
  EndIf

  ; Slow plot timer: redraws the curve only every #PLOT_UPDATE_INTERVAL_MS.
  If EventTimer() = #TIMER_PLOT
    If gInSizeMove = 0
      If gNeedPlotRedraw
        gNeedPlotRedraw = 0
        UpdateDistributionPlot()
      ElseIf simulationIsRunning And liveGraphEnabled
        UpdateDistributionPlot()
      EndIf
    EndIf
  EndIf
    Case #PB_Event_Menu
      Select EventMenu()
        Case #Menu_RunStart
          StartSimulation()
        Case #Menu_RunStop
          StopSimulation()
        Case #Menu_RunReset
          RequestReset()
        Case #Menu_ViewScale50
          ApplyViewScale(50)
        Case #Menu_ViewScale75
          ApplyViewScale(75)
        Case #Menu_ViewScale100
          ApplyViewScale(100)
        Case #Menu_ViewScale125
          ApplyViewScale(125)
        Case #Menu_ViewScale150
          ApplyViewScale(150)
        Case #Menu_HelpManual
          OpenUserManual()
        Case #Menu_HelpReadme
          OpenReadme()
        Case #Menu_HelpLicense
          OpenLicense()
        Case #Menu_HelpThirdParty
          OpenThirdPartyNotices()
        Case #Menu_HelpAbout
          ShowAbout()
        Case #Menu_LogCopy
          CopyLogSelectionOrAll()
      EndSelect

    Case #PB_Event_Gadget
      Select EventGadget()
        Case #G_Start
          StartSimulation()

        Case #G_Stop
          StopSimulation()

        Case #G_Reset
          RequestReset()

        Case #G_AnalyseLog
          ShowLogAnalysis()

        Case #G_LoadLog
          LoadLogFromFile()

        Case #G_SaveLog
          SaveLogToFile()

        Case #G_AppendFiles
          SetAppendLogExports(GetGadgetState(#G_AppendFiles), #G_AppendFiles)

        Case #G_ClearLog
          ClearLogUI()

        Case #G_CopyLog
          CopyLogToClipboard()

        Case #G_Log
          ; Right-click opens a small context menu (Copy).
          If EventType() = #PB_EventType_RightClick
            DisplayPopupMenu(1, WindowID(#WinMain))
          EndIf
        Case #G_BrowsePath
          Define fn.s = SaveFileRequester("Select output file", GetGadgetText(#G_OutputPath), "Data (*.data)|*.data|All (*.*)|*.*", 0)
          If fn <> ""
            SetGadgetText(#G_OutputPath, fn)
          EndIf

        Case #G_SamplerMode
          HandleConfigurationComboChange(#G_SamplerMode, EventType())

        Case #G_BinomMethod
          HandleConfigurationComboChange(#G_BinomMethod, EventType())

        Case #G_ThreadPolicy
          ApplyThreadUIRules()
          UpdateDerivedInfo()
          If simulationIsRunning = 0
            ; Render plot first, then adjust the worker pool to the chosen policy.
            UpdateDistributionPlot()
            While WindowEvent() : Wend
            If EnsureWorkerPool(workerThreadCount) = 0
              MessageRequester("Error", "Failed to create worker pool (" + Str(workerThreadCount) + " threads).", #PB_MessageRequester_Error)
            EndIf
          EndIf

        Case #G_CustomThreads
          If IsCommitEditEvent(EventType(), EventData())
            CommitNumericInput(#G_CustomThreads)
          EndIf

        Case #G_PlotThreshold
          If IsCommitEditEvent(EventType(), EventData())
            CommitNumericInput(#G_PlotThreshold)
          EndIf

        Case #G_Instances, #G_Runs, #G_Flips, #G_BufferMiB, #G_LocalBatch, #G_BinomK
          If IsCommitEditEvent(EventType(), EventData())
            CommitNumericInput(EventGadget())
          EndIf

        Case #G_SaveToFile
          ApplySaveUIRules()
          UpdateDerivedInfo()

        Case #G_LiveGraph
          ; Toggle live plot updates:
          ; - ON  : collect stats and redraw every #PLOT_UPDATE_INTERVAL_MS
          ; - OFF : keep the current plot visible but frozen for maximum speed
          ApplyPlotUIRules()

        Case #G_LoadData
          ; Load a saved .data file into the plot (only when not running).
          If simulationIsRunning = 0
            Define fnLoad.s = OpenFileRequester("Load data file", GetGadgetText(#G_OutputPath), "Data (*.data)|*.data|All (*.*)|*.*", 0)
If fnLoad <> ""
  ; Mirror the Browse/Save behavior: update the Output Path field so both dialogs
  ; remember the same folder for next time.
  SetGadgetText(#G_OutputPath, fnLoad)
  LoadDeviationDataFile(fnLoad)
EndIf
          EndIf

        Default
          UpdateDerivedInfo()
      EndSelect

    Case #EventThreadFinished
      ; No-op: UI timer checks workerThreadsFinished and finalizes

    Case #EventFatal
      HandleFatal()

    Case #EventEditCommit
      CommitNumericInput(EventData())

  EndSelect

ForEver

ShutdownWorkerPool()

End
; IDE Options = PureBasic 6.40 (Windows - x64)
; CursorPosition = 189
; FirstLine = 180
; Folding = ----------------------
; Optimizer
; EnableAsm
; EnableThread
; DPIAware
; EnableXP
; UseIcon = Noto_Emoji_Coin.ico
; Executable = C:\Users\JT\Desktop\CoinFlips.exe
; DisableDebugger
; EnablePurifier
