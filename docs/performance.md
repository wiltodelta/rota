# Local performance diagnostics

## Built-in journal

Rota starts local diagnostics with the app and records them under
`~/Library/Logs/Rota/Diagnostics`. Development builds use `Rota Dev` instead;
with `ROTA_DATA_DIR`, diagnostics stay inside that directory's `Logs` folder.
There is no upload or remote analytics service. The installed app needs a build
containing this feature; the external collector below can observe older builds.

`current.jsonl` and `previous.jsonl` form a bounded rotating journal. The byte
budget lives in `PerformanceLog.byteLimit`, not in a retention preference.
Each launch and rotation writes metadata with app version, build, bundle ID,
macOS version, CPU count and a random launch ID. Lines use local timestamps
with UTC offsets. Both files stay private to the user. Older diagnostic data
is replaced on rotation; routine history and conversation logs are unaffected.

The journal records:

- `resources`: interval CPU percentage, resident bytes, the largest completed
  main-queue probe delay, and aggregate transcript read counts and durations.
  CPU uses the process's cumulative user and system time; 100% is one core.
  Missing CPU or memory fields mean the OS measurement was unavailable.
- `main_thread_delay`: a main-queue probe that was answered late.
- `main_thread_stall`: an outstanding probe, recorded before recovery. Its
  duration is a lower bound, so evidence remains if the app never responds.
- `slow_transcript`: a slow read, with duration and item count. Periodic
  aggregates distinguish earlier-page requests and Shell reads.
- `sleep`, `wake`, and `shutdown`: lifecycle boundaries. Sleep and wake discard
  pending probes and the CPU baseline so sleep is not counted as a UI stall.

Intervals and thresholds live in `PerformanceDiagnostics`. An outstanding
probe is never duplicated, even during a long hang. Main-queue availability
is a responsiveness proxy, not frame rate or a complete UI interaction time;
brief pauses between probes can be missed. A busy machine can also delay a
probe. The recorded context is the last available main-thread snapshot:
screen category, app activation, window dimensions, routine count and active
run count. It never includes message text, routine names, session identifiers,
project paths, model prompts or credentials.
Window context uses only the main window's container and Rota's menu panel;
the small system-owned status-item window is excluded.

Transcript timing runs in the shared `TranscriptSessionReader`, so it covers
the UI readers for every harness, including both Claude modes and Shell,
without probing or changing agent protocols. It measures reading and parsing,
not network latency or SwiftUI layout. Background timers and journal writes
use a utility queue; the main queue only answers one small probe at a time.
An I/O failure disables the journal for that launch and logs the failure via
`os.Logger`; it does not fail a routine. Built-in diagnostics do not hold a
power assertion or prevent the Mac from sleeping.

Open the folder in Finder and review the matching time interval in both
files before sharing it. Keep the launch metadata with the relevant events
to identify the app build. Use the external collector's stack snapshots to
investigate where a slow interval spent time.

Tests: `swift test --filter '^RotaTests.PerformanceTests/'` covers interval
CPU, pending probes, sleep, bounded rotation, failure isolation and shared
transcript instrumentation without launching an agent.

## External collector

`scripts/performance.py` observes an already running installed app. It does
not restart Rota, change routines, register a scheduled task, or contact a
server. It uses Python's standard library and macOS `ps` and `sample`.

```bash
python3 scripts/performance.py collect
```

The collector logs its output folder under `~/Library/Logs/Rota/Performance`.
It runs for a bounded period; `--help` lists the current defaults and options.
Keep the terminal open, or run it under `nohup` for unattended collection.
Stop with Control-C, or send SIGTERM to `collector_pid` in `metadata.json`.
It follows relaunches at the same app path. `--app` selects another bundle,
including a development build; the exact executable path must match.

Each private collection folder contains:

- `metadata.json`: app version and build, macOS version, architecture and CPU
  count. A new collection is needed after an app update for new version metadata.
- `metrics.jsonl`: local timestamps with UTC offsets, process identity,
  cumulative CPU time, interval CPU percentage, resident memory, system load,
  unavailable observations and stack-capture outcomes.
- `stack-*.txt`: native stack samples after sustained high CPU, with a cooldown
  and a per-collection capture budget. Sampling can briefly add overhead.
  A macOS permission failure is recorded rather than treated as a successful capture.

CPU percentage uses differences in cumulative CPU time between observations;
100% means one CPU core, and multithreaded work can exceed that. The first
observation after a launch has no interval CPU value. RSS is resident memory,
not total allocations or a proof of a leak. Metrics describe Rota itself,
not its agent processes. The system load helps flag concurrent machine load.
The external collector cannot measure frame rate or main-thread responsiveness.
It can miss short spikes and cannot automatically detect low-CPU hangs.

During a visible slowdown, capture stacks explicitly, including low-CPU hangs:

```bash
python3 scripts/performance.py snapshot
```

Note the local time and action that felt slow, for example opening a session,
scrolling a long conversation, switching sessions, or leaving the window idle.
No conversation text, routine configuration, process arguments or environment
is collected. Native stack reports can contain executable and library paths;
the home-directory prefix is replaced with `~`. Review reports before sharing.
Nothing is uploaded automatically.

Summarize a collection while it is running or after it stops:

```bash
python3 scripts/performance.py report /path/to/collection
```

The report includes CPU percentiles and maximum, first/last/maximum RSS,
process identities, missing observations and stack outcomes. Percentiles are
over observed intervals, not an estimate of unobserved time. Use the timestamped
raw records and matching stacks to investigate a symptom. Compare the same
actions and conversation size across app versions before attributing a change
to a fix. A high process-wide CPU reading alone does not identify the cause.

Collections stop automatically and are never pruned by the script. Existing
evidence is preserved. Tests: `python3 -m unittest scripts.tests.test_performance`.
