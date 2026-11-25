# Headroom: benchmarks

Headroom's performance suite: launch time, scan time, memory, search latency and rendering, measured the same way on
every run and kept with the code, so a regression can be traced to the change that caused it.

## Running

```
benchmarks/run.py --label "what changed"       working tree, three rounds, recorded
benchmarks/run.py --compare HEAD               working tree against the last commit, rounds interleaved, both recorded
benchmarks/run.py --commit <sha>               an older commit, to backfill history or bisect a regression
benchmarks/run.py --only search,typing         selected scenarios, not recorded
benchmarks/run.py --view                       open the dashboard
benchmarks/run.py --log                        regenerate the log tables below from log.jsonl
benchmarks/run.py --float                      the ring scenario's window in front of yours at once (see below)
```

Run the suite before committing any change that could affect a metric (scan, map, rendering, search, memory, launch
work), with a `--label` describing the change. A full run takes about 15 minutes for one build and 30 for two. Measure
on AC power with no heavy apps running.

Before each scenario the suite records system conditions: other processes' CPU (by name only), load average, power
source, thermal state and Low Power Mode. A run is **under load** when another process averaged half a core or more,
all others together a full core, the thermal state was elevated, or Low Power Mode was on. Timings from a run under
load aren't compared with a separate run; interleaved runs (`--compare`) are, since both builds saw the same conditions.

The suite also records whether the display was on. With the screen locked or the display asleep nothing is rendered:
memory reads about 190 MB lower and short tasks run slower. Such runs are compared only with runs made the same way, or
interleaved.

Hitches can only be measured on frames that reach the screen, and macOS doesn't composite a window covered by others.
The ring scenario therefore puts its test window in front of every other window (without focus) for about 15 s a round,
but only when the keyboard and mouse have been idle for 5 minutes. Otherwise it stays where it opened, behind your
windows, and if they cover it that run records no hitches or max frame time. The sweep's first 2–3 frames never reach
the screen even with the window in view; the rest do. `--float` skips the wait: an agent passes it only when the owner
has said they won't use the Mac meanwhile.

Each run builds a release binary, signed as `build.sh` signs it so it keeps Full Disk Access, and launches it in script
mode (`--script`) on this Mac's own disk, once per scenario per round. Scripted instances keep their data separate
(`Application Support/Headroom-check`). The user's own records (`backup.json`, `agents.json`) are checked before and
after, and any change is reported. Scenarios only read the disk; none deletes or moves anything.

## Data

- `benchmarks/results.jsonl`: the results, one line per build per run, append-only, kept in git. Each line has the run
  time, commit hash, subject and date, whether the working tree was dirty, the label, the machine (model, chip, cores,
  memory, macOS), the disk (files and nodes scanned), the load average, and each metric's median, min and max across
  rounds. Numbers only: no file names, no paths.
- `benchmarks/log.jsonl`: the log of what changed a metric and why, and what's still open (see "Log" below).
- `benchmarks/index.html`: the dashboard, opened by `run.py --view`, which also writes its data (`data.js`, not kept).
  Each tab has its own URL:
  - **Metrics:** every metric with its history, latest value, change from the previous run and `DESIGN.md` reference
    value; filters for group, changed only, open items only, or name. Click a metric for its chart: runs filled,
    historical data points hollow, runs under load ringed in yellow, display-off runs ringed in blue, each run's
    min–max range, and a marker for each log entry.
  - **Log:** open items first, then resolved entries, newest first.
  - **Runs:** every run with its system conditions; click one for all its metrics, select two to compare.
  - **Compare:** any two runs side by side, with each change and whether it's outside noise.
- `benchmarks/scenarios/`: the scripts each scenario runs. `benchmarks/out/` (not in git): builds and logs.

A metric counts as a **regression** or an **improvement** only when it moved more than 10% and the two runs' min–max
ranges don't overlap. Anything smaller is noise on this Mac: the same build varies 10 to 20% from run to run.

**Bisecting a regression:** run `--commit` on commits between the last good run and the first bad one, halving the
range each time, as `git bisect` does. If an old commit can't run a scenario (a script step it doesn't have), those
metrics are left out of its record and the rest are kept.

## Metrics

