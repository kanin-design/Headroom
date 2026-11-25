#!/usr/bin/env python3
"""Headroom's benchmarks: builds the app, runs it through scripted scenarios on this Mac's own disk, and keeps what it
measured, one line per run, in results.jsonl beside this file. See BENCHMARKS.md for what each number means.

    benchmarks/run.py                      the working tree, three rounds, recorded
    benchmarks/run.py --compare HEAD       the working tree and a commit, rounds alternating between them, both recorded
    benchmarks/run.py --commit 9ff7930     a commit of its own, to fill in history or find when something changed
    benchmarks/run.py --only search,typing a few scenarios, for a quick look (not recorded unless --record)
    benchmarks/run.py --view               the page of results, made fresh from results.jsonl and log.jsonl
    benchmarks/run.py --log                BENCHMARKS.md's log and open items, written again from log.jsonl
    benchmarks/run.py --float              the ring's window in front of yours at once, not only after 5 minutes away. An
                                           agent passes it only when the owner has said they won't use the Mac meanwhile

Scripted copies keep their data apart from yours (Application Support/Headroom-check), and nothing here writes outside
that, this folder and the build folders. Your own records are checked before and after, and any change is reported.
Only numbers are kept: no file names, no paths.
"""

import argparse, ctypes, datetime, hashlib, json, os, re, shutil, statistics, subprocess, sys, tarfile, io, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
OUT = HERE / "out"
RESULTS = HERE / "results.jsonl"
# What changed a number and why, and what's still open: one finding per line (see BENCHMARKS.md, "The log").
LOG = HERE / "log.jsonl"
DOC = REPO / "BENCHMARKS.md"
VERDICTS = ("fixed", "improved", "better", "feature cost", "measuring", "open", "proposal")
SCENARIOS = HERE / "scenarios"
HOME = Path.home()
RECORDS = [HOME / "Library/Application Support/Headroom" / name for name in ("backup.json", "agents.json")]
CHECK_DATA = HOME / "Library/Application Support/Headroom-check"
# A scenario's `float` step puts its window in front of everyone's, so its frames reach the screen. Only after this long
# without keyboard or mouse input, or with --float: otherwise the window stays behind yours.
AWAY_S = 300

# Each scenario: its steps file, what the app is opened with, and the longest it may take.
SCENARIO_ARGS = {
    "first-launch": (["--no-cache"], 300),
    "refresh": ([], 300),
    "rescan": ([], 300),
    "bench": ([], 600),
    "search": ([], 300),
    "typing": ([], 300),
    "ring": ([], 300),
    "copies": ([], 300),
}
ORDER = list(SCENARIO_ARGS)

# What's measured: unit, which way is better, group, what it is, and, where DESIGN.md noted it, that number.
CATALOGUE = {
    "launch.scan_began_ms": ("ms", "lower", "Launch", "Cold launch: time to scan start (script-observed)", None),
    "launch.scan_started_ms": ("ms", "lower", "Launch", "Cold launch: time to scan start (app-reported)", None),
    "launch.first_picture_ms": ("ms", "lower", "Launch", "Cold launch: time to first frame", 200),
    "launch.half_placed_s": ("s", "lower", "Launch", "Cold scan: time to 50% of used bytes", 0.4),
    "launch.placed_at_1s_pct": ("%", "higher", "Launch", "Cold scan: used bytes at 1 s", 76),
    "launch.everything_read_s": ("s", "lower", "Launch", "Cold scan: total time", 7.7),
    "launch.memory_peak_mb": ("MB", "lower", "Memory", "Cold launch: peak memory", 465),
    "rest.memory_mb": ("MB", "lower", "Memory", "Idle memory", 140),
    "rest.cpu_pct": ("%", "lower", "Memory", "Idle CPU", 0.0),
    "saved.map_mb": ("MB", "lower", "Memory", "Scan cache size", 3.2),
    "app.size_mb": ("MB", "lower", "Memory", "App bundle size", 6.7),
    "refresh.saved_map_load_ms": ("ms", "lower", "Launch", "Warm launch: scan cache load", 17),
    "refresh.first_picture_ms": ("ms", "lower", "Launch", "Warm launch: time to first frame", None),
    "refresh.done_s": ("s", "lower", "Launch", "Warm launch: incremental scan time", None),
    "refresh.memory_peak_mb": ("MB", "lower", "Memory", "Warm launch: peak memory", 360),
    "rescan.s": ("s", "lower", "Launch", "Full rescan (⌘R): time", 6.9),
    "rescan.memory_peak_mb": ("MB", "lower", "Memory", "Full rescan (⌘R): peak memory", None),
    "search.small_files_ms": ("ms", "lower", "Search", "Search latency: small-file index", None),
    "search.total_ms": ("ms", "lower", "Search", "Search latency: total", None),
    "typing.cpu_pct": ("%", "lower", "Search", "Typing: CPU", None),
    "typing.main_pct": ("%", "lower", "Search", "Typing: main-thread utilization", None),
    "typing.longest_ms": ("ms", "lower", "Search", "Typing: max keystroke latency", None),
    "typing.over_16ms": ("frames", "lower", "Search", "Typing: keystrokes over 16 ms", None),
    "typing.memory_mb": ("MB", "lower", "Memory", "Memory after typing", None),
    "ring.hitches": ("frames", "lower", "Rendering", "Pointer sweep: hitches", 0),
    "ring.longest_gap_ms": ("ms", "lower", "Rendering", "Pointer sweep: max frame time", None),
    "ring.frame_cpu_p95_ms": ("ms", "lower", "Rendering", "Frame CPU time, p95", None),
    "ring.gpu_frame_ms": ("ms", "lower", "Rendering", "Frame GPU time", None),
    "ring.frame_gpu_p95_ms": ("ms", "lower", "Rendering", "Frame GPU time, p95, at display rate (deprecated)", None),
    "ring.memory_moving_mb": ("MB", "lower", "Memory", "Memory during animation", None),
    "ring.memory_still_mb": ("MB", "lower", "Memory", "Memory 2 s after animation", None),
    "copies.s": ("s", "lower", "Checks", "Duplicate detection, warm cache", None),
}


