; ================================================================================
; Coin-Flip Deviation Simulator (PureBasic x64, multi-threaded, file-backed)
; ================================================================================
; Author: John Torset
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
; For each sample we compute:
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
; AVX and AVX2 do NOT provide a native vector popcount instruction.
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
; - We generate a "normal-like" Z using the CLT trick: sum of K uniforms.
;     Z ~= ( (U1+...+UK) - K/2 ) * sqrt(12/K)
; - If K=12, sqrt(12/K)=1, and Z is bounded to [-6,+6] (because each Ui in [0,1)).
; - We then generate Heads ~= n/2 + Z * sqrt(n/4) and round to nearest integer.
;
; Consequences (important):
; - This is NOT bit-level randomness. It approximates the *binomial* distribution.
; - With K=12, far tails beyond ~6 sigma are truncated by construction.
;   That's actually useful here: with 115M samples you typically see maxima near ~6 sigma.


; =============================================================================
; Constants
; =============================================================================
#ProgramVersion$ = "V1.10"
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
; We use a mix of absolute minimum pixels and a small fraction of plot height.
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
; Source: Coinflip_V0.86.data (WORDs, little-endian)
; Values are deviations (|heads - n/2|) in "heads" units.
; -----------------------------------------------------------------------------
DataSection
  EmbeddedDeviationData:
    Data.w 192, 80, 66, 114, 146, 454, 44, 18, 143, 585, 35, 268
    Data.w 63, 166, 96, 156, 44, 88, 106, 528, 104, 515, 367, 167
EndDataSection

; Minimal embedded ONNX model (Identity graph) used only for ORT self-test.
DataSection
  EmbeddedOrtModel:
    Data.b 8,9,18,11,112,98,45,101,109,98,101,100,100,101,100,58
    Data.b 55,10,16,10,1,88,18,1,89,34,8,73,100,101,110,116,105,116
    Data.b 121,18,1,103,90,15,10,1,88,18,10,10,8,8,1,18,4,10,2,8
    Data.b 1,98,15,10,1,89,18,10,10,8,8,1,18,4,10,2,8,1,66,2,16,13
  EmbeddedOrtModelEnd:
EndDataSection

; =============================================================================
; Layout Guide (GUI)
; =============================================================================
; Change UI sizing/spacing from ONE place by editing the constants in this section.
; Common tweaks:
;   - Main window size:     #WIN_W, #WIN_H, #WIN_MIN_W, #WIN_MIN_H
;   - Left panel width:     #LEFT_W (and min clamps)
;   - Global spacing:       #MARGIN, #PAD, #GAP_X, #GAP_Y
;   - Row/button sizes:     #ROW_H, #BTN_H, #SMALLBTN_H
;   - Plot sizing:          #PLOT_BASE_HEIGHT, #PLOT_HEIGHT_MULTIPLIER, #PLOT_MIN_HEIGHT
; =============================================================================
#WIN_W         = 1920
#WIN_H         = 1200
#WIN_MIN_W     = 900
#WIN_MIN_H     = 700

#MARGIN         = 14     ; outer margin to window client area
#PAD            = 10     ; inner padding within panels (reserved)
#GAP_X          = 10      ; horizontal spacing between gadgets
#GAP_Y          = 8      ; vertical spacing between rows

#TITLE_H        = 20     ; section/header text height
#ROW_H          = 24     ; typical input row height (String/Combo/CheckBox)
#BTN_H          = 30     ; Start/Stop/Reset button height
#SMALLBTN_H     = 24     ; small button height (Clear/Copy/Load)
#SEP_H          = 6      ; separator canvas height

#INPUT_W       = 120    ; width of left-side numeric input fields
#BROWSE_W      = 38     ; width of the "..." browse button

#LEFT_W        = 640    ; desired left panel width
#LEFT_MIN_W    = 560
#RIGHT_MIN_W    = 320


#COL3_W        = 340    ; desired width of rightmost column (buttons+log)
#LOG_BTN_W     = 96    ; width of Clear/Copy buttons
#PLOTINFO_LABEL_H = 18     ; label above the ETA/Throughput line
#PLOT_BAR_H     = (#PLOTINFO_LABEL_H + 2 + #ROW_H) ; label + gap + status line

#TOPBAR_H      = #BTN_H ; top row containing Start/Stop/Reset + plot controls
#COL1_W        = 330    ; left settings column width (reduced)    ; left settings column width
#COL2_W        = 320    ; middle policy column width (fixed)
#COL1_MIN_W    = 300
#COL2_MIN_W    = 220
#TOP_MIN_H      = 620    ; minimum height reserved for the top panels (controls+log)
#DERIVED_ROWS   = 2      ; rows used for the derived-values text box
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



; Help/About text dialog sizing
#TEXTDLG_W      = 760
#TEXTDLG_H      = 700
#TEXTDLG_MARGIN = 10
#TEXTDLG_BTN_W  = 80
#TEXTDLG_BTN_H  = 24

#LOG_MAX_CHARS         = 1200000
#LOG_TRIM_TARGET_CHARS = 900000
#LOG_THROUGHPUT_INTERVAL_MS = 10000
#THROUGHPUT_MIN_ELAPSED_MS = 500      ; hide ETA/throughput during startup transients
#THROUGHPUT_EWMA_ALPHA_D  = 0.25     ; short-window live speed smoothing

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
EndEnumeration

Enumeration Windows
  #WinMain
EndEnumeration



Enumeration MenuItems
  #Menu_RunStart
  #Menu_RunStop
  #Menu_RunReset
  #Menu_HelpHelp
  #Menu_HelpAbout
  #Menu_LogCopy
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
; We keep a running mean + M2 (Welford) so std-dev is stable for huge sample counts.
; =============================================================================
Global deviationStatsCount.q
Global deviationStatsMean.d
Global deviationStatsM2.d
Global deviationStatsCountAtOrAboveThreshold.q
Global deviationStatsMaxValue.w

; Plot UI state:
Global liveGraphEnabled.i = 1              ; 1=live updates during run, 0=frozen for speed (plot stays visible)
Global loadedDataFilePath.s = ""           ; When a .data file is loaded (only when not running), this holds the path
Global lastPlotThresholdText.s = ""
Global loadedDataIsActive.i = 0            ; 1 if plot currently shows loaded file stats (not live run stats)

; Plot tick marks: store each deviation value >= threshold (capped, intended for rare events)
Global Dim plotAboveThresholdValues.w(0)
Global plotAboveThresholdUsed.i
Global plotAboveThresholdTruncated.i


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

; Workload shared across threads (so we do not pass pointers/structs)
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
Global liveFlipsPerMillisecond.d         ; short-window EWMA throughput (flips/ms)
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

; Optional embedded ONNX Runtime self-test (diagnostic only).
Global embeddedOrtLibraryHandle.i
Global embeddedOrtSelfTestState.i             ; 0=not attempted, 1=ok, -1=failed/unavailable
Global embeddedOrtSelfTestLogged.i
Global embeddedOrtSelfTestSummary.s


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

Structure OrtApiBase_Embedded
  *GetApi
  *GetVersionString
EndStructure

; Partial prefix of OrtApi, only as far as the one-time self-test needs.
Structure OrtApi_Min_Embedded
  *CreateStatus
  *GetErrorCode
  *GetErrorMessage
  *CreateEnv
  *CreateEnvWithCustomLogger
  *EnableTelemetryEvents
  *DisableTelemetryEvents
  *CreateSession
  *CreateSessionFromArray
  *Run
  *CreateSessionOptions
  *SetOptimizedModelFilePath
  *CloneSessionOptions
  *SetSessionExecutionMode
  *EnableProfiling
  *DisableProfiling
  *EnableMemPattern
  *DisableMemPattern
  *EnableCpuMemArena
  *DisableCpuMemArena
  *SetSessionLogId
  *SetSessionLogVerbosityLevel
  *SetSessionLogSeverityLevel
  *SetSessionGraphOptimizationLevel
  *SetIntraOpNumThreads
  *SetInterOpNumThreads
  *CreateCustomOpDomain
  *CustomOpDomain_Add
  *AddCustomOpDomain
  *RegisterCustomOpsLibrary
  *SessionGetInputCount
  *SessionGetOutputCount
EndStructure

Prototype.i ProtoOrtGetApiBase_Embedded()
Prototype.i ProtoOrtBaseGetApi_Embedded(version.l)
Prototype.i ProtoOrtBaseGetVersionString_Embedded()
Prototype.i ProtoOrtCreateEnv_Embedded(logLevel.l, logId.p-ascii, *outEnv)
Prototype.i ProtoOrtCreateSessionOptions_Embedded(*outOptions)
Prototype.i ProtoOrtCreateSessionFromArray_Embedded(*env, *modelData, modelDataLength.i, *options, *outSession)
Prototype.i ProtoOrtSessionGetInputCount_Embedded(*session, *outCount)
Prototype.i ProtoOrtSessionGetOutputCount_Embedded(*session, *outCount)
Prototype.i ProtoOrtGetErrorMessage_Embedded(*status)
Prototype ProtoOrtRelease_Embedded(*obj)