| Group | Metric | Method |
|---|---|---|
| Launch | `launch.scan_began_ms` | Cold launch (`--no-cache`): process start to scan start, as the script first observes it. The first poll comes after window layout, about 150 ms after the actual scan start |
| Launch | `launch.scan_started_ms` | The same, from the app's own timestamp for scan start (builds since `215bc71`) |
| Launch | `launch.first_picture_ms` | Process start to first frame of the map |
| Launch | `launch.half_placed_s` | Scan start to 50% of used bytes on the map |
| Launch | `launch.placed_at_1s_pct` | Share of used bytes on the map 1 s after scan start |
| Launch | `launch.everything_read_s` | Scan start to scan complete |
| Launch | `refresh.saved_map_load_ms` | Warm launch (saved scan): scan cache load |
| Launch | `refresh.first_picture_ms` | Process start to first frame from the scan cache |
| Launch | `refresh.done_s` | The incremental scan after it, from scan start, right after a full scan (so little has changed) |
| Launch | `rescan.s` | ⌘R: full rescan at full priority |
| Memory | `launch.memory_peak_mb`, `refresh.memory_peak_mb`, `rescan.memory_peak_mb` | Peak memory (`phys_footprint` peak) |
| Memory | `rest.memory_mb` | Idle, 20 s after a cold launch, window on screen |
| Memory | `rest.cpu_pct` | CPU over the next 5 s, share of one core |
| Memory | `ring.memory_moving_mb`, `ring.memory_still_mb` | During map animation, and 2 s after it stops |
| Memory | `typing.memory_mb` | After typing a search |
| Memory | `saved.map_mb`, `app.size_mb` | Scan cache size on disk; app bundle size |
| Search | `search.small_files_ms`, `search.total_ms` | A new search, median over five queries (`md`, `zz`, `readme`, `pa`, `blå`): small-file index only, and total with the map |
| Search | `typing.*` | Typing `package.json`, one key every 0.25 s: app CPU, main-thread utilization, max keystroke latency, and keystrokes over 16 ms |
| Rendering | `ring.hitches`, `ring.longest_gap_ms`, `ring.frame_cpu_p95_ms` | Pointer swept across the map for 4 s, the window in front of other windows (not focused): hitches, max frame time, frame CPU time at p95. Hitches and max frame time are not recorded when a frame between two shown frames never reached the screen, or when fewer than 90% did; a run's first frames before its first one on screen don't count against it. Frame CPU time runs from getting a drawable to sending the frame; until 2026-11-25 it included the wait for a drawable |
| Rendering | `ring.gpu_frame_ms` | The frame with a segment pointed at, drawn 60 times back to back at the screen's size: GPU time per frame, median of 5 batches. Until 2026-11-25, `ring.frame_gpu_p95_ms`: each frame's own GPU time during the sweep, which reads 4–5× higher because a GPU drawing one frame a refresh runs at a low clock |
| Checks | `copies.s` | Copies view opened: duplicate detection with a warm cache |
| Microbenchmarks | `bench.*` | The script's `bench` step: about 50 operations timed in ms (layout, labels, hover, zoom, searches, pre-clean checks, folder sizes, suggestions, scan cache save and load) |

## Results

### 2026-11-24: working tree against the previous commit

First run of the suite: the working tree (search 5× cheaper with incremental filtering, map search off the main thread,
Sort By, list names truncated as on the map) against `9ff7930`, three interleaved rounds, on an M5 MacBook Air (4
performance and 6 efficiency cores, macOS 27.3) with 1.65 million files scanned, 300,000 of them on the map. `9ff7930`'s
build got the same measurement steps and one search per script step, as typing does, so both ran the same script.

Outside noise:

| | `9ff7930` | Now | |
|---|---|---|---|
| Typing `package.json`: CPU | 32.7% of a core | 17.9% | −45% |
| Search latency, small-file index | 12.8 ms | 7.0 ms | −45%; 8.1 ms with map search running alongside |
| Map search: `node_modules`, `ø`, `blåbær` | 1.57, 2.37, 2.36 ms | 1.82, 2.76, 2.71 ms | +15–17%: the incremental-filtering refactor called the match check through a closure, which can't be inlined. Fixed: see the log |

Everything else (about 65 metrics) was within noise: scan, incremental scan, ⌘R, memory, rendering, checks, scan cache
save and load. Typing main-thread utilization (9.6% against 11.4%) and max keystroke latency (42 against 44 ms) have
overlapping ranges.

### Current against DESIGN.md's reference values

DESIGN.md's numbers were measured by hand from 2026-11-05, with other methods, on a disk that has changed since (2.1
million files then, 1.65 million scanned now). They're reference values, not a baseline. Where a number differs a lot,
the run history should show when it moved.