def bench_metric(label):
    """A `bench` line's label as a metric name, its letters beyond A to Z written out: `search: blåbær` is
    `bench.search_blaabaer`, so no two labels end up as one name."""
    spelled = label.lower()
    for letter, out in (("æ", "ae"), ("ø", "oe"), ("å", "aa"), ("é", "e"), ("ü", "ue"), ("ö", "oe"), ("ä", "ae")):
        spelled = spelled.replace(letter, out)
    return "bench." + re.sub(r"[^a-z0-9]+", "_", spelled).strip("_")


BENCH_LABELS = {}


# Names on the page for metrics named elsewhere: the labels the app's `bench` step prints, and the definitions kept with
# records from before the suite. Keys and records stay as they are.
SHOWN = {
    "bench.changes_map": "Build Changes map",
    "bench.check_one_thing": "Pre-clean check: 1 item",
    "bench.check_one_thing_as_a_clean_does": "Pre-clean check: 1 item, thorough",
    "bench.check_them_all_first_time": "Pre-clean check: all items, cold",
    "bench.check_them_all_again": "Pre-clean check: all items, warm",
    "bench.check_them_all_while_ticking": "Pre-clean check: all items, incremental",
    "bench.facts_library": "Folder summary: ~/Library",
    "bench.facts_your_files": "Folder summary: home",
    "bench.find_by_path": "Path lookup",
    "bench.gather_facts_afresh": "Usage data collection, cold",
    "bench.gather_facts_again": "Usage data collection, warm",
    "bench.hover_line_biggest": "Hover label: largest folder",
    "bench.hover_on_hover_off": "Hover highlight on/off",
    "bench.kinds_biggest": "File-kind breakdown: largest folder",
    "bench.map_to_free_up_and_back": "View switch: Map → Free Up → Map",
    "bench.newest_change_40_000_files": "Newest change: 40,000 files",
    "bench.one_picture": "Map layout",
    "bench.open_files": "Open-files snapshot",
    "bench.pictures_biggest": "Media listing: largest folder",
    "bench.read_the_saved_map": "Scan cache load",
    "bench.reclaimable_biggest": "Reclaimable space: largest folder",
    "bench.save_the_map": "Scan cache save",
    "bench.search_a": "Search: a",
    "bench.search_mkv": "Search: mkv",
    "bench.search_node_modules": "Search: node_modules",
    "bench.search_oe": "Search: ø",
    "bench.search_blaabaer": "Search: blåbær",
    "bench.size_of_dev": "Folder size: ~/dev",
    "bench.size_of_library": "Folder size: ~/Library",
    "bench.size_of_media": "Folder size: ~/Media",
    "bench.sorting_them_into_boxes": "Suggestion grouping",
    "bench.story_biggest": "Hardlink accounting: largest folder",
    "bench.suggestions": "Suggestions build",
    "bench.the_disk_as_it_d_be_after": "Post-clean preview",
    "bench.the_list_for_this_picture": "Inspector list rebuild",
    "bench.the_menu_for_it": "Context menu build",
    "bench.the_names_around_it": "Label layout",
    "bench.the_other_copies_of_each": "Other-copies lookup",
    "bench.the_top_list": "Top-items list",
    "bench.untouched_for_a_year": "Untouched map: 1 year",
    "bench.what_s_inside_library": "Folder contents: ~/Library",
    "bench.what_they_d_free": "Space freed: top items",
    "bench.zoom_in_and_back": "Zoom in and out",
    "noted.copies_cold_s": "Duplicate detection, cold cache",
    "noted.copies_repeat_ms": "Duplicate detection, unchanged (upper bound)",
    "noted.copy_1000_small_files_s": "Copy 1,000 small files, verified",
    "noted.du_scan_s": "`du` full-disk scan (reference)",
    "noted.first_launch_quiet_read_s": "Cold scan: low-priority remainder",
    "noted.full_read_after_refresh_s": "Full rescan after warm launch",
    "noted.git_checks_s": "Git status checks, per pass",
    "noted.hover_longest_ms": "Pointer sweep: longest main-thread stall",
    "noted.hover_main_pct": "Pointer sweep: main-thread utilization",
    "noted.hover_stalls_over_16ms": "Pointer sweep: stalls over 16 ms",
    "noted.journal_query_s": "Change-journal query",
    "noted.memory_after_scan_mb": "Memory after cold scan",
    "noted.memory_after_typing_mb": "Memory after typing",
    "noted.refresh_full_power_s": "Warm launch: incremental scan, full priority",
    "noted.refresh_quiet_full_read_s": "Warm launch: full rescan, low priority",
    "noted.rest_memory_6s_after_scan_mb": "Memory 6 s after cold scan",
    "noted.rest_memory_hidden_mb": "Idle memory, window hidden",
    "noted.ring_moving_extra_mb": "Animation memory overhead",
    "noted.saved_map_save_s": "Scan cache save",
    "noted.search_names_ms": "Search latency: map only, per keystroke",
    "noted.six_thumbnails_ms": "Thumbnails: 6 images",
    "noted.small_files_catalogue_mb": "Small-file index size",
    "noted.whole_disk_scan_s": "Full-disk scan, launch type unknown",
}
# Groups as the page names them, for definitions kept with older records.
GROUPS = {"Ring": "Rendering", "Bench": "Microbenchmarks"}
# Verdicts as the page and BENCHMARKS.md show them; log.jsonl keeps the keys.
VERDICT_SHOWN = {"fixed": "fixed", "improved": "optimization", "better": "improvement", "feature cost": "accepted cost",
                 "measuring": "measurement artifact", "open": "open", "proposal": "proposal"}