Procedure.s PeekAsciiZ_EmbeddedOrt(*p)
  If *p = 0
    ProcedureReturn ""
  EndIf
  ProcedureReturn PeekS(*p, -1, #PB_Ascii)
EndProcedure

Procedure.s EmbeddedOrtStatusMessage(*api.OrtApi_Min_Embedded, *status)
  Protected GetErrorMessage.ProtoOrtGetErrorMessage_Embedded
  Protected msg.s

  If *status = 0
    ProcedureReturn ""
  EndIf

  If *api
    GetErrorMessage = *api\GetErrorMessage
    If GetErrorMessage
      msg = PeekAsciiZ_EmbeddedOrt(GetErrorMessage(*status))
    EndIf
  EndIf

  If msg = ""
    msg = "(no error message available)"
  EndIf

  ProcedureReturn msg
EndProcedure

Procedure.i EnsureEmbeddedOrtSelfTest()
  Shared embeddedOrtLibraryHandle.i, embeddedOrtSelfTestState.i, embeddedOrtSelfTestSummary.s

  Protected lib.i
  Protected openedHere.i
  Protected apiVersion.i
  Protected inputCount.i
  Protected outputCount.i
  Protected modelBytes.i
  Protected runtimeVersion.s
  Protected statusText.s
  Protected canClose.i
  Protected *base.OrtApiBase_Embedded
  Protected *api.OrtApi_Min_Embedded
  Protected *env
  Protected *sessionOptions
  Protected *session
  Protected *status
  Protected *modelData
  Protected OrtGetApiBase.ProtoOrtGetApiBase_Embedded
  Protected GetApi.ProtoOrtBaseGetApi_Embedded
  Protected GetVersionString.ProtoOrtBaseGetVersionString_Embedded
  Protected CreateEnv.ProtoOrtCreateEnv_Embedded
  Protected CreateSessionOptions.ProtoOrtCreateSessionOptions_Embedded
  Protected CreateSessionFromArray.ProtoOrtCreateSessionFromArray_Embedded
  Protected SessionGetInputCount.ProtoOrtSessionGetInputCount_Embedded
  Protected SessionGetOutputCount.ProtoOrtSessionGetOutputCount_Embedded
  Protected ReleaseStatus.ProtoOrtRelease_Embedded
  Protected ReleaseEnv.ProtoOrtRelease_Embedded
  Protected ReleaseSessionOptions.ProtoOrtRelease_Embedded
  Protected ReleaseSession.ProtoOrtRelease_Embedded

  If embeddedOrtSelfTestState <> 0
    ProcedureReturn Bool(embeddedOrtSelfTestState > 0)
  EndIf

  lib = embeddedOrtLibraryHandle
  If lib = 0
    lib = OpenLibrary(#PB_Any, "onnxruntime.dll")
    If lib = 0
      embeddedOrtSelfTestSummary = "Embedded ONNX self-test unavailable (onnxruntime.dll not found)."
      embeddedOrtSelfTestState = -1
      ProcedureReturn #False
    EndIf
    openedHere = #True
    embeddedOrtLibraryHandle = lib
  EndIf

  OrtGetApiBase = GetFunction(lib, "OrtGetApiBase")
  If OrtGetApiBase = 0
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test unavailable (OrtGetApiBase export not found)."
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  *base = OrtGetApiBase()
  If *base = 0
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed (OrtGetApiBase returned NULL)."
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  GetApi = *base\GetApi
  GetVersionString = *base\GetVersionString
  If GetApi = 0 Or GetVersionString = 0
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test unavailable (OrtApiBase missing required methods)."
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  runtimeVersion = PeekAsciiZ_EmbeddedOrt(GetVersionString())
  If runtimeVersion = ""
    runtimeVersion = "unknown"
  EndIf

  For apiVersion = 25 To 1 Step -1
    *api = GetApi(apiVersion)
    If *api
      Break
    EndIf
  Next

  If *api = 0
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed (no supported OrtApi version found)."
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  CreateEnv = *api\CreateEnv
  CreateSessionOptions = *api\CreateSessionOptions
  CreateSessionFromArray = *api\CreateSessionFromArray
  SessionGetInputCount = *api\SessionGetInputCount
  SessionGetOutputCount = *api\SessionGetOutputCount

  If CreateEnv = 0 Or CreateSessionOptions = 0 Or CreateSessionFromArray = 0 Or SessionGetInputCount = 0 Or SessionGetOutputCount = 0
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test unavailable (OrtApi is missing required functions)."
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  ReleaseStatus = GetFunction(lib, "OrtReleaseStatus")
  ReleaseEnv = GetFunction(lib, "OrtReleaseEnv")
  ReleaseSessionOptions = GetFunction(lib, "OrtReleaseSessionOptions")
  ReleaseSession = GetFunction(lib, "OrtReleaseSession")

  *modelData = ?EmbeddedOrtModel
  modelBytes = ?EmbeddedOrtModelEnd - ?EmbeddedOrtModel
  If modelBytes <= 0
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed (embedded model is empty)."
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  *status = CreateEnv(2, "CoinflipEmbeddedORT", @*env)
  If *status
    statusText = EmbeddedOrtStatusMessage(*api, *status)
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed at CreateEnv: " + statusText
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  *status = CreateSessionOptions(@*sessionOptions)
  If *status
    statusText = EmbeddedOrtStatusMessage(*api, *status)
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed at CreateSessionOptions: " + statusText
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  *status = CreateSessionFromArray(*env, *modelData, modelBytes, *sessionOptions, @*session)
  If *status
    statusText = EmbeddedOrtStatusMessage(*api, *status)
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed at CreateSessionFromArray: " + statusText
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  *status = SessionGetInputCount(*session, @inputCount)
  If *status
    statusText = EmbeddedOrtStatusMessage(*api, *status)
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed at SessionGetInputCount: " + statusText
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  *status = SessionGetOutputCount(*session, @outputCount)
  If *status
    statusText = EmbeddedOrtStatusMessage(*api, *status)
    embeddedOrtSelfTestSummary = "Embedded ONNX self-test failed at SessionGetOutputCount: " + statusText
    embeddedOrtSelfTestState = -1
    Goto ort_selftest_done
  EndIf

  embeddedOrtSelfTestSummary = "Embedded ONNX self-test OK (ORT " + runtimeVersion + ", API " + Str(apiVersion) + ", " + Str(inputCount) + " in / " + Str(outputCount) + " out)."
  embeddedOrtSelfTestState = 1

ort_selftest_done:
  ; Some ORT builds do not export the standalone release helpers. Clean up when
  ; they exist; otherwise keep the DLL loaded for process lifetime and accept
  ; the tiny one-time diagnostic leak.
  If *status And ReleaseStatus
    ReleaseStatus(*status)
    *status = 0
  EndIf
  If *session And ReleaseSession
    ReleaseSession(*session)
    *session = 0
  EndIf
  If *sessionOptions And ReleaseSessionOptions
    ReleaseSessionOptions(*sessionOptions)
    *sessionOptions = 0
  EndIf
  If *env And ReleaseEnv
    ReleaseEnv(*env)
    *env = 0
  EndIf

  canClose = Bool(*env = 0 And *sessionOptions = 0 And *session = 0 And *status = 0)
  If openedHere And canClose
    CloseLibrary(lib)
    embeddedOrtLibraryHandle = 0
  EndIf

  ProcedureReturn Bool(embeddedOrtSelfTestState > 0)
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
; NOTE:
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
Declare StartSimulation()
Declare RequestReset()
Declare ShowHelp()
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


; ------------------------------------------------------------------------------
; Procedure: RandU01_Excl(threadIndex.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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

; ------------------------------------------------------------------------------
; Procedure: StirlingCorr(x.d)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure.d StirlingCorr(x.d)
  ; Stirling/de Moivre correction used by BTPE final acceptance test
  ; (13860 - (462 - (132 - (99 - 140/x^2)/x^2)/x^2)/x^2) / (x * 166320)
  Protected.d x2 = x * x
  Protected.d t  = (99.0 - 140.0 / x2) / x2
  t = (132.0 - t) / x2
  t = (462.0 - t) / x2
  t = 13860.0 - t
  ProcedureReturn t / x / 166320.0
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: InitBinomialHalf_BTPE(n.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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


; ------------------------------------------------------------------------------
; Procedure: BinomialHeads_BTPE_Exact(n.i, threadIndex.i, sigma.d)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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
; It is an exact Binomial(t, p) generator. In this program we always use p=0.5,
; but the code keeps the p<=0.5 symmetry so it stays correct if extended later.
;
; References:
; - Wolfgang Hormann (1993), "The generation of binomial random variates"
; - Boost: boost/random/binomial_distribution.hpp
;
; Notes:
; - For small mean (m < 11) we fall back to direct Bernoulli counting. This is exact,
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
    ; We'll keep that cutoff but use direct Bernoulli counting in that case.
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
; In this simulator p is fixed at 0.5, so symmetry is usually a no-op, but we
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
  ; We use precomputed log-factorials (exact for integer inputs).
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
        kernelSelectionWarning = "WARNING: Forced AVX-512 requested but unavailable. Falling back to auto-detected kernel level " + Str(detected) + "."
      EndIf

    Case 3
      If detectedSupportsAVX2
        activeKernelSupportLevel = 3
        kernelSelectionSuffix = " (forced AVX2)"
      Else
        activeKernelSupportLevel = detected
        kernelSelectionSuffix = " (forced AVX2 unavailable -> auto)"
        kernelSelectionWarning = "WARNING: Forced AVX2 requested but unavailable. Falling back to auto-detected kernel level " + Str(detected) + "."
      EndIf

    Case 2
      If detectedSupportsAVX
        activeKernelSupportLevel = 2
        kernelSelectionSuffix = " (forced AVX)"
      Else
        activeKernelSupportLevel = detected
        kernelSelectionSuffix = " (forced AVX unavailable -> auto)"
        kernelSelectionWarning = "WARNING: Forced AVX requested but unavailable. Falling back to auto-detected kernel level " + Str(detected) + "."
      EndIf

    Case 1
      If detectedSupportsPOPCNT
        activeKernelSupportLevel = 1
        kernelSelectionSuffix = " (forced POPCNT)"
      Else
        activeKernelSupportLevel = detected
        kernelSelectionSuffix = " (forced POPCNT unavailable -> auto)"
        kernelSelectionWarning = "WARNING: Forced POPCNT requested but unavailable. Falling back to auto-detected kernel level " + Str(detected) + "."
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

; Store one WORD into buffer; caller holds mutex (or call under mutex).
Procedure StoreWordInBuffer(value.i)
  Shared isFileOutputEnabled.i
  If isFileOutputEnabled = 0 : ProcedureReturn : EndIf
  outputDeviationWords(outputDeviationWordsUsed) = value
  outputDeviationWordsUsed + 1

  If outputDeviationWordsUsed >= configuredOutputBufferWordCount
    FlushBuffer()
  EndIf
EndProcedure

; Store a local batch of WORDs into buffer; caller holds mutex.
; Note: This avoids pointer copying. It uses a simple loop (fast enough at 512).
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


; ------------------------------------------------------------------------------
; Procedure: MaxIntValue(value1.i, value2.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure.i MaxIntValue(value1.i, value2.i)
  Protected mask.i
  mask = (value1 - value2) >> 63
  ProcedureReturn (value1 & ~mask) | (value2 & mask)
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: MaxDoubleValue(value1.d, value2.d)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure.d MaxDoubleValue(value1.d, value2.d)
  Protected diff.d, mask.d
  diff = value1 - value2
  mask = (diff / (Abs(diff) + 0.0000001) + 1) / 2
  ProcedureReturn value1 * mask + value2 * (1 - mask)
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: FormatDuration(seconds.d)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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


; ------------------------------------------------------------------------------
; Procedure: InitThreadRngState(base.q, threadIndex.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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
; - We emulate popcount by counting low/high nibbles via a 16-entry LUT.
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


; ------------------------------------------------------------------------------
; Procedure: Kernel_POPCNT_Tuned(arrayPtr.i, quadEnd.q)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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


; ------------------------------------------------------------------------------
; Procedure: Kernel_SWAR_Unroll8(Array randomQuadBuffer.q(1), quadEnd.q)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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

  ; Live distribution stats (per local flush batch, merged into global stats)
  Protected batchStatsCount.q
  Protected batchStatsMean.d
  Protected batchStatsM2.d
  Protected batchStatsCountAboveThreshold.q
  Protected batchStatsMaxValue.w
  Protected batchStatsValue.d
  Protected batchStatsDelta.d

  ; If the user disables the live graph during a run, we skip these stats to maximize speed.
  Protected plotCollectEnabled.i

  ; Plot tick marks: keep the actual deviation values >= threshold (per flush batch)
  Protected Dim localAbove.w(255)
  Protected localAboveCount.i

  Protected collectToBatch.i  ; 1 when we must store per-sample values (save file and/or live plot)
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
  Shared liveGraphEnabled.i


  flipsNeeded = configuredFlipsPerSample
  instancesToSimulate = configuredInstancesPerWorkBlock

  plotCollectEnabled = liveGraphEnabled

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

        plotCollectEnabled = liveGraphEnabled

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

      ; Add to local batch (only when we must store per-sample values)
      If collectToBatch
        localBatch(localCount) = absoluteDeviation
      EndIf
      localCount + 1

      ; Fast path: when not saving and live plot is OFF, avoid periodic flush/locks
      If collectToBatch
        ; Flush local batch periodically (reduces lock overhead)
        If (localCount >= localBatchSamples) Or stopRequested Or fatalErrorFlag
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
          plotCollectEnabled = liveGraphEnabled
          collectToBatch = Bool(isFileOutputEnabled Or plotCollectEnabled)

          If stopRequested Or fatalErrorFlag
            Goto thread_done
          EndIf
        EndIf
      Else
        ; Stop is rare, so only poll occasionally to avoid overhead
        If (localCount & 255) = 0
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

      plotCollectEnabled = liveGraphEnabled
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
  ; NOTE: Physical threadIndex is fixed at pool creation time (0..#POOL_MAX_THREADS-1).
  ; For each run we assign a *logical* thread index [0..poolActiveThreadCount-1]
  ; using a ticket, so we can start runs with any thread count without caring
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

    ; Robustness: in normal operation we signal exactly poolActiveThreadCount times,
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
EndEnumeration

#TIMER_UI      = 1
#TIMER_UI_MS   = 100
#TIMER_PLOT    = 2
#TIMER_PLOT_MS = #PLOT_UPDATE_INTERVAL_MS
Global NewList threadList.i()

; ----------------------------------------------------------------------------
; Window callback: detect interactive move/resize (for smooth UI)
; ----------------------------------------------------------------------------
#MSG_WM_ENTERSIZEMOVE = $0231
#MSG_WM_EXITSIZEMOVE  = $0232

#MSG_WM_COPY          = $0301
#MSG_EM_GETSEL        = $00B0

; Context-menu handling for the log (EditorGadget / RichEdit)
#MSG_WM_CONTEXTMENU   = $007B
#MSG_WM_NULL          = $0000
#GWL_WNDPROC          = -4
#TPM_RIGHTBUTTON      = $0002

Structure LOGPOINT
  x.l
  y.l
EndStructure

Global gLogOldProc.i


; SetWindowPos flags (local definitions for portability)
#SWP_NOSIZE      = $0001
#SWP_NOMOVE      = $0002
#SWP_NOZORDER    = $0004
#SWP_NOACTIVATE  = $0010

Global gInSizeMove.i
Global gNeedPlotRedraw.i
Global gBaseTitle.s


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

; ------------------------------------------------------------------------------
; DPI / scaling helpers (PB units <-> physical pixels)
; ------------------------------------------------------------------------------
; Goal:
; - Keep PureBasic's default GUI behavior where Windows DPI scaling affects the UI
;   (text/buttons scale with the user's DPI setting).
; - Allow #WIN_W/#WIN_H to be specified in *physical pixels* (e.g. 7680x2160).
; - Show physical pixel size in the window title.
;   When maximized, show the physical desktop resolution.
;
; How it works:
; - For a DPI-unaware process, GetDeviceCaps(HORZRES/VERTRES) returns the
;   virtualized (scaled) resolution, while DESKTOPHORZRES/DESKTOPVERTRES return
;   the physical pixel resolution.
; - scale = DESKTOPHORZRES / HORZRES  (and same for Y)
; - PB units = physical / scale
; ------------------------------------------------------------------------------
#GDC_HORZRES        = 8
#GDC_VERTRES        = 10
#GDC_DESKTOPHORZRES = 118
#GDC_DESKTOPVERTRES = 117

; GetSystemMetrics indices (for portability)
#SM_CXSCREEN = 0
#SM_CYSCREEN = 1

Global gScaleX.d = 1.0
Global gScaleY.d = 1.0

Procedure InitDpiScale()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; We want a robust "virtualization scale" that works regardless of whether the
    ; process is DPI-aware or DPI-unaware.
    ;
    ; - physW/physH: physical pixel size (DESKTOPHORZRES/DESKTOPVERTRES)
    ; - appW/appH  : what THIS process sees as the screen size (GetSystemMetrics)
    ;
    ; If the process is DPI-unaware, appW/appH are typically smaller (effective pixels),
    ; so scale > 1.0 (e.g. 1.50 at 150% scaling).
    ; If the process is DPI-aware, appW/appH match physical, so scale = 1.0.
    Protected physW.i, physH.i
    Protected hdc.i = GetDC_(0)
    If hdc
      physW = GetDeviceCaps_(hdc, #GDC_DESKTOPHORZRES)
      physH = GetDeviceCaps_(hdc, #GDC_DESKTOPVERTRES)
      ReleaseDC_(0, hdc)
    EndIf

    Protected appW.i = GetSystemMetrics_(#SM_CXSCREEN)
    Protected appH.i = GetSystemMetrics_(#SM_CYSCREEN)

    If appW > 0 And physW > 0
      gScaleX = physW / appW
    Else
      gScaleX = 1.0
    EndIf

    If appH > 0 And physH > 0
      gScaleY = physH / appH
    Else
      gScaleY = 1.0
    EndIf

    If gScaleX <= 0.0 : gScaleX = 1.0 : EndIf
    If gScaleY <= 0.0 : gScaleY = 1.0 : EndIf
  CompilerEndIf
EndProcedure

Procedure.i PhysToPB_X(px.i)
  If gScaleX <= 0.0 : ProcedureReturn px : EndIf
  ProcedureReturn Int(px / gScaleX + 0.5)
EndProcedure

Procedure.i PhysToPB_Y(py.i)
  If gScaleY <= 0.0 : ProcedureReturn py : EndIf
  ProcedureReturn Int(py / gScaleY + 0.5)
EndProcedure

Procedure.i PBToPhys_X(x.i)
  ProcedureReturn Int(x * gScaleX + 0.5)
EndProcedure

Procedure.i PBToPhys_Y(y.i)
  ProcedureReturn Int(y * gScaleY + 0.5)
EndProcedure

Procedure.i GetDesktopPhysW()
  Protected w.i
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected hdc.i = GetDC_(0)
    If hdc
      w = GetDeviceCaps_(hdc, #GDC_DESKTOPHORZRES)
      ReleaseDC_(0, hdc)
    EndIf
  CompilerEndIf
  ProcedureReturn w
EndProcedure

Procedure.i GetDesktopPhysH()
  Protected h.i
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected hdc.i = GetDC_(0)
    If hdc
      h = GetDeviceCaps_(hdc, #GDC_DESKTOPVERTRES)
      ReleaseDC_(0, hdc)
    EndIf
  CompilerEndIf
  ProcedureReturn h
EndProcedure

Procedure SetMainWindowFrameSize(frameW_PB.i, frameH_PB.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected hWnd.i = WindowID(#WinMain)
    If hWnd
      ; Set FRAME size exactly to frameW_PB x frameH_PB (PB units).
      SetWindowPos_(hWnd, 0, 0, 0, frameW_PB, frameH_PB, #SWP_NOMOVE | #SWP_NOZORDER | #SWP_NOACTIVATE)
    EndIf
  CompilerEndIf
EndProcedure

Procedure UpdateMainWindowTitle()
  If IsWindow(#WinMain) = 0 : ProcedureReturn : EndIf

  ; Show the ACTUAL outer window size (frame) in PHYSICAL pixels.
  ; - WindowWidth/Height with #PB_Window_FrameCoordinate includes borders/titlebar.
  ; - The returned units are "app pixels" (virtualized if the process is DPI-unaware).
  ; - Convert to physical pixels using gScaleX/gScaleY.
  Protected fwPB.i = WindowWidth(#WinMain, #PB_Window_FrameCoordinate)
  Protected fhPB.i = WindowHeight(#WinMain, #PB_Window_FrameCoordinate)

  Protected wPhys.i = PBToPhys_X(fwPB)
  Protected hPhys.i = PBToPhys_Y(fhPB)

  SetWindowTitle(#WinMain, gBaseTitle)
EndProcedure


; ----------------------------------------------------------------------------
; Progress bar (custom-drawn Canvas)
; ----------------------------------------------------------------------------
; We draw the bar ourselves so the percent label is ALWAYS:
;   - white text
;   - 1px black shadow
;   - centered (stable)
; This avoids theme-dependent repaint issues with native ProgressBar controls.
; ----------------------------------------------------------------------------
Global uiLastProgressPercent.i
Global logLinesSinceTrimCheck.i

Procedure DrawProgressCanvas(percent.i)
  If percent < 0 : percent = 0 : EndIf
  If percent > 100 : percent = 100 : EndIf
  uiLastProgressPercent = percent

  If IsGadget(#G_Progress) = 0 : ProcedureReturn : EndIf
  If GadgetType(#G_Progress) <> #PB_GadgetType_Canvas : ProcedureReturn : EndIf

  If StartDrawing(CanvasOutput(#G_Progress))
    Protected w.i = OutputWidth()
    Protected h.i = OutputHeight()
    If w < 1 : w = 1 : EndIf
    If h < 1 : h = 1 : EndIf

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

    ; Stronger shadow outline (all directions) for maximum readability.
    ; Draw a 2px outline by rendering black text around the yellow center text.
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
    DrawText(tx, ty, s, RGB(210, 180, 0))

    StopDrawing()
  EndIf
EndProcedure
Declare StopSimulation()
Declare ApplyPlotUIRules()
Declare LoadDeviationDataFile(filePath.s)

; ------------------------------------------------------------------------------
; Procedure: LogLine(msg.s)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure LogLine(msg.s)
  Protected t.s = FormatDate("%hh:%ii:%ss", Date()) + "  " + msg
  Protected h.i = GadgetID(#G_Log)
  Protected s.s = t + #CRLF$

  ; Append efficiently to the read-only EditorGadget.
  SendMessage_(h, #EM_SETSEL, -1, -1)
  SendMessage_(h, #EM_REPLACESEL, 0, @s)
  SendMessage_(h, #EM_SCROLLCARET, 0, 0)

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
      EndIf
    EndIf
  EndIf
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

  msg = "Progress update: " + Str(pct) + "% complete"
  msg + "   Elapsed: " + FormatDuration((nowMs - simulationStartMillis) / 1000.0)

  If etaSeconds >= 0.0
    msg + "   ETA: " + FormatDuration(etaSeconds)
  EndIf

  If throughputFlipsPerMs >= 0.0
    msg + "   Throughput: " + FormatNumber(throughputFlipsPerMs, 0, ".", ",") + " flips/ms"
  EndIf

  If liveThroughputFlipsPerMs >= 0.0
    msg + "   Live: " + FormatNumber(liveThroughputFlipsPerMs, 0, ".", ",") + " flips/ms"
  EndIf

  LogLine(msg)

  Repeat
    nextThroughputLogMillis + #LOG_THROUGHPUT_INTERVAL_MS
  Until nextThroughputLogMillis > nowMs
EndProcedure



; ------------------------------------------------------------------------------
; Procedure: YesNo(flag.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure.s YesNo(flag.i)
  If flag
    ProcedureReturn "yes"
  Else
    ProcedureReturn "no"
  EndIf
EndProcedure



; ------------------------------------------------------------------------------
; Procedure: ParseIntQFromGadget(gadget.i, defaultValue.q)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
; ------------------------------------------------------------------------------
; Procedure: ParseIntQFromString(text.s, defaultValue.q)
; Purpose  : Robust integer parsing for user-entered text.
;            - Accepts thousands separators (space, comma, underscore, apostrophe, dot).
;            - Ignores other non-digit characters (tolerates minor typos).
;            - If no digits are found, returns defaultValue.
;            - Caps digit count to avoid 64-bit overflow.
; ------------------------------------------------------------------------------
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


; ------------------------------------------------------------------------------
; Procedure: ParseIntQFromGadget(gadget.i, defaultValue.q)
; Purpose  : Parses an integer from a gadget text field using ParseIntQFromString().
; ------------------------------------------------------------------------------
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


; ------------------------------------------------------------------------------
; Procedure: UpdateDerivedInfo()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure UpdateDerivedInfo()
  Protected threads.q, flips.q, inst.q, runs.q, totalSamples.q, bytes.q
  Protected cpuCount.q = GetCpuCountCached()

  inst  = ParseIntQFromGadget(#G_Instances, #INSTANCES_TO_SIMULATE)
  runs  = ParseIntQFromGadget(#G_Runs, #SIMULATION_RUNS)
  flips = ParseIntQFromGadget(#G_Flips, #FLIPS_NEEDED)

  threads = ResolveThreadCount(GetGadgetState(#G_ThreadPolicy), ParseIntQFromGadget(#G_CustomThreads, cpuCount * cpuCount))

  totalSamples = threads * inst * runs
  bytes = totalSamples * 2

  SetGadgetText(#G_Derived, "Threads: " + Str(threads) + "   Total samples: " + FormatNumber(totalSamples, 0, ".", ",") + #LF$ + "Total flips: " + FormatNumber(totalSamples * flips, 0, ".", ",") + "   Est. file: " + FormatNumber(bytes / (1024.0*1024.0), 2, ".", ",") + " MiB")
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: DisableSettings(disable.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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


; ------------------------------------------------------------------------------
; Procedure: ApplySamplerUIRules()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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



; ------------------------------------------------------------------------------
; Procedure: ApplyThreadUIRules()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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


; ------------------------------------------------------------------------------
; Procedure: ApplySaveUIRules()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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
  ; Live graph toggle always stays available (user can trade speed vs. visuals).
  liveGraphEnabled = GetGadgetState(#G_LiveGraph)

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
  DisableSettings(isRunning)
  DisableGadget(#G_Start, Bool(isRunning))
  DisableGadget(#G_Stop, Bool(Not isRunning))
  ApplyConfigurationUIRules()
  ApplyPlotUIRules()
EndProcedure

Procedure SetPlotStatusLine(prefix.s, progress.i, etaSeconds.d, throughputFlipsPerMs.d, liveThroughputFlipsPerMs.d, maxDeviation.q, maxPct.d, zSigma.d)
  Protected pct.i = progress
  Protected text.s

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
    text + "  T:" + FormatNumber(throughputFlipsPerMs, 0, ".", ",") + " f/ms"
  EndIf

  If liveThroughputFlipsPerMs >= 0.0
    text + "  L:" + FormatNumber(liveThroughputFlipsPerMs, 0, ".", ",") + " f/ms"
  EndIf

  If maxDeviation >= 0
    text + "  M:" + Str(maxDeviation) + " (" + FormatNumber(maxPct, 2) + "%, " + FormatNumber(zSigma, 2) + "s)"
  EndIf

  SetGadgetText(#G_PlotInfo, text)
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


; ------------------------------------------------------------------------------
; Procedure: CopyLogToClipboard()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure CopyLogToClipboard()
  Protected OUT.s = GetGadgetText(#G_Log)
  If OUT <> ""
    SetClipboardText(OUT)
    LogLine("Log copied to clipboard.")
  EndIf
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: CopyLogSelectionOrAll()
; Purpose  : Copy selected text in the log if there is a selection; otherwise copy the entire log.
; Notes    : We use the native edit control messages for correct clipboard behavior.
; ------------------------------------------------------------------------------
Procedure CopyLogSelectionOrAll()
  ; Ensure the RichEdit has focus; WM_COPY can fail if another control owns focus.
  SetActiveGadget(#G_Log)
  Protected selA.l, selB.l
  Protected oldA.l, oldB.l

  SendMessage_(GadgetID(#G_Log), #MSG_EM_GETSEL, @selA, @selB)
  If selB > selA
    ; Copy selected text.
    SendMessage_(GadgetID(#G_Log), #MSG_WM_COPY, 0, 0)
  Else
    ; No selection -> copy all (temporarily select everything).
    oldA = selA : oldB = selB
    SendMessage_(GadgetID(#G_Log), #EM_SETSEL, 0, -1)
    SendMessage_(GadgetID(#G_Log), #MSG_WM_COPY, 0, 0)
    SendMessage_(GadgetID(#G_Log), #EM_SETSEL, oldA, oldB)
  EndIf
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: ClearLogUI()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure ClearLogUI()
  SetGadgetText(#G_Log, "")
EndProcedure



; =============================================================================
; Small helpers (GUI layout)
; =============================================================================
Procedure.i ClampI(value.i, minValue.i, maxValue.i)
  If value < minValue : ProcedureReturn minValue : EndIf
  If value > maxValue : ProcedureReturn maxValue : EndIf
  ProcedureReturn value
EndProcedure
; =============================================================================
; Text dialog layout helper (Help/About)
; =============================================================================
Procedure ApplyTextDialogLayout(win.i, editorGadget.i, closeButton.i)
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

  ; Editor takes the remaining space above the button row
  Protected editorX.i = clientX
  Protected editorY.i = clientY
  Protected editorW.i = clientW
  Protected editorH.i = btnY - #TEXTDLG_MARGIN - editorY

  ResizeGadget(editorGadget, editorX, editorY, editorW, editorH)
  ResizeGadget(closeButton, btnX, btnY, btnW, btnH)
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: ShowTextDialog(title.s, body.s)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure ShowTextDialog(title.s, body.s)
  ; Simple modal text viewer (Help/About).
  ; Uses a read-only EditorGadget and a Close button.
  Protected win.i, ed.i, btn.i
  Protected w.i = #TEXTDLG_W
  Protected h.i = #TEXTDLG_H
  Protected ev.i
  Protected i.i, lines.i, line.s
  Protected ww.i, hh.i

  ; Make modal-ish by disabling the main window while this is open
  DisableWindow(#WinMain, #True)

  win = OpenWindow(#PB_Any, 0, 0, w, h, title, #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_Tool)
  If win = 0
    DisableWindow(#WinMain, #False)
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

Protected edX.i = clientX
Protected edY.i = clientY
Protected edW.i = clientW
Protected edH.i = btnY - #TEXTDLG_MARGIN - edY

ed  = EditorGadget(#PB_Any, edX, edY, edW, edH, #PB_Editor_ReadOnly)
btn = ButtonGadget(#PB_Any, btnX, btnY, btnW, btnH, "Close")
ApplyTextDialogLayout(win, ed, btn)

  ; Fill editor line-by-line
  lines = CountString(body, #LF$) + 1
  For i = 1 To lines
    line = StringField(body, i, #LF$)
    AddGadgetItem(ed, -1, line)
  Next

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
        ApplyTextDialogLayout(win, ed, btn)
Case #PB_Event_Gadget
        If EventGadget() = btn
          Break
        EndIf
    EndSelect
  ForEver

  CloseWindow(win)
  DisableWindow(#WinMain, #False)
  SetActiveWindow(#WinMain)
EndProcedure


; =============================================================
; Returns the default output file path used when "Save output file"
; is enabled and the Output Path field is empty.
;
; We stamp the filename with the program version so that different
; builds do not overwrite each other's results.
; Example: Coinflip_<version>.data
; =============================================================
Procedure.s GetDefaultOutputFilePath()
  ProcedureReturn GetCurrentDirectory() + "Coinflip_" + #ProgramVersion$ + ".data"
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: ShowHelp()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure ShowHelp()
  Protected helpText.s

  helpText = "Coin-Flip Deviation Simulator " + #ProgramVersion$ + " - User Guide" + #LF$ +
             "====================================================" + #LF$ +
             "" + #LF$ +
             "1) Purpose" + #LF$ +
             "----------" + #LF$ +
             "The simulator runs repeated fair-coin experiments and records, per sample:" + #LF$ +
             "  absolute deviation = |Heads - n/2|" + #LF$ +
             "where n is the configured flips per sample." + #LF$ +
             "" + #LF$ +
             "2) Quick Start" + #LF$ +
             "--------------" + #LF$ +
             "1. Choose Flips / sample (n)." + #LF$ +
             "2. Choose Instances / run-block and Run-blocks / thread." + #LF$ +
             "3. Select Thread policy (default: CPUs^2)." + #LF$ +
             "4. Click Start." + #LF$ +
             "5. Watch Progress, ETA, Throughput, and Max in the status area." + #LF$ +
             "" + #LF$ +
             "3) Simulation Modes" + #LF$ +
             "-------------------" + #LF$ +
             "BIT-EXACT:" + #LF$ +
             "  Generates random bits and counts heads with popcount kernels." + #LF$ +
             "  This is the strictest bit-level simulation path." + #LF$ +
             "" + #LF$ +
             "BINOMIAL:" + #LF$ +
             "  Samples heads directly from Binomial(n, 0.5), then computes |Heads - n/2|." + #LF$ +
             "  This is faster and statistically equivalent for deviation-level analysis." + #LF$ +
             "" + #LF$ +
             "Binomial engines:" + #LF$ +
             "  0 BTPE exact (recommended)" + #LF$ +
             "  1 BTRD exact (Hormann transformed rejection)" + #LF$ +
             "  2 CLT K approximation (bounded tails; fastest approximate route)" + #LF$ +
             "  3 CPython exact (BG + BTRS)" + #LF$ +
             "" + #LF$ +
             "Optional ONNX diagnostic:" + #LF$ +
             "  If onnxruntime.dll is available, the run log reports a one-time" + #LF$ +
             "  embedded-model self-test. Native PB samplers still do all sampling." + #LF$ +
             "" + #LF$ +
             "4) Throughput and Accuracy Notes" + #LF$ +
             "-------------------------------" + #LF$ +
             "- Disable Live graph for maximum speed." + #LF$ +
             "- Larger local batch sizes reduce synchronization overhead." + #LF$ +
             "- BIT-EXACT uses CPU kernel selection; BINOMIAL ignores kernel policy." + #LF$ +
             "" + #LF$ +
             "5) Plot Threshold Behavior" + #LF$ +
             "--------------------------" + #LF$ +
             "- Threshold drives plot markers and >= threshold counts." + #LF$ +
             "- While stopped, threshold commits on Enter or when focus is lost." + #LF$ +
             "- While running, threshold input is locked to keep statistics consistent." + #LF$ +
             "" + #LF$ +
             "6) Output File" + #LF$ +
             "--------------" + #LF$ +
             "When Save output file is enabled, each sample writes one WORD (16-bit):" + #LF$ +
             "  deviation_clamped = Clamp(|Heads - n/2|, 0..65535)" + #LF$ +
             "File format is raw little-endian WORD values (.data)." + #LF$ +
             "" + #LF$ +
             "7) Status and Log" + #LF$ +
             "-----------------" + #LF$ +
             "Live status shows:" + #LF$ +
             "  Progress %, ETA, Throughput (flips/ms), and Max deviation with sigma." + #LF$ +
             "The log stores run configuration, method selection, and final summary." + #LF$ +
             "" + #LF$ +
             "8) Reset" + #LF$ +
             "--------" + #LF$ +
             "Reset restores all defaults, including plot threshold, and reloads the" + #LF$ +
             "embedded demo distribution for immediate visual feedback." + #LF$ +
             "" + #LF$ +
             "9) Practical Interpretation" + #LF$ +
             "--------------------------" + #LF$ +
             "For n flips per sample, one standard deviation is sqrt(n*0.25)." + #LF$ +
             "Large maxima are expected across many samples; use sigma to compare runs." + #LF$ +
             "" + #LF$ +
             "Tip: hover controls for context tooltips." + #LF$

  ShowTextDialog("Help", helpText)
EndProcedure



; ------------------------------------------------------------------------------
; Procedure: ShowAbout()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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
              "- Optional embedded ONNX Runtime self-test (diagnostic only)" + #LF$ +
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


; ------------------------------------------------------------------------------
; Procedure: BuildMenuBar()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure BuildMenuBar()
  If CreateMenu(0, WindowID(#WinMain))
    MenuTitle("Run")
      MenuItem(#Menu_RunStart, "Start")
      MenuItem(#Menu_RunStop,  "Stop")
      MenuItem(#Menu_RunReset, "Reset")
    MenuTitle("Help")
      MenuItem(#Menu_HelpHelp,  "Help...")
      MenuItem(#Menu_HelpAbout, "About...")
  EndIf
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: BuildPopupMenus()
; Purpose  : Right-click context menus (currently used for the log window)
; ------------------------------------------------------------------------------
Procedure BuildPopupMenus()
  ; Popup menu id 1 is reserved for the log right-click menu.
  If CreatePopupMenu(1)
    MenuItem(#Menu_LogCopy, "Copy")
  EndIf
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: ResetToDefaults()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure ResetToDefaults()
  ; Restore default settings from constants and clear progress fields.
  SetGadgetText(#G_Instances, Str(#INSTANCES_TO_SIMULATE))
  SetGadgetText(#G_Runs, Str(#SIMULATION_RUNS))
  SetGadgetText(#G_Flips, Str(#FLIPS_NEEDED))
  SetGadgetText(#G_BufferMiB, Str(#BUFFER_SIZE / (1024*1024)))
  SetGadgetText(#G_LocalBatch, Str(#LOCAL_BATCH_SAMPLES))

  SetGadgetState(#G_SamplerMode, #SAMPLER_MODE)
  SetGadgetState(#G_BinomMethod, 0)
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

  DrawProgressCanvas(0)
  SetPlotStatusLine("Ready", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0)

  ; Show a meaningful plot immediately (no disk I/O)
  LoadEmbeddedDeviationData()

  LogLine("Back to defaults.")
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: RequestReset()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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
; NOTE: Intended for rare events with a high threshold. Storage is capped.
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


; ------------------------------------------------------------------------------
; Procedure: MergeDeviationStats(batchCount.q, batchMean.d, batchM2.d, batchCountAboveThreshold.q, batchMaxValue.w)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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
  ; This is fast enough for our plot (few hundred segments) and avoids DPI artifacts.
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


; ------------------------------------------------------------------------------
; Procedure: DrawThickFrame(x.i, y.i, w.i, h.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure DrawThickFrame(x.i, y.i, w.i, h.i)
  ; Draw a thicker rectangle outline by drawing nested frames.
  Protected i.i
  DrawingMode(#PB_2DDrawing_Outlined)
  For i = 0 To #PLOT_LINE_THICKNESS - 1
    Box(x + i, y + i, w - (2 * i), h - (2 * i))
  Next
EndProcedure



; ------------------------------------------------------------------------------
; Procedure: DrawDashedVLine(x.i, y1.i, y2.i, dashLen.i, gapLen.i)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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



; ------------------------------------------------------------------------------
; Procedure: DrawDistributionPlot(mean.d, stdDev.d, maxValue.q, sampleCount.q, countAboveThreshold.q)
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure DrawDistributionPlot(mean.d, stdDev.d, maxValue.q, sampleCount.q, countAboveThreshold.q, *aboveVals, aboveCount.i, aboveTruncated.i)
  ; Draw a simplified version of DesktopCoinFlip.py:
  ; - Bell curve based on running mean/std-dev
  ; - Vertical dashed lines at maxValue (green) and threshold (red)
  ; - A stats box (placed in the upper half, above the blue reference line)
  ;
  ; IMPORTANT (DPI / resize correctness):
  ; Use OutputWidth()/OutputHeight() *after* StartDrawing() so the drawing area matches
  ; the actual pixel buffer. This prevents "leftover" artifacts when resizing.

  If StartDrawing(CanvasOutput(#G_PlotCanvas))

    ; Use the actual drawing surface size (handles DPI scaling correctly).
    Protected w.i = OutputWidth()
    Protected h.i = OutputHeight()

    ; Always clear the full canvas first (prevents artifacts on resize).
    DrawingMode(#PB_2DDrawing_Default)
    Box(0, 0, w, h, RGB(255, 255, 255))

    ; Plot padding (room for title + labels + margins)
    ; Keep LEFT and RIGHT padding identical so the plot is visually centered.
    ; (Earlier versions used a larger left margin, which made the plot start too far to the right.)
    Protected lrPad.i = 10
    Protected left.i  = lrPad
    Protected right.i = lrPad
    Protected top.i = 26
    Protected bottom.i = 22

    Protected plotW.i = w - left - right
    Protected plotH.i = h - top - bottom


    ; Reserve enough space at the bottom so the bell-curve tail never overlaps the X-axis tick labels.
    ; Tick labels are drawn just above the bottom frame line, so we ensure innerPadBottom >= tickHeight + textHeight.
    Protected tickLabelBand.i = #PLOT_TICK_HEIGHT + TextHeight("0") + 6
; --------------------------------------------------------------------------
; Inner drawing area (padding inside the frame)
; --------------------------------------------------------------------------
; The frame uses (left/top/plotW/plotH). To keep the bell curve from touching
; the frame borders, we draw the curve (and curve-dependent markers) inside a
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
      ProcedureReturn
    EndIf

    ; Title (top-left)
    DrawingMode(#PB_2DDrawing_Transparent)
    FrontColor(RGB(0, 0, 0))
    DrawText(left, 4, "Data Points (>= " + Str(configuredPlotThreshold) + ") and Bell Curve")

    ; Status note (top-right)
    DrawingMode(#PB_2DDrawing_Transparent)
    FrontColor(RGB(70, 70, 70))
    If simulationIsRunning And liveGraphEnabled = 0
      DrawText(w - right - TextWidth("Live graph disabled (plot frozen for speed)") , 4, "Live graph disabled (plot frozen for speed)")
    ElseIf loadedDataIsActive And loadedDataFilePath <> ""
      DrawText(w - right - TextWidth("Loaded: " + GetFilePart(loadedDataFilePath)), 4, "Loaded: " + GetFilePart(loadedDataFilePath))
    EndIf

    ; Frame (thick)
    FrontColor(RGB(0, 0, 0))
    DrawThickFrame(left, top, plotW, plotH)

    ; NOTE: The curve is drawn inside (top+innerPadTop) .. (top+innerPadTop+innerH),
    ; while the frame uses the full plotH. This creates a clean margin to the borders.


    ; Not enough data yet?
    If sampleCount < 2 Or stdDev <= 0.0
      DrawingMode(#PB_2DDrawing_Transparent)
      FrontColor(RGB(90, 90, 90))
      DrawText(left + 10, top + 10, "Waiting for enough samples to estimate mean and std dev...")
      StopDrawing()
      ProcedureReturn
    EndIf

    ; Determine x range (0 .. max(threshold, maxValue)) with enough right-side room for labels
    Protected xMin.d = 0.0
    Protected xMax.d = maxValue
    If xMax < configuredPlotThreshold : xMax = configuredPlotThreshold : EndIf
    If xMax < 1 : xMax = 1 : EndIf

    ; Ensure the green max-value label fits inside the right border:
    ; We expand xMax so the maxValue vertical line is far enough from the right edge.
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
; true peak, and the "hanging" mean/+/-1ÃƒÂÃ†â€™ markers will appear to start above
; the drawn curve. To avoid this, we choose a higher step count tied to the
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
; IMPORTANT: because thick lines are drawn with +/-radius pixel offsets, we shift the
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
    Protected boxY.i

    If upperBottom <= upperTop + boxH
      boxY = upperTop
    Else
      boxY = upperTop + (upperBottom - upperTop - boxH) / 2
    EndIf

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
  EndIf
EndProcedure



; ------------------------------------------------------------------------------
; Procedure: UpdateDistributionPlot()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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




; ------------------------------------------------------------------------------
; Procedure: ApplyLayout()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure ApplyLayout()
  ; Recompute all gadget rectangles based on current window size.
  Protected winW.i = WindowWidth(#WinMain, #PB_Window_InnerCoordinate)
  Protected winH.i = WindowHeight(#WinMain, #PB_Window_InnerCoordinate)

  Protected clientX.i = #MARGIN
  Protected clientY.i = #MARGIN
  Protected clientW.i = winW - (#MARGIN * 2)
  Protected clientH.i = winH - (#MARGIN * 2)
  If clientW < 1 : clientW = 1 : EndIf
  If clientH < 1 : clientH = 1 : EndIf

  ; ------------------------------------------------------------
  ; Vertical allocation:
  ;   Top: 3 columns (settings | policy | buttons+log)
  ;   Bottom: plot bar (controls + status) + plot canvas
  ; ------------------------------------------------------------
  Protected plotBarH.i = #PLOT_BAR_H
  If plotBarH < 0 : plotBarH = 0 : EndIf

  ; Minimum content heights (approx) for each top column.
  Protected minCol1H.i
  minCol1H = (#TITLE_H + #GAP_Y)                               ; Settings header
  minCol1H + (5 * (#ROW_H + #GAP_Y))                           ; Instances/Runs/Flips/Buffer/LocalBatch
  minCol1H + (#TITLE_H + #GAP_Y) + (#ROW_H + #GAP_Y)           ; Sampler header + combo
  minCol1H + (#TITLE_H + #GAP_Y) + (#ROW_H + #GAP_Y)           ; Binomial header + combo
  minCol1H + (#ROW_H + #GAP_Y)                                 ; Binom K row

  Protected minCol2H.i
  minCol2H = (#TITLE_H + #GAP_Y) + (#ROW_H + #GAP_Y)           ; Kernel header + combo
  minCol2H + (#ROW_H + #GAP_Y)                                 ; Save checkbox
  minCol2H + (#ROW_H + #GAP_Y)                                 ; Output path row
  minCol2H + (#TITLE_H + #GAP_Y) + (#ROW_H + #GAP_Y)           ; Thread header + combo
  minCol2H + (#ROW_H + #GAP_Y)                                 ; Custom threads row
  minCol2H + ((#ROW_H * #DERIVED_ROWS) + #GAP_Y)               ; Derived text
  minCol2H + (#SEP_H + #GAP_Y)                                 ; Separator

  Protected minCol3H.i
  minCol3H = (#BTN_H + #GAP_Y)                                 ; Start/Stop/Reset + progress (same row)
  minCol3H + (#SMALLBTN_H + #GAP_Y)                            ; Log header + buttons
  minCol3H + #LOG_MIN_H                                        ; Log editor

  ; Top height must fit the tallest column (minimum).
  Protected minTopH.i = minCol1H
  If minCol2H > minTopH : minTopH = minCol2H : EndIf
  If minCol3H > minTopH : minTopH = minCol3H : EndIf

  ; Allocate vertical space:
  ; - Top area uses its minimum required height (minTopH).
  ; - Any extra height is given to the plot canvas (reduces unused blank space).
  Protected gapsH.i = #GAP_Y + plotBarH + #GAP_Y
  Protected availableForPlot.i = clientH - (minTopH + gapsH)

  Protected plotCanvasH.i
  Protected topH.i

  If availableForPlot >= #PLOT_MIN_HEIGHT
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
  Protected colGap.i = #GAP_X

  ; Keep column 1 and 2 fixed (preferred widths). Column 3 absorbs horizontal resize.
  Protected col1W.i = #COL1_W
  Protected col2W.i = #COL2_W
  If col1W < #COL1_MIN_W : col1W = #COL1_MIN_W : EndIf
  If col2W < #COL2_MIN_W : col2W = #COL2_MIN_W : EndIf

  Protected col3W.i = topW - col1W - col2W - (colGap * 2)

  ; If the window is too narrow, shrink col2 then col1 (down to their minima).
  If col3W < #RIGHT_MIN_W
    col3W = #RIGHT_MIN_W
    col2W = topW - col1W - col3W - (colGap * 2)
    If col2W < #COL2_MIN_W
      col2W = #COL2_MIN_W
      col1W = topW - col2W - col3W - (colGap * 2)
      If col1W < #COL1_MIN_W
        col1W = #COL1_MIN_W
        col3W = topW - col1W - col2W - (colGap * 2)
        If col3W < #RIGHT_MIN_W : col3W = #RIGHT_MIN_W : EndIf
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
  Protected inputW1.i = #INPUT_W
  Protected labelX1.i = col1X + inputW1 + #GAP_X
  Protected labelW1.i = col1W - inputW1 - #GAP_X
  If labelW1 < #MIN_LABEL_W : labelW1 = #MIN_LABEL_W : EndIf

  Protected y1.i = colY

  ResizeGadget(#G_LblSettings, col1X, y1, col1W, #TITLE_H) : y1 + #TITLE_H + #GAP_Y

  ResizeGadget(#G_Instances,    col1X, y1, inputW1, #ROW_H)
  ResizeGadget(#G_LblInstances, labelX1, y1, labelW1, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ResizeGadget(#G_Runs,    col1X, y1, inputW1, #ROW_H)
  ResizeGadget(#G_LblRuns, labelX1, y1, labelW1, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ResizeGadget(#G_Flips,    col1X, y1, inputW1, #ROW_H)
  ResizeGadget(#G_LblFlips, labelX1, y1, labelW1, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ResizeGadget(#G_BufferMiB,    col1X, y1, inputW1, #ROW_H)
  ResizeGadget(#G_LblBufferMiB, labelX1, y1, labelW1, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ResizeGadget(#G_LocalBatch,    col1X, y1, inputW1, #ROW_H)
  ResizeGadget(#G_LblLocalBatch, labelX1, y1, labelW1, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ResizeGadget(#G_LblSamplerHeader, col1X, y1, col1W, #TITLE_H) : y1 + #TITLE_H + #GAP_Y
  ResizeGadget(#G_SamplerMode, col1X, y1, col1W, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ResizeGadget(#G_LblBinomHeader, col1X, y1, col1W, #TITLE_H) : y1 + #TITLE_H + #GAP_Y
  ResizeGadget(#G_BinomMethod, col1X, y1, col1W, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ResizeGadget(#G_BinomK,    col1X, y1, inputW1, #ROW_H)
  ResizeGadget(#G_LblBinomK, labelX1, y1, labelW1, #ROW_H) : y1 + #ROW_H + #GAP_Y

  ; ------------------------------------------------------------
  ; Column 2 (kernel + save + threads + derived)
  ; ------------------------------------------------------------
  Protected inputW2.i = #INPUT_W
  Protected labelX2.i = col2X + inputW2 + #GAP_X
  Protected labelW2.i = col2W - inputW2 - #GAP_X
  If labelW2 < #MIN_LABEL_W : labelW2 = #MIN_LABEL_W : EndIf

  Protected y2.i = colY

  ResizeGadget(#G_LblKernelHeader, col2X, y2, col2W, #TITLE_H) : y2 + #TITLE_H + #GAP_Y
  ResizeGadget(#G_ForceKernel, col2X, y2, col2W, #ROW_H) : y2 + #ROW_H + #GAP_Y

  ResizeGadget(#G_SaveToFile, col2X, y2, col2W, #ROW_H) : y2 + #ROW_H + #GAP_Y

  ResizeGadget(#G_OutputPath, col2X, y2, col2W - #BROWSE_W - #GAP_X, #ROW_H)
  ResizeGadget(#G_BrowsePath, col2X + col2W - #BROWSE_W, y2, #BROWSE_W, #ROW_H) : y2 + #ROW_H + #GAP_Y

  ResizeGadget(#G_LblThreadHeader, col2X, y2, col2W, #TITLE_H) : y2 + #TITLE_H + #GAP_Y
  ResizeGadget(#G_ThreadPolicy, col2X, y2, col2W, #ROW_H) : y2 + #ROW_H + #GAP_Y

  ResizeGadget(#G_CustomThreads,    col2X, y2, inputW2, #ROW_H)
  ResizeGadget(#G_LblCustomThreads, labelX2, y2, labelW2, #ROW_H) : y2 + #ROW_H + #GAP_Y

  ResizeGadget(#G_Derived, col2X, y2, col2W, (#ROW_H * #DERIVED_ROWS)) : y2 + (#ROW_H * #DERIVED_ROWS) + #GAP_Y

  ResizeGadget(#G_SepLine, col2X, y2, col2W, #SEP_H) : y2 + #SEP_H + #GAP_Y

  ; (Old progress text lines are hidden; progress now lives next to Start/Stop/Reset)
  ResizeGadget(#G_Prog2, 0, 0, 1, 1)
  ResizeGadget(#G_Prog3, 0, 0, 1, 1)
  ResizeGadget(#G_Prog4, 0, 0, 1, 1)

  ; ------------------------------------------------------------
  ; Column 3 (Start/Stop/Reset + progress bar, then log)
  ; ------------------------------------------------------------
  Protected y3.i = colY

  Protected btnGap.i = 6
  Protected btnW.i = 70
  Protected usedW.i = (btnW * 3) + (btnGap * 3) ; includes gap between Reset and progress
  Protected progW.i = col3W - usedW

  If progW < 80
    btnW = (col3W - (btnGap * 3) - 80) / 3
    If btnW < 60 : btnW = 60 : EndIf
    usedW = (btnW * 3) + (btnGap * 3)
    progW = col3W - usedW
    If progW < 60 : progW = 60 : EndIf
  EndIf

  ResizeGadget(#G_Start, col3X, y3, btnW, #BTN_H)
  ResizeGadget(#G_Stop,  col3X + btnW + btnGap, y3, btnW, #BTN_H)
  ResizeGadget(#G_Reset, col3X + (btnW + btnGap) * 2, y3, btnW, #BTN_H)

  Protected progX.i = col3X + (btnW + btnGap) * 3
  Protected progY.i = y3 + (#BTN_H - #PROG_H) / 2
  ResizeGadget(#G_Progress, progX, progY, progW, #PROG_H)
  y3 + #BTN_H + #GAP_Y

  Protected headerLabelW.i = col3W - (2 * #LOG_BTN_W) - (#GAP_X)
  If headerLabelW < #MIN_LABEL_W : headerLabelW = #MIN_LABEL_W : EndIf

  ResizeGadget(#G_LblLogHeader, col3X, y3 + 2, headerLabelW, #TITLE_H)
  ResizeGadget(#G_ClearLog, col3X + col3W - (2 * #LOG_BTN_W + #GAP_X), y3, #LOG_BTN_W, #SMALLBTN_H)
  ResizeGadget(#G_CopyLog,  col3X + col3W - #LOG_BTN_W,              y3, #LOG_BTN_W, #SMALLBTN_H)

  Protected logY.i = y3 + #SMALLBTN_H + #GAP_Y
  Protected logH.i = (topY + topH) - logY
  If logH < #LOG_MIN_H : logH = #LOG_MIN_H : EndIf
  ResizeGadget(#G_Log, col3X, logY, col3W, logH)

  ; ------------------------------------------------------------
  ; Bottom: plot bar + plot canvas
  ; ------------------------------------------------------------
  Protected plotBarX.i = clientX
  Protected plotBarY.i = topY + topH + #GAP_Y
  Protected plotW.i = clientW

  If plotBarH > 0
    ; Two-line plot bar:
    ;   - a small label above the status line (ETA/Throughput/Max)
    ;   - the status line aligned with the Live graph / Load data controls
    Protected labelH.i  = #PLOTINFO_LABEL_H
    Protected statusY.i = plotBarY + labelH + 2

    ; Keep the plot bar compact and stable across window sizes:
    ; [Live graph] [Load data...] [Threshold: ____] [Status label + status line]
    Protected checkW.i = #PLOT_CHECK_W
    Protected loadW.i = #PLOT_LOAD_W
    Protected thrLabelW.i = #PLOT_THR_LABEL_W
    Protected thrInputW.i = #PLOT_THR_INPUT_W
    Protected fixedW.i = checkW + #GAP_X + loadW + #GAP_X + thrLabelW + #GAP_X + thrInputW + #GAP_X
    Protected plotInfoW.i = plotW - fixedW

    ; Narrow-window fallback: shrink control widths before status text collapses.
    If plotInfoW < #PLOT_STATUS_MIN_W
      checkW = 150 : loadW = 96 : thrLabelW = 64 : thrInputW = 80
      fixedW = checkW + #GAP_X + loadW + #GAP_X + thrLabelW + #GAP_X + thrInputW + #GAP_X
      plotInfoW = plotW - fixedW
    EndIf
    If plotInfoW < 10 : plotInfoW = 10 : EndIf

    Protected loadX.i = plotBarX + checkW + #GAP_X
    Protected thrLabelX.i = loadX + loadW + #GAP_X
    Protected thrValueX.i = thrLabelX + thrLabelW + #GAP_X
    Protected plotInfoX.i = thrValueX + thrInputW + #GAP_X

    ResizeGadget(#G_LiveGraph,        plotBarX, statusY, checkW, #ROW_H)
    ResizeGadget(#G_LoadData,         loadX, statusY, loadW, #ROW_H)
    ResizeGadget(#G_LblPlotThreshold, thrLabelX, statusY, thrLabelW, #ROW_H)
    ResizeGadget(#G_PlotThreshold,    thrValueX, statusY, thrInputW, #ROW_H)
    ResizeGadget(#G_PlotInfoLabel,    plotInfoX, plotBarY, plotInfoW, labelH)
    ResizeGadget(#G_PlotInfo,         plotInfoX, statusY, plotInfoW, #ROW_H)

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

  Protected plotCanvasY.i = plotBarY + plotBarH + #GAP_Y
  Protected plotCanvasH2.i = (clientY + clientH) - plotCanvasY
  If plotCanvasH2 < 0 : plotCanvasH2 = 0 : EndIf
  ResizeGadget(#G_PlotCanvas, clientX, plotCanvasY, plotW, plotCanvasH2)

  ; Redraw the progress bar after size/layout changes (Canvas does not auto-scale).
  DrawProgressCanvas(uiLastProgressPercent)
EndProcedure



; ------------------------------------------------------------------------------
; Procedure: ResizeUI()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure ResizeUI()
  ; Backwards-compatible wrapper: keep existing calls intact.
  ApplyLayout()
EndProcedure






; ------------------------------------------------------------------------------
; Procedure: HandleFatal()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure HandleFatal()
  Protected msg.s = fatalErrorMessage
  If msg = "" : msg = "Unknown fatal error." : EndIf
  LogLine("FATAL: " + msg)
  MessageRequester("Fatal error", msg, #PB_MessageRequester_Error)
  stopRequested = 1
  fatalErrorFlag = 0
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: StartSimulation()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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
    SetGadgetText(#G_PlotInfo, "  Creating worker pool... 0 / " + Str(workerPoolThreadCount))
    While WindowEvent() : Wend
  EndIf

  For i = 0 To workerPoolThreadCount - 1
    workerPoolThreadID(i) = CreateThread(@CoinFlipWorkerLoop(), i)
    If workerPoolThreadID(i) = 0
      MessageRequester("Error", "CreateThread() failed while building the worker pool at thread " + Str(i) + ".", #PB_MessageRequester_Error)
      poolQuitFlag = 1
      ; Wake and join any threads we already created
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
      SetGadgetText(#G_PlotInfo, "  Creating worker pool... " + Str(i + 1) + " / " + Str(workerPoolThreadCount))
      nextUiMs = ElapsedMilliseconds() + 1000
      While WindowEvent() : Wend
    EndIf
  Next

  workerPoolCreated = 1

  If IsGadget(#G_PlotInfo)
    SetGadgetText(#G_PlotInfo, "  Worker pool ready: " + Str(workerPoolThreadCount) + " threads")
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
  configuredBinomialMethod = GetGadgetState(#G_BinomMethod)
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
  ; - If live graph is enabled, we start fresh for THIS run (clear old plot + loaded-file flag).
  ; - If live graph is disabled (speed mode), we keep the existing plot and loaded-file info visible.
  liveGraphEnabled = GetGadgetState(#G_LiveGraph)

  If liveGraphEnabled
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
  ClearList(threadList())
  ApplyRunControlUI(#True)
  SetPlotStatusLine("Running", 0, -1.0, -1.0, -1.0, 0, 0.0, 0.0)
  DrawProgressCanvas(0)
  LogLine("------------------------------------------------------------")
  LogLine("Run started (" + #ProgramVersion$ + ").")
  LogLine("CPU: " + GetCpuBrandString() + ".")
  LogLine("OS : " + GetWindowsVersionString() + ".")
  LogLine("Workers (threads): " + Str(workerThreadCount) + ".")
  LogLine("Planned work: " + FormatNumber(totalSamplesPlanned, 0, ".", ",") + " samples total.")
  LogLine("  Each sample = " + FormatNumber(configuredFlipsPerSample, 0, ".", ",") + " coin flips.")
  LogLine("  Total flips  = " + FormatNumber(totalSamplesPlanned * configuredFlipsPerSample, 0, ".", ",") + ".")

  If isFileOutputEnabled
    LogLine("Saving results: Yes (2 bytes per sample) -> " + outputFilePath)
  Else
    LogLine("Saving results: No (speed test mode).")
  EndIf

  If sigmaHeads > 0.0
    LogLine("Natural variation: about 1 sigma ~= " + FormatNumber(sigmaHeads, 1) + " heads for this sample size.")
    If expectedMaxSigmaMean > 0.0
      LogLine("Rule of thumb for the biggest deviation (over all samples):")
      LogLine("  ~" + FormatNumber(expectedMaxSigmaMean, 2) + " sigma on average (often " + FormatNumber(expectedMaxSigmaP05, 2) + " sigma .. " + FormatNumber(expectedMaxSigmaP95, 2) + " sigma).")
      LogLine("  Roughly " + Str(Int(expectedMaxDeviationMeanHeads + 0.5)) + " heads (often " + Str(Int(expectedMaxDeviationP05Heads + 0.5)) + " .. " + Str(Int(expectedMaxDeviationP95Heads + 0.5)) + ").")
    EndIf
  EndIf

  If configuredSamplerMode = 0
    ; BIT-EXACT: generate random bits and count heads (real flip simulation)
    Select activeKernelSupportLevel
      Case 4 : kernelName = "AVX-512 VPOPCNTQ (native vector popcount)"
      Case 3 : kernelName = "AVX2 (256-bit PSHUFB popcount emulation)"
      Case 2 : kernelName = "AVX (128-bit PSHUFB popcount emulation)"
      Case 1 : kernelName = "POPCNT (scalar popcount)"
      Default: kernelName = "SWAR (portable bit counting)"
    EndSelect
    LogLine("Randomness method: BIT-EXACT (generate bits, then count heads).")
    LogLine("Counting kernel: " + kernelName + kernelSelectionSuffix)
  Else
    ; BINOMIAL: sample number of heads directly (no bitstreams)
    LogLine("Randomness method: BINOMIAL (sample number of heads directly).")
    Select configuredBinomialMethod
      Case 0
        LogLine("Binomial engine: Exact BTPE (Kachitvichyanukul & Schmeiser).")
      Case 1
        LogLine("Binomial engine: Exact BTRD (Hormann transformed rejection).")
      Case 2
        LogLine("Binomial engine: Approximate CLT. K=" + Str(configuredBinomialCltK) + ".")
        If sigmaTailCap > 0.0
          LogLine("  Note: CLT limits extremes to about +/-" + FormatNumber(sigmaTailCap, 2) + " sigma.")
        EndIf
      Case 3
        LogLine("Binomial engine: Exact CPython (BG+BTRS, random.binomialvariate).")
      Default
        LogLine("Binomial engine: Exact BTPE (Kachitvichyanukul & Schmeiser).")
    EndSelect
    If embeddedOrtSelfTestLogged = 0
      EnsureEmbeddedOrtSelfTest()
      LogLine(embeddedOrtSelfTestSummary)
      embeddedOrtSelfTestLogged = 1
    EndIf
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
    SetPlotStatusLine("Starting workers", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0)
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
    SetPlotStatusLine("Running", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0)
  EndIf
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: FinalizeSimulation()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
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

  ; NOTE (thread pool):
  ; Workers are persistent and reused across runs, so we do NOT WaitThread() here.
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

  ; Use ACTUAL completed samples so throughput is correct on Stop
  LockMutex(ioMutex)
    totalSamples = totalSamplesWritten
  UnlockMutex(ioMutex)

  Protected plannedSamples.q
  plannedSamples = workerThreadCount * configuredInstancesPerWorkBlock * configuredWorkBlocksPerThread

  totalFlips = totalSamples * configuredFlipsPerSample
  avgFlipsPerMs = totalFlips / elapsed

  If totalSamples < plannedSamples
    LogLine("Run finished (stopped early).")
    LogLine("Summary: " + FormatNumber(totalSamples, 0, ".", ",") + " samples of " + FormatNumber(plannedSamples, 0, ".", ",") + " planned  (" + FormatNumber(totalFlips, 0, ".", ",") + " flips).")
  Else
    LogLine("Run finished.")
    LogLine("Summary: " + FormatNumber(totalSamples, 0, ".", ",") + " samples  (" + FormatNumber(totalFlips, 0, ".", ",") + " flips).")
  EndIf
  LogLine("Largest deviation seen: " + Str(maxDeviationAbsoluteOverall) + " heads (" + FormatNumber(maxDeviationPercentOverall, 3) + " % of flips).")
  LogLine("Average speed: " + FormatNumber(avgFlipsPerMs, 0, ".", ",") + " flips/ms (" + FormatNumber((avgFlipsPerMs*1000.0)/1000000.0, 2, ".", ",") + " M flips/s).")

  If sigmaHeads > 0.0
    zFinal = maxDeviationAbsoluteOverall / sigmaHeads
    LogLine("In sigma terms: " + FormatNumber(zFinal, 2) + " sigma  (1 sigma ~= " + FormatNumber(sigmaHeads, 1) + " heads).")
    If expectedMaxSigmaMean > 0.0
      LogLine("Rule of thumb check (largest deviation over many samples):")
      LogLine("  ~" + FormatNumber(expectedMaxSigmaMean, 2) + " sigma on average (often " + FormatNumber(expectedMaxSigmaP05, 2) + " sigma .. " + FormatNumber(expectedMaxSigmaP95, 2) + " sigma).")
    EndIf
    If configuredSamplerMode = 1 And configuredBinomialMethod = 2 And sigmaTailCap > 0.0
      LogLine("CLT note: with K=" + Str(configuredBinomialCltK) + " the tails are limited to about +/-" + FormatNumber(sigmaTailCap, 2) + " sigma.")
    EndIf
  EndIf

  If isFileOutputEnabled
    LogLine("Output file: " + FormatNumber(fileSize / (1024.0*1024.0), 2, ".", ",") + " MiB -> " + outputFilePath)
  Else
    LogLine("Output file: not saved.")
  EndIf
  LogLine("Elapsed time: " + FormatDuration(elapsed / 1000.0))

  simulationIsRunning = 0
  nextThroughputLogMillis = 0

  ; Update the compact plot status line.
  Protected zDone.d
  If sigmaHeads > 0.0
    zDone = maxDeviationAbsoluteOverall / sigmaHeads
  Else
    zDone = 0.0
  EndIf
  DrawProgressCanvas(100)
  SetPlotStatusLine("Finished", 100, -1.0, avgFlipsPerMs, -1.0, maxDeviationAbsoluteOverall, maxDeviationPercentOverall, zDone)

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


; ------------------------------------------------------------------------------
; Procedure: StopSimulation()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure StopSimulation()
  If simulationIsRunning
    stopRequested = 1
    LogLine("Stop requested. Waiting for workers to finish their current batch...")
  EndIf
EndProcedure


; ------------------------------------------------------------------------------
; Procedure: BuildGUI()
; Purpose  : (see inline comments in the procedure body)
; ------------------------------------------------------------------------------
Procedure BuildGUI()
  ; Create the main window and all gadgets.
  ;
  ; Layout Guide:
  ;   Edit the constants in the "Layout Guide (GUI)" section near the top.

  gBaseTitle = "Coin-Flip Deviation Simulator (GUI) " + #ProgramVersion$
  Protected winW_PB.i = PhysToPB_X(#WIN_W)
  Protected winH_PB.i = PhysToPB_Y(#WIN_H)
  OpenWindow(#WinMain, 0, 0, winW_PB, winH_PB, gBaseTitle, #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_MinimizeGadget | #PB_Window_SizeGadget | #PB_Window_MaximizeGadget)
  SetWindowCallback(@MainWinCB(), #WinMain)
  WindowBounds(#WinMain, PhysToPB_X(#WIN_MIN_W), PhysToPB_Y(#WIN_MIN_H), #PB_Ignore, #PB_Ignore)

  ; Ensure the outer (frame) size matches #WIN_W x #WIN_H exactly.
  SetMainWindowFrameSize(winW_PB, winH_PB)
  UpdateMainWindowTitle()
  BuildMenuBar()
  BuildPopupMenus()

  ; Create gadgets (positions will be set by ApplyLayout()).
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
  TextGadget(#G_PlotInfo, 0, 0, 1, 1, "", #PB_Text_Border)
  ; Live status area: light yellow background for visibility (requested).
  SetGadgetColor(#G_PlotInfoLabel, #PB_Gadget_BackColor, RGB(255,255,192))
  SetGadgetColor(#G_PlotInfo,      #PB_Gadget_BackColor, RGB(255,255,192))

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

  TextGadget(#G_Derived, 0, 0, 1, 1, "")

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
  ButtonGadget(#G_ClearLog, 0, 0, 1, 1, "Clear")
  ButtonGadget(#G_CopyLog,  0, 0, 1, 1, "Copy")
  EditorGadget(#G_Log, 0, 0, 1, 1, #PB_Editor_ReadOnly)

  ; Subclass the RichEdit behind EditorGadget so right-click reliably shows a context menu.
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    gLogOldProc = SetWindowLongPtr_(GadgetID(#G_Log), #GWL_WNDPROC, @LogWndProc())
  CompilerEndIf

  ; Plot
  CanvasGadget(#G_PlotCanvas, 0, 0, 1, 1)

  ; Timers / UI rules
  AddWindowTimer(#WinMain, #TIMER_UI, #TIMER_UI_MS)
  AddWindowTimer(#WinMain, #TIMER_PLOT, #TIMER_PLOT_MS)

  ApplyConfigurationUIRules()
  ApplyPlotUIRules()
  ApplyLayout()
  UpdateDerivedInfo()
  SetPlotStatusLine("Ready", 0, -1.0, -1.0, -1.0, -1, 0.0, 0.0)

  ; Tooltips
  GadgetToolTip(#G_Instances, "Samples per run-block per thread.")
  GadgetToolTip(#G_Runs, "Run-blocks per thread. Total samples = Threads x Instances x Runs.")
  GadgetToolTip(#G_Flips, "Flips per sample (n). Default is 350,757.")
  GadgetToolTip(#G_BufferMiB, "Buffer size for the output file writer (MiB).")
  GadgetToolTip(#G_LocalBatch, "How many samples a worker processes before updating shared progress counters.")
  GadgetToolTip(#G_SamplerMode, "Choose BIT-EXACT (bitstream+popcount) or BINOMIAL (sample heads directly).")
  GadgetToolTip(#G_BinomMethod, "0=BTPE exact, 1=BTRD exact, 2=CLT K approx, 3=CPython exact.")
  GadgetToolTip(#G_BinomK, "CLT K: only used when Binomial method = 2 (CLT).")
  GadgetToolTip(#G_ForceKernel, "BIT-EXACT kernel policy (ignored when BINOMIAL).")
  GadgetToolTip(#G_SaveToFile, "Save deviations to a .data file (16-bit clamped).")
  GadgetToolTip(#G_OutputPath, "Output file path (used when Save output file is enabled).")
  GadgetToolTip(#G_BrowsePath, "Choose output file location.")
  GadgetToolTip(#G_ThreadPolicy, "How many worker threads to use.")
  GadgetToolTip(#G_CustomThreads, "Custom thread count (only when Thread policy = Custom).")
  GadgetToolTip(#G_Start, "Start the simulation.")
  GadgetToolTip(#G_Stop, "Request a graceful stop.")
  GadgetToolTip(#G_Reset, "Reset to defaults. If running, it will stop first, then reset.")
  GadgetToolTip(#G_Progress, "Overall progress (percent complete).")
  GadgetToolTip(#G_ClearLog, "Clear the log window.")
  GadgetToolTip(#G_CopyLog, "Copy log to the clipboard.")
  GadgetToolTip(#G_Log, "Run log and progress messages.")
  GadgetToolTip(#G_LiveGraph, "Enable/disable live plot updates during a run. Disable for max speed.")
  GadgetToolTip(#G_LoadData, "Load a saved .data file into the plot (only when stopped).")
  GadgetToolTip(#G_PlotThreshold, "Deviation threshold for plot marker and >= threshold counts (editable when stopped).")
  GadgetToolTip(#G_PlotCanvas, "Deviation distribution plot (bell curve + markers).")
  GadgetToolTip(#G_PlotInfoLabel, "Live status label.")
  GadgetToolTip(#G_PlotInfo, "Live run summary: progress, ETA, throughput, and max deviation.")

EndProcedure

InitDpiScale()
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

      ; Hide startup transients until we have enough elapsed time.
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
        Case #Menu_HelpHelp
          ShowHelp()
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

        Case #G_SamplerMode, #G_BinomMethod
          ApplyConfigurationUIRules()
          UpdateDerivedInfo()

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
          ; Option 1: apply + resize only when user commits (Enter) or leaves the field.
          If simulationIsRunning = 0 And GetGadgetState(#G_ThreadPolicy) = 2
            If IsCommitEditEvent(EventType(), EventData())
              ApplyThreadUIRules()
              UpdateDerivedInfo()
              UpdateDistributionPlot()
              While WindowEvent() : Wend
              If EnsureWorkerPool(workerThreadCount) = 0
                MessageRequester("Error", "Failed to create worker pool (" + Str(workerThreadCount) + " threads).", #PB_MessageRequester_Error)
              EndIf
            EndIf
          EndIf

        Case #G_PlotThreshold
          If simulationIsRunning = 0
            If IsCommitEditEvent(EventType(), EventData())
              ApplyPlotUIRules()
            EndIf
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

  EndSelect

ForEver


ShutdownWorkerPool()

End
; IDE Options = PureBasic 6.30 (Windows - x64)
; CursorPosition = 189
; FirstLine = 180
; Folding = ----------------------
; Optimizer
; EnableAsm
; EnableThread
; EnableXP
; UseIcon = Awicons-Vista-Artistic-Coin.ico
; Executable = C:\Users\JT\Desktop\CoinFlips.exe
; DisableDebugger
; EnablePurifier