| | DESIGN.md | Current |
|---|---|---|
| Cold scan: time to 50% of used bytes | 0.4 s | 0.20 s from scan start, plus 0.6 s from process start to scan start, which wasn't counted before |
| Cold scan: used bytes at 1 s | 72–81% | 77% |
| Cold scan: total time | 7.7 s, with the remainder at low priority after the first frame | 9.0 s |
| ⌘R | 6.9 s | 7.8 s |
| Scan cache load at launch | 10–25 ms | 26 ms in the app, 17 ms standalone |
| Cold launch: peak memory | 450–480 MB | 437 MB |
| Idle memory, window on screen | 130–150 MB | 321 MB, the same from 20 s to 3 minutes after a cold launch. 144 MB of it was the precomputed Backup side-by-side map; it no longer holds path strings, and idle memory is about 198 MB with it (see the log) |
| During map animation | 220–260 MB overhead for rendering | 427 MB, 168 MB more than 2 s after it stops |
| Scan cache size | 3.2 MB | 4.0 MB |
| App bundle size | 6.7 MB | 10.1 MB |
| Map layout | under 1 ms | 0.30 ms |
| Folder size: `~/Library` | 1.7 s | 2.1 s |
| Folder size: `~/dev` | 0.55 s | 0.77 s |
| Pre-clean check, all items: cold, warm, incremental | 0.35 s, 0.2 s, 9 ms (47 items) | 0.45 s, 0.28 s, 13 ms (70 items, 89 paths) |
| Pointer sweep | no hitches | no hitches in 4 s, max frame time 16.7 ms |

## Historical data

The results also hold 47 sets of numbers from before the suite existed, collected from DESIGN.md and the README as each
version stated them (`"source": "noted"`), commit messages, and the output of scripted runs kept in old session
transcripts and scratch logs (`"source": "logged"`). Each names its source and the commit it was measured on (for logs,
a working tree just after that commit). They were measured with other methods, so the dashboard draws them hollow and
never compares a run with them. What they show:

- **Idle memory:** 145 MB at the first commit (2026-11-05), about 180–200 MB during the Free Up work, 130–150 MB after
  the first memory optimization pass, 96 MB after the switch to a 10-bit render buffer (2026-11-06), 118–140 MB on
  2026-11-06 and 07. No measurements after that until the suite's first run, at 321 MB, which turned out to be the
  precomputed Backup map (2026-11-23).
- **⌘R:** 6.2–6.8 s on the first day, 6.9 s in DESIGN.md after that, 7.8 s now. The scan does more work since (it
  indexes small-file names during the scan, for one); which part costs the extra second hasn't been profiled.
- **Cold scan, total time:** 13–14 s when the remainder ran at low priority (2026-11-05), 5.6 s once the first scan
  stayed at full priority (2026-11-07), 6.8 s in the small-file comparison the morning of 2026-11-24, 8.2–9.0 s in the
  suite. The suite's instances set their window size first and the system was under more load; that 6.8 → 8.6 s for the
  same code is the cross-session variance the suite's interleaved rounds are meant to avoid.
- **Checks and folder sizes:** pre-clean check, all items went from 1,815 to 352 ms and `~/Library` size from 8.1 to
  1.74 s within an hour on 2026-11-05 (parallel folder traversal, fewer flushes). They're 453 ms and 2.1 s now, with 70
  items checked instead of 47.
- **Rendering:** 1 to 13 hitches per pointer sweep in probe builds, none since rendering moved to its own thread
  (2026-11-07), and none now.

## Log

`benchmarks/log.jsonl` records what changed a metric and why, one entry per line, and what's still open. It's kept with
the results, shown on the dashboard beside the metrics, and written into the two tables below by `run.py --log`. Edit
the file, never the tables.

```json
{"date": "2026-11-24", "commit": "after 9ff7930", "metrics": ["rest.memory_mb"], "moved": "304.5 → 197.5 MB",
 "why": "the cause, in one line", "verdict": "improved"}
```