# Where DESIGN.md noted a number for one of the `bench` lines.
BENCH_NOTED = {
    "size of ~/Library": 1700, "size of ~/dev": 550, "check them all, first time": 350, "check them all, again": 200,
    "check them all, while ticking": 9, "one picture": 1, "read the saved map": 10, "save the map": 80,
}


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def git(*args):
    return sh(["git", "-C", str(REPO), *args]).stdout.strip()


# MARK: Building


def source_for(commit):
    """The working tree, or a commit unpacked from git into the out folder."""
    if commit is None:
        return REPO
    full = git("rev-parse", commit)
    src = OUT / "src" / full[:10]
    if not (src / "Package.swift").exists():
        src.mkdir(parents=True, exist_ok=True)
        archive = subprocess.run(["git", "-C", str(REPO), "archive", full], capture_output=True, check=True).stdout
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            try:
                tar.extractall(src, filter="data")
            except TypeError:
                tar.extractall(src)
    return src


def build(commit):
    """A release build in a bundle of its own, signed as build.sh signs it, so it keeps Full Disk Access."""
    src = source_for(commit)
    name = (git("rev-parse", "--short=10", commit) if commit else "worktree")
    log = OUT / f"build-{name}.log"
    print(f"building {name}…", flush=True)
    done = sh(["swift", "build", "-c", "release"], cwd=src)
    log.write_text(done.stdout + done.stderr)
    if done.returncode != 0:
        sys.exit(f"build of {name} failed: see {log}")
    app = OUT / "apps" / name / "Headroom.app"
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (app / "Contents/Resources").mkdir(parents=True, exist_ok=True)
    binary = app / "Contents/MacOS/Headroom"
    binary.unlink(missing_ok=True)
    shutil.copy2(src / ".build/release/Headroom", binary)
    sh(["strip", "-x", str(binary)])
    shutil.copy2(src / "Resources/Info.plist", app / "Contents/Info.plist")
    sh(["plutil", "-replace", "CFBundleVersion", "-string", f"bench-{name}", str(app / "Contents/Info.plist")])
    for resource in ("Assets.car", "AppIcon.icns", "logo.png"):
        if (src / "Resources" / resource).exists():
            shutil.copy2(src / "Resources" / resource, app / "Contents/Resources" / resource)
    identities = sh(["security", "find-identity", "-p", "codesigning"]).stdout
    identity = "Headroom" if '"Headroom"' in identities else "-"
    if sh(["codesign", "--force", "--sign", identity, str(app)]).returncode != 0:
        sh(["codesign", "--force", "--sign", "-", str(app)])
    size = sum(f.stat().st_size for f in app.rglob("*") if f.is_file())
    return {"name": name, "app": app, "commit": commit, "size_mb": size / 1e6}


# MARK: Running


def idle_seconds():
    """How long since the keyboard or mouse was last used."""
    m = re.search(r'"HIDIdleTime" = (\d+)', sh(["ioreg", "-c", "IOHIDSystem", "-d", "4"]).stdout)
    return int(m.group(1)) / 1e9 if m else 0.0


def run_scenario(app, scenario, run_dir, float_anyway=False):
    """One scripted copy through one scenario; its log."""
    args, limit = SCENARIO_ARGS[scenario]
    steps = run_dir / f"{scenario}.txt"
    lines = (SCENARIOS / f"{scenario}.txt").read_text().splitlines()
    if "float" in lines and not float_anyway and idle_seconds() < AWAY_S:
        lines = [line for line in lines if line != "float"]
        print(f"  {scenario}: the Mac is in use, so the window isn't brought in front of yours (--float to override)", flush=True)
    steps.write_text("\n".join(lines) + "\n")
    log = run_dir / f"{scenario}.log"
    with open(log, "w") as out:
        subprocess.run(
            ["open", "-n", "-g", "--stdout", str(log), "--stderr", str(log), str(app), "--args", "-ApplePersistenceIgnoreState",
             "YES", "--script", str(steps), *args], stdout=out, stderr=out)
    time.sleep(2)
    started = time.time()
    while time.time() - started < limit:
        if sh(["pgrep", "-f", "--", f"--script {steps}"]).returncode != 0:
            break
        time.sleep(0.5)
    else:
        # Only ever the copy this run opened, found by its own steps file.
        for pid in sh(["pgrep", "-f", "--", f"--script {steps}"]).stdout.split():
            print(f"  {scenario}: over {limit} s, stopping it", flush=True)
            sh(["kill", pid])
    time.sleep(1)
    return log.read_text(errors="replace")


def number(pattern, text, cast=float):
    m = re.search(pattern, text)
    return cast(m.group(1)) if m else None