The verdict key is one of `fixed` (a regression reverted; shown as "fixed"), `improved` (a deliberate optimization;
"optimization"), `better` (an improvement from other work; "improvement"), `feature cost` (a feature's cost, accepted;
"accepted cost"), `measuring` (the measurement changed, not the app; "measurement artifact"), `open` (to investigate)
or `proposal` (a change that needs the owner's approval). A resolved `open` item keeps its entry and gets a new one
with the finding; `"source": "history"` marks entries reconstructed from before the suite.

### Open

<!-- open:start -->
| Date | Commit | Metrics | Change | Cause | Verdict |
|---|---|---|---|---|---|
| 2026-11-24 | d9e6947 on perf/open-items | `typing.longest_ms`, `typing.over_16ms` | Max keystroke latency about 11 ms instead of 25–50 ms | Defer the results list by at least 16 ms after the key so the keystroke's own frame renders first; the list's frame stays 20–33 ms. Prototyped with the screen locked, not committed. Changes when the list updates: the owner's call | proposal |
| 2026-11-24 | 4f0dbad on perf/open-items | `typing.memory_mb`, `ring.memory_moving_mb`, `ring.memory_still_mb` | Memory after a warm-launch refresh 159–165 → 177–183 MB; typing.memory_mb 157 → 188 in the record | Since 4f0dbad. Live heap 4 MB smaller; the rest is freed heap the allocator keeps. The old 120 MB spike, freed at once, made it return such pages; malloc_zone_pressure_relief returns nothing. Source of the fragmentation not found | open |
| 2026-11-24 | 4f0dbad on perf/open-items | `rest.memory_mb` | About 40 MB of idle memory: the precomputed Backup side-by-side map | Keep it, so Backup opens instantly, or build it when the pointer reaches the mode switch | proposal |
| 2026-11-24 | after 9ff7930 | `launch.scan_began_ms`, `launch.first_picture_ms` | Time to first frame about 50 ms lower (596 → 630 ms with the menu, median of 8 launches) | The toolbar's Sort By SwiftUI menu is built with the window after scan start: it delays the first frame, not the scan. Built on click as an AppKit menu it would cost nothing at launch, but it opens differently | proposal |
| 2026-11-24 | 215bc71 on perf/open-items | `launch.scan_started_ms` | Scan start about 70–90 ms sooner, and 17 ms more with Backup drives enumerated after scan start | Start the scan before the window exists. Untried: it reorders AppModel.start() | proposal |
| 2026-11-25 | after 9ff7930 | `bench.check_one_thing`, `bench.open_files` | Single-item check 330 → 518 ms; open files 8.2 → 13.0 ms against the Nov 12 build (61b27fc), interleaved, same disk | Cause not found yet | open |
| 2026-11-25 | perf/round-2-early-stop on perf/round-2 | `bench.check_one_thing`, `bench.newest_change_40_000_files` | Single-item check 300–520 → 142–162 ms; 40,000-file look 410/1,040 → 424–480 ms (three runs, prototype) | Check the look's limit before every getattrlistbulk batch, so a look that has reached its limit leaves the flat folders its threads are in. Not merged: a quick look would read about 40,000 entries and no more, where today it also finishes those folders, so a changed file in the rest of one is no longer seen by chance. One commit on the branch perf/round-2-early-stop | proposal |
| 2026-11-25 | 357cc61 on perf/round-2 | `rest.memory_mb`, `typing.memory_mb` | Heap fragmentation at rest: default malloc zone 37–42 MB allocated, 72–76 MB resident. 23–24 MB of the gap is already there when the scan ends, before the Backup map is built; the build adds about 11 MB | Narrows the open item of 2026-11-24: PairPicture.build is not the main source. The scan itself leaves 23 MB of freed small-zone pages (vmmap right after the scan: 32 MB allocated, 56 MB resident). Not traced further. The Backup map's own cost is 29 MB of mapped tables (95 bytes a node: the same tables as any map), 5–9 MB of heap and that 11 MB | open |
| 2026-11-25 | abe5052 on perf/round-2 | `ring.memory_moving_mb`, `ring.memory_still_mb` | During animation about 170 MB above idle, unchanged | By design: two full-resolution rgba16Float targets (pieces and glow, 2800×1800: 40 MB each), six blur levels (13 MB) and up to three drawables (20–40 MB each) exist only while the ring draws, and are marked volatile when it stops. Cutting it changes the picture or the pacing: a 4-byte glow target (rg11b10Float) or a half-resolution glow pass would save 20–30 MB, two drawables instead of three 20–40 MB. Not tried | proposal |
| 2026-11-25 | 34352a8 on perf/round-2 | `bench.search_mkv`, `bench.search_node_modules`, `bench.search_oe`, `bench.search_blaabaer` | In the recorded run of 34352a8: mkv 5.18, node_modules 2.72, ø 3.80, blåbær 3.32 ms, against 4.0, 2.1, 3.5, 3.1 for the base in an interleaved run an hour earlier | Flagged as a regression by the run. Not confirmed and not ruled out: in 8 alternating bench-only runs the best cases are equal and the medians 0–25% apart, and one build varies ±25% between runs on these 2–5 ms timings. To settle it, time each search over a few hundred rounds in one process, both builds alternating | open |
<!-- open:end -->

### Resolved

<!-- log:start -->
| Date | Commit | Metrics | Change | Cause | Verdict |
|---|---|---|---|---|---|
| 2026-11-25 | after 0713e19 on perf/round-2 | `ring.frame_cpu_p95_ms` | Frame CPU time p95 0.60 ms (34352a8, window covered) → 1.94 and 17.28 ms in two rounds with the window floated and the Mac busy → 0.58 ms with the new timing (window on screen), 0.52 and 0.49 ms floated, the Mac busy again (none recorded) | Frame CPU time ran from before nextDrawable() to the commit, so it included the wait for a free drawable. It now runs from getting a drawable to sending the frame, and the pacing line reports the wait apart as drawable wait. In the two floated rounds with the new timing that wait was 1.82 and 1.95 ms at p95 (34.8 ms at most), beside 0.52 and 0.49 ms of work: the earlier 1.94 ms is about their sum. The 17.28 ms round, a median of 16.63 ms or about one 60 Hz refresh, fits the same wait but wasn't reproduced. Earlier records include the wait, which was small in them (p95 0.3–0.6 ms) | measurement artifact |
| 2026-11-25 | after 0713e19 on perf/round-2 | `ring.frame_gpu_p95_ms`, `ring.gpu_frame_ms` | Frame GPU time 4.0–8.2 ms (p95, during the sweep, 6–25 Nov) → 0.93 ms a frame with the GPU busy (unrecorded run, rounds 1 and 3; round 2 dropped: the window was clicked) | The old figure is each frame's own GPU time (gpuEndTime − gpuStartTime) while one frame is drawn each 60 Hz refresh, when the GPU is mostly idle and runs at a low clock. The renderer alone at this map's size (442 segments, 2032×1800): 1.23 ms a frame drawn back to back (1.01 ms without bloom), 5.4 ms each when paced at 60 Hz. Now recorded as ring.gpu_frame_ms by the script's gpucost step; ring.frame_gpu_p95_ms is no longer recorded | measurement artifact |
| 2026-11-25 | 34352a8 on perf/round-2 | `ring.hitches`, `ring.longest_gap_ms` | Pointer sweep in the recorded run of 34352a8: 0 hitches, max frame time 0 ms. No data: removed from the record | In all three rounds 253 of 253 frames were drawn and never shown. The test copy opens in the background (open -g), behind other apps' windows, and macOS doesn't composite a covered window; builds back to ede82cd do the same on today's screen. The ring scenario now brings its window in front of other windows without focusing it (float step) once the keyboard and mouse have been idle 5 minutes, or with --float. With the window on screen (5 unrecorded rounds on 25 Nov, 4 of them floated) every frame was shown but the sweep's first 2 to 4; 4 rounds had 0 hitches and max frame time 16.7 ms, one had 2 hitches and 33.3 ms in the sweep's last frames with the Mac busy. Frames still in flight when the notes are read no longer count as never shown; run.py records hitches and max frame time only when no frame between two shown ones was lost and at least 90% were shown. The covered window also lowered that run's memory peaks (the peak memory entry for 34352a8): 315 MB moving and 168 MB still, against 349–359 and 181–190 MB in the rounds on screen, and 360 and 192 MB on 24 Nov | measurement artifact |
| 2026-11-25 | 34352a8 on perf/round-2 | `launch.memory_peak_mb`, `refresh.memory_peak_mb`, `rescan.memory_peak_mb`, `ring.memory_moving_mb`, `typing.memory_mb` | Peak memory, display on, recorded run of 34352a8: cold launch 361, warm launch 400, full rescan 396 MB; during animation 315, after typing 306 MB. Interleaved an hour earlier, display on: base 435 / 449, this branch 430 / 448 MB (cold / warm) | First display-on figures since 4f0dbad (before it: 543 and 537 MB). Nothing on this branch changes the peaks: base and branch are equal when interleaved. The 50–70 MB between the two sessions is not from the code. Likely the display: the drawables are 8 bytes a pixel while the screen has EDR headroom above 1.5 and 4 below it, and up to three are live during a scan. Not verified | measurement artifact |
| 2026-11-25 | abe5052 on perf/round-2 | `app.size_mb` | App bundle 10.12 → 10.16 MB | This branch adds about 40 KB of code. The linker already dead-strips (a build with -dead_strip is byte-for-byte the same size); 4.4 MB is the icon's Assets.car, 5.66 MB the stripped binary. Unused code wasn't searched for: no tool for it is installed | accepted cost |
| 2026-11-25 | abe5052 on perf/round-2 | `bench.reclaimable_biggest`, `bench.story_biggest` | Accounting.reclaimable 0.23 or 0.5–0.6 ms, Accounting.story 0.15 or 0.33 ms on the same build, run to run | Not a regression: both are bimodal by about 2× between runs of one binary (the base build reads 0.48/0.16 and 0.52/0.32). Each is one pass over the hard-link records, about 3 ns a record. Left as is | measurement artifact |
| 2026-11-25 | abe5052 on perf/round-2 | `typing.main_pct`, `typing.longest_ms`, `typing.over_16ms`, `typing.cpu_pct` | Typing, interleaved, display on: main-thread utilization 11.6 → 10.4%, max keystroke latency 59.8 → 52.2 ms, keystrokes over 16 ms 10 → 10, CPU 21.9 → 21.5% | Profile of the main thread while typing (1 ms samples, 557 busy): SwiftUI graph update 52% (LazyVStack measuring and placing rows, row bodies), AppKit window layout in the CA commit 40% (NSHostingView.layout 12%, NSToolbarView 6%, drag regions 6%), Headroom's own code 14% (FittedText width measuring 5%, small-file rows 2.5%, ListNames 2.5%). Changed: the width cache is keyed by font identity and text instead of an interpolated string, and the share hairline is one Shape instead of a GeometryReader (search list pixel-identical to base). Tried: no second layout pass for fitted names (onGeometryChange removed): 11.9 → 11.3%, noise, so that isn't it. The per-key cost is row construction and window layout inside SwiftUI/AppKit; the deferral proposal of 2026-11-24 still stands | optimization |
| 2026-11-25 | 357cc61 on perf/round-2 | `rest.memory_mb` | Live heap with the Backup map precomputed 47.6 → 43.9 MB (heap -s, cold launch, at rest); idle footprint not separable from run-to-run variance (175–209 MB on the same build) | The path-hash → node dictionary was reserved for every node of the map (one 7.8 MB allocation); after the build it's a sorted (key, node) table searched by bisection. Idle footprint is bimodal by about 30 MB between runs of one build, so memory changes under 30 MB need heap or vmmap figures, not rest.memory_mb | optimization |
| 2026-11-25 | 1c65454 on perf/round-2 | `launch.scan_started_ms`, `launch.first_picture_ms`, `refresh.first_picture_ms` | Scan start 60–80 ms sooner by the app's clock (traced: process start → scan start 295 → 216–228 ms at equal pre-main time); interleaved under load: cold scan start 465 → 255 ms, cold first frame 650 → 433 ms, warm first frame 552 → 480 ms (ranges overlap) | AppModel.start() ran 42 ms of blocking reads on the main thread after the window appeared: Backup drive enumeration 18 ms, the Full Disk Access probe 5 ms twice, scan cache load 8–20 ms; and AppModel.init decoded the duplicates record (10 ms). The first three now run on background threads from main.swift, in parallel with AppKit/SwiftUI init, and are taken in start(); the duplicates record is decoded on first use. Warm launch is slower than cold because both wait about 175 ms of main-thread time for the first window layout after start() (62% of it building and laying out the NSToolbar), and the cached map is applied on the main queue after that | optimization |
| 2026-11-25 | 08facb9 on perf/round-2 | `bench.gather_facts_afresh` | Facts.gather, cold 211 → 97 ms (interleaved); warm unchanged (8.7 vs 9.2 ms, noise) | It was I/O waits in series: per app about 15 stats and directory listings plus a Spotlight XPC query, per repository two git subprocesses, per video an MDItem query, per frame folder a listing. They're collected first and run with concurrentPerform, results kept in list order. Also hoisted: ~/Library/Group Containers was listed once per installed app | optimization |
| 2026-11-25 | bdc78af on perf/round-2 | `bench.open_files`, `bench.check_one_thing`, `bench.newest_change_40_000_files` | Resolves the open item of 2026-11-25: open files is now 3.9 ms; the single-item check (300–520 ms) and the 40,000-file look (410 or 1,040 ms) are bimodal on every build | Both walk ~/Library with a 40,000-entry limit, but the limit is only checked between folders: threads already inside a flat folder finish it. Timed per folder: ~/Library/Caches/Google/… 64,642 entries 340–520 ms, five CoreSpotlight folders of about 9,000 entries 130–210 ms each, Preferences 12,499 entries up to 550 ms, against 24 ms for Preferences read alone (2 µs an entry): six threads in getattrlistbulk on one volume contend. Which mode a run lands in depends on which of these folders are in flight when the limit is reached. Attribute set and buffer size make no difference (24 ms for all variants); 2, 4, 6 and 10 threads were tried, 6 stays the best | measurement artifact |
| 2026-11-25 | bdc78af on perf/round-2 | `bench.open_files`, `bench.check_them_all_while_ticking`, `bench.check_them_all_first_time`, `bench.check_them_all_again` | OpenFiles.snapshot 8.4 → 3.9 ms; all-items check, incremental 7.9 → 4.2 ms, cold 340 → 295 ms, warm 211 → 206 ms (interleaved) | Snapshot: one proc_pidfdinfo syscall per open file of every process, serial; now spread over the cores in shares of 8 processes, merged in pid-list order so the result is the same. Checks: each planned path was walked on its own (6 threads started per path, mostly idle on small folders); all paths of a check now share one pool with a limit and a result per path. The warm all-items check stays at about 205 ms: it is bounded by a few flat folders of 10,000–65,000 entries, read by one thread each | optimization |
| 2026-11-25 | abe5052 on perf/round-2 | `bench.search_a`, `bench.search_mkv`, `bench.search_node_modules`, `bench.search_oe`, `bench.search_blaabaer` | Search.run("a") 14.0–15.8 → 7.9–10.2 ms (8 alternating runs). The other four: best case equal (mkv 3.27 vs 3.23, node_modules 1.96 vs 1.96, ø 3.13 vs 3.17 ms), medians 0–25% higher on this branch (mkv 4.8 vs 4.2, node_modules 2.45 vs 2.2) | With 250,000 matches about 10 of the 15 ms was the comparison sort, each compare two cache misses into the totals table: over 4,096 matches it's now an LSD radix sort on (size, node) pairs, same order (stable, ties by node). The match loop is a function of its own (@inline(never)): with the sort in the same function, or the needle passed as a buffer pointer, plain-text searches measured 10–60% slower although the loop's source was unchanged. Whether the remaining difference in the medians is code or variance isn't settled: the base Search.swift compiled into this branch reads 3.2–5.0 ms for mkv across three runs | optimization |
| 2026-11-25 | dbf3954 on perf/round-2 | `bench.save_the_map`, `bench.read_the_saved_map`, `refresh.saved_map_load_ms`, `saved.map_mb` | Scan cache save 104.6 → 22.6 ms, load 15.2 → 8.0 ms (bench, interleaved, display on); load at warm launch 21–33 → 6 ms; file 3.88 → 4.04 MB (+4%) | Save and load were one LZFSE stream on one core. The tables are now cut into 1 MB pieces, each compressed independently, encoded and decoded with concurrentPerform. New file magic: an older cache is ignored once (one full scan instead of an incremental one). What's left of the load is the single-threaded validation and re-summing | optimization |
| 2026-11-25 | after 9ff7930 | `bench.changes_map`, `bench.newest_change_40_000_files`, `bench.gather_facts_again` | Changes map 0.6–0.8 → 7.5 ms, newest changes (40,000 files) 117–394 → 406 ms, cached facts 1.7 → 8.3 ms against the Nov 5–12 records | Input, not code: the Nov 12 build (61b27fc), interleaved on today's disk, measures 7.4 ms, 316 ms and 9.6 ms | measurement artifact |
| 2026-11-24 |  | `app.size_mb`, `saved.map_mb` | App bundle 6.7 → 10.1 MB; scan cache 3.2 → 4.0 MB | Bundle: 5.6 MB of code, up from about 2.3 MB on 11-06, plus the same 4.4 MB icon. Cache: same format plus one column; the 3.2 MB was from a scan without Full Disk Access | accepted cost |
| 2026-11-24 | 215bc71 on perf/open-items | `rescan.s`, `launch.everything_read_s` | Full rescan 7.8 → 5.98 s, cold scan total 8.2–9.0 → 5.85 s, same code | System load, not the code: the slow runs had another app's renderer at a full core and Spotlight indexing. Scan only (--bench), interleaved: 7 November build 5.88, 6.08, 6.22 s; today's build 6.03, 6.11, 6.56 s | measurement artifact |
| 2026-11-24 | 215bc71 on perf/open-items | `launch.scan_began_ms`, `launch.scan_started_ms` | App start → scan start: 405 ms script-observed, 253 ms actual (idle system, screen locked). The 630 ms reading was under load with the display on | The script's launch step first polls after window layout, about 150 ms after scan start; the app now also logs the actual scan start, recorded as launch.scan_started_ms. The 253 ms: pre-main 25 ms, SwiftUI and AppKit init 75 ms, shaders 8 ms, window creation to first view 100 ms, Headroom's own 30 ms (17 ms of it enumerating Backup drives) | measurement artifact |
| 2026-11-24 | 4f0dbad on perf/open-items | `rest.memory_mb` | Idle memory breakdown: 168 MB with the screen locked; display on adds about 15 MB | Map about 30 MB; precomputed Backup map about 40 MB; UI (SwiftUI, AppKit) about 37 MB; freed heap not returned to the OS about 24 MB; the rest frameworks and other live heap | accepted cost |
| 2026-11-24 | 4f0dbad on perf/open-items | `launch.memory_peak_mb` | Cold-launch peak memory about 437 MB, unchanged | Each map snapshot during a scan copies the tree, by design (DESIGN.md: 450–480 MB) | accepted cost |
| 2026-11-24 | 4f0dbad on perf/open-items | `refresh.memory_peak_mb`, `rescan.memory_peak_mb` | Peak memory, screen locked, interleaved: warm launch 344 → 270 MB, full rescan 372 → 274 MB. Display on adds about 190 MB to each (about 540 MB before) | Both peaks were one spike: precomputing Backup's side-by-side map 1.5 s after launch built every path as a string (+170 MB, 120 MB of it freed a second later). It's now built from path hashes, one component at a time, with strings only for the few files that need one. The full rescan itself adds about 45 MB. Verified in a debug build against every path and hash on this disk: 304,521 items | fixed |
| 2026-11-24 | 86cf172 on perf/open-items | `rest.memory_mb` | Idle memory 200 → 185 MB, display on (interleaved); 183 → 170 MB, screen locked | Each map label held its own glyph paths: 10,266 paths, 15 MB. Glyph paths are now shared per font and glyph: 524, under 1 MB. Rendering unchanged | fixed |
| 2026-11-24 | d9e6947 on perf/open-items | `typing.main_pct`, `typing.longest_ms`, `typing.over_16ms` | Typing, display on, interleaved: main-thread utilization 10.4 → 8.4% (about 25 → 20 ms per key), max keystroke latency 45 → 40 ms, keystrokes over 16 ms 10 → 9 of 11 | The search field was bound to the whole window, so each keystroke rebuilt the toolbar buttons and updated the map, the centre label and the path bar. It now has an empty view of its own; same field, same position, ⌘F and Esc unchanged. Remaining per-key cost: about half AppKit toolbar layout for the field, half list-row construction. Tried and reverted, within noise: position-keyed row reuse, skipping unchanged results, a cheaper hairline and width lookup | optimization |
| 2026-11-24 | after 9ff7930 | `rescan.s`, `launch.everything_read_s`, `ring.frame_gpu_p95_ms` | 37 timings 20–50% slower than the previous run, all at once, frame GPU time included | System under load (Spotify's renderer at a full core, WindowServer 39%) in a run that didn't interleave builds. Not a code regression: memory, which load doesn't affect, was as expected | measurement artifact |
| 2026-11-24 | after 9ff7930 | `rest.memory_mb`, `ring.memory_moving_mb`, `ring.memory_still_mb`, `typing.memory_mb` | Idle memory 304.5 → 197.5 MB (interleaved); during animation 425 → 360 MB, after 257 → 192 MB | The precomputed Backup map derives paths from its own tree and looks items up by path hash; verified against the previous build for every path on this disk (301,073) | optimization |
| 2026-11-24 | after 9ff7930 | `bench.search_node_modules`, `bench.search_oe`, `bench.search_blaabaer` | Map search 1.57 → 1.82 ms, 2.37 → 2.76, 2.36 → 2.71; after the fix 1.65 / 2.68 / 2.71 against 1.65 / 2.54 / 2.58 | Incremental filtering called the map search's match check through a closure that was never inlined, 300,000 nodes per search; now an inlined struct method | fixed |
| 2026-11-24 | after 9ff7930 | `typing.cpu_pct`, `search.small_files_ms` | Typing CPU 32.7 → 17.9% of a core; small-file search 12.8 → 7.0 ms | Small-file index scanned 16 bytes at a time on 4 threads; each further keystroke filters only the previous matches; map search runs alongside it off the main thread | improvement |
| 2026-11-24 | 0d8113e | `rest.memory_mb` | Idle memory 130–150 MB (DESIGN.md, 11-05 to 11-07) → 305–321 MB | The faster switch to Backup (2026-11-23) precomputes Backup's side-by-side map in Free Up and keeps it resident: 309,000 path strings plus path-keyed dictionaries, 144 MB | accepted cost |
| 2026-11-07 | 5ea22d3 | `launch.everything_read_s` | Cold scan total 13–14 s → 5.6 s | First scan stays at full priority instead of dropping to low priority after the first frame | optimization |
| 2026-11-07 | 5ea22d3 | `ring.hitches` | Hitches per pointer sweep 1 to 13 → none | Map rendering moved to a dedicated thread, synced to the display | fixed |
| 2026-11-06 | 119b1fc | `rest.memory_mb`, `launch.memory_peak_mb` | Idle memory 116 → 96 MB; cold-launch peak 492 → 395 MB | Map rendered into a 10-bit buffer | optimization |
| 2026-11-05 | e04d3e5 | `bench.check_them_all_first_time`, `bench.size_of_library` | Pre-clean check, all items 1,815 → 352 ms; ~/Library size 8.1 → 1.74 s | Parallel folder traversal; fewer flushes | optimization |
<!-- log:end -->