def parse(scenario, text):
    """The numbers in a scenario's log, by metric. Anything a build doesn't print is left out."""
    m = {}
    if scenario in ("first-launch", "refresh"):
        launch = re.search(
            r"launch scan began (-?\d+) ms in, first picture (-?\d+) ms in; from the scan's start: half placed (-?[\d.]+) s, "
            r"placed at 1 s (\d+)%, everything read ([\d.]+) s", text)
        if launch and scenario == "first-launch":
            began, first, half, at_one, read = (float(x) for x in launch.groups())
            m["launch.scan_began_ms"] = began
            # Builds since 215bc71 also say when the model really started the scan, before the script's first look.
            really = number(r"launch really: the scan was started (-?\d+) ms in", text)
            if really is not None and really >= 0: m["launch.scan_started_ms"] = really
            if first >= 0: m["launch.first_picture_ms"] = first
            if half >= 0: m["launch.half_placed_s"] = half
            m["launch.placed_at_1s_pct"] = at_one
            m["launch.everything_read_s"] = read
        if launch and scenario == "refresh":
            if float(launch[2]) >= 0: m["refresh.first_picture_ms"] = float(launch[2])
            m["refresh.done_s"] = float(launch[5])
        peak = number(r"memory (?:launched|refreshed): \d+ MB now, (\d+) MB at most", text)
        if peak is not None: m["launch.memory_peak_mb" if scenario == "first-launch" else "refresh.memory_peak_mb"] = peak
        if scenario == "first-launch":
            settled = number(r"memory settled: (\d+) MB now", text)
            if settled is not None: m["rest.memory_mb"] = settled
            cpu = number(r"cpu over \d+ s: ([\d.]+)% of a core", text)
            if cpu is not None: m["rest.cpu_pct"] = cpu
        if scenario == "refresh":
            load = number(r"last scan loaded in ([\d.]+) ms", text)
            if load is not None: m["refresh.saved_map_load_ms"] = load
    elif scenario == "rescan":
        s = number(r"rescan ([\d.]+) s", text)
        if s is not None: m["rescan.s"] = s
        peak = number(r"memory rescanned: \d+ MB now, (\d+) MB at most", text)
        if peak is not None: m["rescan.memory_peak_mb"] = peak
    elif scenario == "bench":
        for label, ms in re.findall(r"^bench (.+?)\s+([\d.]+) ms$", text, re.M):
            m[bench_metric(label.strip())] = float(ms)
            BENCH_LABELS[bench_metric(label.strip())] = label.strip()
    elif scenario == "search":
        small = [float(x) for x in re.findall(r"found among small files: \d+ in ([\d.]+) ms", text)]
        total = [float(x) for x in re.findall(r"searched in ([\d.]+) ms", text)]
        if small: m["search.small_files_ms"] = statistics.median(small)
        if total: m["search.total_ms"] = statistics.median(total)
    elif scenario == "typing":
        meter = re.search(r"meter typing\s+cpu\s+([\d.]+)%, main\s+([\d.]+)%, longest\s+([\d.]+) ms, over 16 ms\s+(\d+)", text)
        if meter:
            m["typing.cpu_pct"], m["typing.main_pct"] = float(meter[1]), float(meter[2])
            m["typing.longest_ms"], m["typing.over_16ms"] = float(meter[3]), float(meter[4])
        typed = number(r"memory typed: (\d+) MB now", text)
        if typed is not None: m["typing.memory_mb"] = typed
    elif scenario == "ring":
        p = re.search(
            r"pacing sweep: (\d+) frames in \d+ runs, (\d+) hitches .*?longest gap ([\d.]+) ms, (\d+) never shown"
            r"(?: \((\d+) at a run's start\))?.*?each frame cpu [\d.]+/([\d.]+)/[\d.]+ ms", text)
        if p:
            frames, unseen, at_start = int(p[1]), int(p[4]), int(p[5] or 0)
            # Hitches are gaps between frames on screen. A frame that never got there (a covered window, a sleeping display)
            # leaves nothing to measure them by, and 0 would read as none. A run's first frames, drawn before its first one
            # reached the screen, leave no gap between frames that did; they count only against the 90% that must get there.
            if frames and unseen == at_start and frames - unseen >= 0.9 * frames:
                m["ring.hitches"], m["ring.longest_gap_ms"] = float(p[2]), float(p[3])
            else:
                between = unseen - at_start
                print(f"  ring: {frames - unseen} of {frames} frames reached the screen"
                      + (f", {between} missing between frames that did" if between else "")
                      + "; hitches and max frame time not recorded", flush=True)
            if frames:
                m["ring.frame_cpu_p95_ms"] = float(p[6])
        # The paced GPU time in the same line isn't kept: a GPU drawing one frame a refresh runs at a low clock.
        gpu = number(r"gpucost: ([\d.]+) ms a frame", text)
        if gpu is not None: m["ring.gpu_frame_ms"] = gpu
        moving = number(r"memory moving: (\d+) MB now", text)
        still = number(r"memory still: (\d+) MB now", text)
        if moving is not None: m["ring.memory_moving_mb"] = moving
        if still is not None: m["ring.memory_still_mb"] = still
    elif scenario == "copies":
        s = number(r"same-size sets in ([\d.]+) s", text)
        if s is not None: m["copies.s"] = s
    return m


def disk_facts(texts):
    """How big the disk read was, from any `report`: the files and nodes it held."""
    for text in texts:
        r = re.search(r"scan [\d.]+s, (\d+) files, (\d+) nodes", text)
        if r:
            return {"files": int(r[1]), "nodes": int(r[2])}
    return {}


def machine():
    def ctl(name):
        return sh(["sysctl", "-n", name]).stdout.strip()
    return {
        "model": ctl("hw.model"), "chip": ctl("machdep.cpu.brand_string"),
        "cores": f"{ctl('hw.perflevel0.physicalcpu')}P+{ctl('hw.perflevel1.physicalcpu')}E",
        "memory_gb": round(int(ctl("hw.memsize") or 0) / 2**30), "macos": sh(["sw_vers", "-productVersion"]).stdout.strip(),
    }


def load():
    numbers = re.findall(r"[\d.]+", sh(["sysctl", "-n", "vm.loadavg"]).stdout)
    return [float(x) for x in numbers[:3]]


def others():
    """What else is using the Mac: every process at 10% of a core or more, by its program's name only (never a path),
    leaving out Headroom's own copies."""
    found = {}
    for line in sh(["ps", "-Ao", "pcpu=,comm="]).stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        cpu, name = float(parts[0]), os.path.basename(parts[1].strip())
        if cpu >= 10 and name != "Headroom":
            found[name] = found.get(name, 0) + cpu
    return found


def setting(args, pattern, default=""):
    m = re.search(pattern, sh(args).stdout)
    return m.group(1) if m else default


def screen():
    """Whether the Mac is drawing: "locked" when the screen is locked, "asleep" when the display sleeps, else "on". With
    nothing on screen nothing is drawn: memory reads about 190 MB lower and short work slower."""
    if re.search(r"<key>CGSSessionScreenIsLocked</key>\s*<true/>", sh(["ioreg", "-n", "Root", "-d1", "-a"]).stdout):
        return "locked"
    try:
        cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        cg.CGMainDisplayID.restype = ctypes.c_uint32
        cg.CGDisplayIsAsleep.restype, cg.CGDisplayIsAsleep.argtypes = ctypes.c_bool, [ctypes.c_uint32]
        if cg.CGDisplayIsAsleep(cg.CGMainDisplayID()):
            return "asleep"
    except (OSError, AttributeError):
        pass
    return "on"


def screen_off(record):
    return record.get("environment", {}).get("screen", "on") != "on"


class Watch:
    """What the Mac was doing while a run measured: sampled before each scenario. A run is busy when something else used
    half a core or more on average, or all else together a whole core: its timings can't be compared then. A run made
    with the screen locked or the display asleep is compared only with runs made the same way."""

    def __init__(self):
        self.samples, self.loads, self.screens = [], [], []

    def sample(self):
        self.samples.append(others())
        self.loads.append(load()[0])
        self.screens.append(screen())

    def summary(self):
        names = {n for s in self.samples for n in s}
        mean = {n: sum(s.get(n, 0) for s in self.samples) / max(len(self.samples), 1) for n in names}
        heavy = sorted(((n, round(c)) for n, c in mean.items() if c >= 20), key=lambda x: -x[1])
        power = "battery" if "Battery Power" in sh(["pmset", "-g", "batt"]).stdout else "power adapter"
        therm = sh(["pmset", "-g", "therm"]).stdout
        thermal = "nominal" if "No thermal warning" in therm or not therm.strip() else "warning"
        low = setting(["pmset", "-g"], r"lowpowermode\s+(\d)", "0") == "1"
        busy = any(c >= 50 for _, c in heavy) or sum(mean.values()) >= 100 or thermal != "nominal" or low
        shown = "on" if all(s == "on" for s in self.screens) else "locked" if "locked" in self.screens else "asleep"
        return {
            "busy": busy, "screen": shown, "others": [{"name": n, "cpu": c} for n, c in heavy],
            "load": [round(min(self.loads), 2), round(max(self.loads), 2)] if self.loads else [],
            "power": power, "thermal": thermal, "low_power": low,
        }


def records_fingerprint():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None for p in RECORDS}


def saved_map_mb():
    scans = sorted(CHECK_DATA.glob("last-*.scan"), key=lambda p: p.stat().st_mtime)
    return scans[-1].stat().st_size / 1e6 if scans else None


# MARK: Recording


def summarise(samples):
    out = {}
    for name, values in samples.items():
        values = [v for v in values if v is not None]
        if values:
            out[name] = {"median": round(statistics.median(values), 3), "min": round(min(values), 3), "max": round(max(values), 3),
                         "n": len(values)}
    return out


def unit(name):
    if name in CATALOGUE:
        return CATALOGUE[name][0], CATALOGUE[name][1]
    return ("ms", "lower")


def compare(now, before, label_now, label_before, busy=False):
    """A table of each metric now and before, with what got worse beyond its noise marked. When either run was taken on
    a busy Mac, speed can't be judged: nothing is called worse or better, only listed."""
    worse, better = [], []
    rows = []
    for name in sorted(set(now) | set(before), key=lambda n: (unit(n)[0], n)):
        a, b = before.get(name), now.get(name)
        if not a or not b:
            continue
        u, way = unit(name)
        change = (b["median"] - a["median"]) / a["median"] * 100 if a["median"] else 0.0
        # Beyond noise: more than 10% apart and the two runs' ranges don't overlap.
        apart = abs(change) > 10 and (b["min"] > a["max"] or b["max"] < a["min"])
        got_worse = apart and not busy and ((way == "lower" and change > 0) or (way == "higher" and change < 0))
        got_better = apart and not busy and not got_worse
        mark = "  WORSE" if got_worse else ("  better" if got_better else "")
        (worse if got_worse else better if got_better else []).append(name)
        rows.append(f"  {name:44} {a['median']:>10.2f} → {b['median']:>10.2f} {u:6} {change:+7.1f}%{mark}")
    print(f"\n{label_before} → {label_now}:")
    print("\n".join(rows))
    if busy:
        print("\nThe Mac was busy during one of these runs: nothing is judged. Run again with --compare, alternating.")
    print(f"\n{len(worse)} worse beyond noise: {', '.join(worse) or 'none'}")
    print(f"{len(better)} better beyond noise: {', '.join(better) or 'none'}")


def read_log():
    """The findings, oldest first, each checked for what it must have."""
    if not LOG.exists():
        return []
    entries = []
    for n, line in enumerate(LOG.read_text().splitlines(), 1):
        if not line.strip():
            continue
        e = json.loads(line)
        missing = {"date", "metrics", "moved", "why", "verdict"} - set(e)
        if missing or e["verdict"] not in VERDICTS:
            sys.exit(f"log.jsonl line {n}: {'missing ' + ', '.join(sorted(missing)) if missing else 'unknown verdict ' + e['verdict']}")
        entries.append(e)
    return entries


def write_log_doc():
    """BENCHMARKS.md's open items and log, written from log.jsonl between their markers, so there's one record of them."""
    entries = read_log()
    def cell(text):
        return str(text).replace("|", "\\|").replace("\n", " ")
    def row(e):
        metrics = ", ".join(f"`{m}`" for m in e["metrics"])
        where = e.get("commit", "") + (f" on {e['branch']}" if e.get("branch") else "")
        return f"| {e['date']} | {cell(where)} | {metrics} | {cell(e['moved'])} | {cell(e['why'])} | {VERDICT_SHOWN[e['verdict']]} |"
    still = [e for e in entries if e["verdict"] in ("open", "proposal")]
    done = [e for e in entries if e["verdict"] not in ("open", "proposal")]
    head = "| Date | Commit | Metrics | Change | Cause | Verdict |\n|---|---|---|---|---|---|\n"
    # Open items in the order they were written, which is how much they're felt; what's done, newest first.
    open_part = (head + "\n".join(row(e) for e in still)) if still else "No open items."
    log_part = (head + "\n".join(row(e) for e in reversed(done))) if done else "No entries."
    text = DOC.read_text()
    for marker, body in (("open", open_part), ("log", log_part)):
        start, end = f"<!-- {marker}:start -->", f"<!-- {marker}:end -->"
        if start in text and end in text:
            text = text[: text.index(start) + len(start)] + "\n" + body + "\n" + text[text.index(end) :]
    DOC.write_text(text)


def write_view():
    """data.js for index.html: the catalogue and every record, so the page opens straight from the disk."""
    records = [json.loads(line) for line in RESULTS.read_text().splitlines() if line.strip()] if RESULTS.exists() else []
    catalogue = {name: {"unit": c[0], "better": c[1], "group": c[2], "what": c[3], "noted": c[4]} for name, c in CATALOGUE.items()}
    for label, noted in BENCH_NOTED.items():
        name = bench_metric(label)
        catalogue.setdefault(name, {"unit": "ms", "better": "lower", "group": "Microbenchmarks", "what": label, "noted": None})["noted"] = noted
    for record in records:
        # Numbers noted in the past, from DESIGN.md, commits and logs, bring their own definitions where they're new.
        for name, d in record.get("defs", {}).items():
            catalogue.setdefault(name, {"unit": d[0], "better": d[1], "group": d[2], "what": d[3], "noted": None})
        for name in record["metrics"]:
            if name.startswith("bench.") and name not in catalogue:
                what = record.get("labels", {}).get(name, name[6:].replace("_", " "))
                catalogue[name] = {"unit": "ms", "better": "lower", "group": "Microbenchmarks", "what": what, "noted": None}
            elif name.startswith("bench.") and name in record.get("labels", {}):
                catalogue[name]["what"] = record["labels"][name]
    for name, entry in catalogue.items():
        entry["what"] = SHOWN.get(name, entry["what"])
        entry["group"] = GROUPS.get(entry["group"], entry["group"])
    (HERE / "data.js").write_text(
        "window.BENCHMARKS = " + json.dumps({"catalogue": catalogue, "records": records, "log": read_log(), "verdicts": VERDICT_SHOWN}) + ";\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--commit", help="benchmark this commit instead of the working tree")
    ap.add_argument("--compare", help="also benchmark this commit, alternating with the working tree")
    ap.add_argument("--only", help="scenarios, comma-separated: " + ",".join(ORDER))
    ap.add_argument("--label", default="", help="a note kept with the record: what changed")
    ap.add_argument("--compare-label", default="", help="a note kept with the compared commit's record")
    ap.add_argument("--record", action="store_true", help="record even with --only")
    ap.add_argument("--no-record", action="store_true")
    ap.add_argument("--float", action="store_true", help="put the ring's window in front of yours even while you use the Mac")
    ap.add_argument("--view", action="store_true", help="write the page's data and open it")
    ap.add_argument("--log", action="store_true", help="write BENCHMARKS.md's log and open items from log.jsonl")
    a = ap.parse_args()
    if a.log:
        write_log_doc()
        write_view()
        print(f"{len(read_log())} findings written to {DOC.name} and the page")
        return
    if a.view:
        write_view()
        subprocess.run(["open", str(HERE / "index.html")])
        return
    scenarios = a.only.split(",") if a.only else ORDER
    record = (not a.no_record) and (a.record or not a.only)
    OUT.mkdir(exist_ok=True)

    builds = [build(a.commit)]
    if a.compare:
        builds.append(build(a.compare))
    earlier = [json.loads(line) for line in RESULTS.read_text().splitlines() if line.strip()] if RESULTS.exists() else []
    fingerprint = records_fingerprint()
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    samples = {b["name"]: {} for b in builds}
    texts = {b["name"]: [] for b in builds}
    loads = [load()]
    watch = Watch()
    for r in range(a.rounds):
        # Alternating which goes first, so whatever the Mac is doing meanwhile falls on both alike.
        for b in (builds if r % 2 == 0 else list(reversed(builds))):
            run_dir = OUT / "runs" / stamp / b["name"] / f"round{r + 1}"
            run_dir.mkdir(parents=True, exist_ok=True)
            for scenario in scenarios:
                watch.sample()
                print(f"round {r + 1}/{a.rounds} · {b['name']} · {scenario}", flush=True)
                text = run_scenario(b["app"], scenario, run_dir, float_anyway=a.float)
                texts[b["name"]].append(text)
                for name, value in parse(scenario, text).items():
                    samples[b["name"]].setdefault(name, []).append(value)
                if scenario == "first-launch":
                    size = saved_map_mb()
                    if size is not None: samples[b["name"]].setdefault("saved.map_mb", []).append(size)
        loads.append(load())
    if records_fingerprint() != fingerprint:
        print("\nWARNING: your Headroom records changed during the run. Look at backup.json and agents.json.")

    environment = watch.summary()
    results = {}
    for b in builds:
        samples[b["name"]]["app.size_mb"] = [b["size_mb"]]
        commit = git("rev-parse", "--short=10", b["commit"] or "HEAD")
        dirty = b["commit"] is None and bool(git("status", "--porcelain", "--untracked-files=no"))
        results[b["name"]] = {
            # A run of this suite. Numbers found from before it were measured other ways: "noted" (DESIGN.md, the README,
            # commit messages) or "logged" (session transcripts, scratch logs). Only runs are compared with runs.
            "source": "run",
            "when": datetime.datetime.now().isoformat(timespec="seconds"),
            "commit": commit, "subject": git("log", "-1", "--format=%s", commit), "committed": git("log", "-1", "--format=%cI", commit),
            "dirty": dirty, "label": a.compare_label if a.compare and b is builds[1] else a.label, "rounds": a.rounds,
            "scenarios": scenarios, "machine": machine(), "disk": disk_facts(texts[b["name"]]),
            "load": [round(sum(x[i] for x in loads) / len(loads), 2) for i in range(3)],
            "environment": environment,
            "metrics": summarise(samples[b["name"]]),
            "labels": {k: v for k, v in BENCH_LABELS.items() if k in samples[b["name"]]},
        }
    if record:
        with open(RESULTS, "a") as f:
            for b in builds:
                f.write(json.dumps(results[b["name"]]) + "\n")
        write_view()
        print("\nIf a number moved, say why in log.jsonl, then run.py --log.")
        print(f"\nrecorded in {RESULTS.relative_to(REPO)}")

    now = results[builds[0]["name"]]
    if a.compare:
        before = results[builds[1]["name"]]
        # Alternating, both ran under the same conditions: judged even when the Mac was busy, since it was busy for both.
        compare(now["metrics"], before["metrics"], f"{builds[0]['name']}", f"{builds[1]['name']} ({before['commit']})")
    else:
        same = [e for e in earlier if e.get("source", "run") == "run" and e.get("machine", {}).get("model") == now["machine"]["model"]]
        previous = same[-1] if same else None
        if previous:
            busy = environment["busy"] or previous.get("environment", {}).get("busy", False) or bool(previous.get("busy"))
            unlike = screen_off(now) != screen_off(previous)
            compare(now["metrics"], previous["metrics"], "now", f"previous run ({previous['commit']}, {previous['when'][:10]})",
                    busy or unlike)
            if unlike:
                print("\nOne of these runs was made with nothing on screen: memory and short work can't be compared either.")
    if environment["busy"]:
        print("\nnote: the Mac was busy: " + ", ".join(f"{o['name']} {o['cpu']}%" for o in environment["others"]))
    if environment["screen"] != "on":
        print(f"\nnote: the screen was {'locked' if environment['screen'] == 'locked' else 'asleep'}: nothing was drawn, so"
              " memory reads about 190 MB lower and short work slower. It's compared only with runs made the same way.")


if __name__ == "__main__":
    main()
