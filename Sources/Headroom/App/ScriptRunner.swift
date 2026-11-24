import AppKit
import Foundation
@_spi(Diagnostics) import SunburstKit
import SwiftUI

/// Runs the real app through a written list of steps and photographs its window, so the whole interface can be
/// checked by eye without anyone at the mouse. Started with `--script steps.txt`, and it keeps its data apart from yours.
/// It can look and click, but it can't move your files: the app may hold Full Disk Access, and that shouldn't be
/// something another program can script. Its clean, empty and undo steps are stopped by `Cleaner.onlyInside` anywhere but
/// a throwaway test disk. `--no-cache` starts without the saved scan, and `--locked` acts as if Full Disk Access were off,
/// so nothing is read, as on a first launch without it. `--reduce-motion` acts as if Reduce Motion were on. Its window
/// opens at the default size and saves neither its size nor its place, so a check can't move or resize yours.
/// `--remember-window` keeps the window, the inspector and the view between runs as your copy does, in your settings, so a
/// check that uses it puts them back afterwards. Pictures need a permission to record the screen that's already there; a
/// check never asks for it, so a copy without it, such as one started with `open`, goes on without pictures. A step given
/// something it can't use (a number that isn't one, a wait of more than a day, more than 10 clicks, a window smaller than
/// it can be, a row that isn't there) says so and the run goes on.
///
///     wait 1.5                 pause, in seconds
///     scanned                  wait until the running scan has finished
///     lens map|changes|freeUp|copies
///     copies                   wait until Copies has looked for duplicates, then say what it found and how long it took
///     copyrow 2, copytick 0    point at a row in Copies, or tick a row of duplicates
///     copyopen links|symlinks  open or close one of Copies' folded lists
///     copyopenrow 0, copykeep 0  open a row of duplicates, or keep its first extra copy instead
///     copylink 0               link a row of duplicates' extra copies to the one that stays: only on the throwaway test disk
///     focus ~/some/folder      zoom straight to a folder
///     up
///     bench                    what everything costs on this disk, in milliseconds
///     meter start, meter name  how busy the main thread was between the two, and its longest stall
///     pacing start, pacing name  whether every frame of the ring reached the screen on time between the two, what each
///                              cost, and how busy the main thread was
///     sweep ring 5             the pointer travelling over the ring or the inspector, without your real one moving
///     back, forward            the arrows in the toolbar
///     select ~/some/file       as if it had been clicked: the inspector shows it
///     hover ~/some/folder
///     links ~/some/folder      what the middle of the ring says about its hard links or clones, and how long that takes
///     lastuse ~/some/folder    what the middle of the ring says about when it was last used, and how long that takes
///     pointname ~/some/folder  as if the pointer were on a row with this name. Nothing after it: the pointer leaves
///     moveto x y               tell the window the pointer is here, without moving your real one
///     axlist, axpress Text     what can be pressed in the window, and pressing the first whose name has that text: the
///                              control's own action, run from inside the app, with no pointer and no permission. The ring
///                              and the toolbar only: the inspector's rows aren't described to anything inside the app
///     pointerpost x y          the same through the system's own path, which SwiftUI's hover follows too. Only when this
///                              app may already post events (Accessibility): it never asks, and says so when it may not
///     rightclick x y           right-click here, say what the menu offers, and close it
///     target                   what an action would apply to now, what the pointer is on, and how many pieces are lit
///     where                    which folder it's in, and what's selected
///     sizes name               what the map says the disk, free space, the Trash and each thing in the folder in view hold
///     agents                   the socket agents come in by, and who is connected, asking and allowed, with what they did
///     agentanswer allow|look|deny  your answer to the next agent that asks, given as soon as it does
///     agentremove              takes back every agent that was allowed
///     agentswindow             opens Agents from the app menu, and says each window's number, for a photograph of it
///     menu ~/some/folder       what a right-click offers for it, or for what an action would apply to now
///     action Copy Path         do this from that list, to what an action would apply to now
///     clipboard                what's been copied, on a clipboard of its own, and what the pill says
///     menubar                  what's in every menu, with ✓ by what's ticked
///     key c cmd opt            give the menu bar this shortcut
///     menuitem Edit Copy List  choose this from the menu bar. `menuitem View Rings > 8` goes into a submenu
///     rings                    how many rings were asked for, can be filled and are drawn, the pieces in each, and the time
///     ringbench name           each way of sizing the rings, laid out 20 times for the folder in view: the time, the pieces
///     changeinfo ~/some/folder over the last day, how it changed and what grew and shrank inside it, and in each thing in it
///     copyroute                what ⌘C would copy now
///     tick 0                 tick the nth row in Free Up, or the row with this title
///     plan ~/some/folder       add it to the planned actions, or take it out
///     box quick                tick a box in the inspector, by id or title
///     point models             point at a box in the inspector. Nothing after it: the pointer leaves
///     pointat Caches           point at one thing in the inspector
///     press x y clicks dx dy   a click, double-click or drag on the window, given to the app alone. `press piece 1` hits the ring
///     frame                    where the window is, and whether it fills the screen
///     memory, footprint        how much memory it uses, and what that's made of
///     open models              open a box
///     review                   check what's selected
///     labelpoint 2             the pointer on a name around the ring, and what's lit while it moves there
///     labelleave 2, ringpoint  the pointer leaves that name, or moves onto the ring itself, and what's lit then
///     panelhover 2             the pointer on that thing's row in the inspector, moving a little, and what's lit
///     labelclick 2             what a click on that name does. `labelclick 2 2` is the second click of a double-click
///     ringclick 2              a click on this piece of the ring. `ringclick 2 2` is a double-click
///     button                   how much of what's selected is ready, and why the rest isn't
///     busy anyway              what Send to Trash asks when something is using the folder, and the answer: anyway or cancel
///     cleananyway /some/path   the Clean anyway button, for something selected that's in use
///     leaks                    with --hide-names, look for real names in everything the app has ready to show
///     about picture.png        open About Headroom from the app menu, and take its picture
///     clean, empty, undo       only ever act inside the throwaway test disk. `clean nowait`, `empty nowait` and
///                              `undo nowait` go on to the next step at once, while things are still going or coming back
///     keep Title               keep a suggestion
///     after on|off             show the disk as it will be after the clean
///     expand Title             open a suggestion
///     window 7                 pick a Changes window, in days, or 0 for the last scan
///     search text
///     found                    what the search found on the map and among the small files, once that's done, and how long
///                              the small files took
///     smallfiles on|off        Edit › Search Small Files. Nothing after it: whether the map has its catalogue, and how big
///                              that is
///     panel on|off             show or hide the inspector, as its button does
///     scrolls                  where each list starts and is scrolled to, beside the room kept for the toolbar
///     voiceover [press]        what VoiceOver hears for the ring, and with press, what pressing its first piece does
///     size 1440 900            the window's size. size 1440 900 0 40 also puts its top left corner there on the screen,
///                              away from wherever your real pointer is resting
///     jiggle 6                 for this many seconds, the window's right edge moves 3 points out and back every 8 ms, as
///                              in a live resize, a zoom or a window manager, while the steps after it go on
///     collide 860 620          switch the view as the switcher does, and give the window this size in the same instant
///     timescale 0.1            slow every animation down
///     mouse x y                move the real pointer path, in window points
///     click x y
///     activate                 bring the app to the front
///     look ~/some/file         open the card Shift-Space opens, for this or for what an action would apply to now
///     card                     what the card is showing, where its window is, and what it has worked out
///     cardpress x y [clicks]   a click on the card's window, at points from its top left
///     carddrag x y dx dy       a press on the card's window that drags the pointer this far
///     cardframe x y w h        as if the card's window had been dragged and sized there
///     keydown 49 [cmd opt ...] a key as the app gets it, by key code. 49 is space, and keydown 123 cmd is ⌘←
///     volume /Volumes/Name     switch to another disk
///     shot file.png
///     clock, at 3.25           start a director's clock; wait until 3.25 s after it (late steps run at once, so nothing drifts)
///     titlemenu Travel SSD     the window title's menu, opened as a click opens it, and that item chosen from it
///     piece ~/some/folder      where its piece is on the ring now, in points from the window's top left
///     pointer x y              the pointer is here now, quietly, for one moved sixty times a second
///     mark name                print the moment, on the clock every process shares, for something outside to line up with
///     windowid                 the window's number and frame, for a recorder outside the app
///     film 3 0.1 name          keep photographing in the background without holding anything up: 3 s, every 0.1 s
///     memory label             say how much memory is in use, and the most so far
///     checkupdates             Check for Updates, as from the menu. `--update-feed releases.json` reads GitHub's list of
///                              releases from that file, and a release's files can be file URLs
///     updatestate              what the updater found, and what its window says about it
///     installupdate            put in place what it found
///     quit
@MainActor
enum ScriptRunner {
    private static var meter: MainThreadMeter?
    private static var pacingStarted: CFTimeInterval = 0

    /// The file of steps the app was started with, if it was. Asked all over the app, so it's worked out once.
    nonisolated static let path = CommandLine.arguments.value(after: "--script")

    static func startIfAsked() {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // Each line as it's written, so a run that gets stuck still says how far it got.
        setvbuf(stdout, nil, _IOLBF, 0)
        let model = AppModel.shared
        Task {
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                print("step \(line)")
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                await run(parts[0], argument, model)
            }
        }
    }

    /// How evenly the ring's frames reached the screen. A frame that came a refresh or more late is one you'd see as a hitch.
    private static func pacing(_ notes: [RingDrawer.FrameNote], interval: Double, since start: CFTimeInterval, label: String) -> String {
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * p)]
        }
        var hitches = 0, missed = 0, longest = 0.0, uneven = 0
        var when: [String] = []
        for i in notes.indices.dropFirst() where !notes[i].restarted && notes[i].presented > 0 && notes[i - 1].presented > 0 {
            let gap = notes[i].presented - notes[i - 1].presented
            longest = max(longest, gap)
            let refreshes = Int((gap / interval).rounded())
            if refreshes > 1 {
                hitches += 1
                missed += refreshes - 1
                when.append(
                    String(
                        format: "%.0f ms (frame %d of its run)", (notes[i].target - start) * 1000,
                        i - (notes[...i].lastIndex(where: \.restarted) ?? 0)))
            }
            // The picture moved on by a different time than passed on screen: it would look uneven even with no frame missed.
            if abs(notes[i].dt - gap) > interval * 0.5 { uneven += 1 }
        }
        let runs = notes.filter(\.restarted).count
        let unseen = notes.filter { $0.presented == 0 }.count
        let cpu = notes.map(\.cpu), gpu = notes.map(\.gpu).filter { $0 > 0 }
        return String(
            format:
                "pacing %@: %d frames in %d runs, %d hitches (%d refreshes missed), longest gap %.1f ms, %d never shown, %d uneven; each frame cpu %.2f/%.2f/%.2f ms, gpu %.2f/%.2f/%.2f ms (median/95%%/most)",
            label as NSString, notes.count, runs, hitches, missed, longest * 1000, unseen, uneven,
            percentile(cpu, 0.5), percentile(cpu, 0.95), cpu.max() ?? 0, percentile(gpu, 0.5), percentile(gpu, 0.95), gpu.max() ?? 0)
            + (when.isEmpty ? "" : "\n  hitches at " + when.joined(separator: ", "))
            + "\n  runs start at "
            + notes.indices.filter { notes[$0].restarted }.map { String(format: "%.0f ms", (notes[$0].target - start) * 1000) }.joined(
                separator: ", ")
    }

    private static func resolve(_ path: String, _ model: AppModel) -> UInt32? {
        guard let tree = model.tree else { return nil }
        var p = path
        if p.hasPrefix("~") { p = NSHomeDirectory() + p.dropFirst() }
        return tree.find(path: p) ?? tree.find(visible: p)
    }

    /// Whether the app has been told something is reading its views, for `axlist` and `axpress`.
    private static var axAnnounced = false

    /// When the director's clock started, for `at`.
    private static var clockStart = 0.0

    /// The parts of the harness. Every step belongs to one, and is carried out by that part's function below.
    private enum StepGroup { case timing, copies, map, menus, plan, measuring, window, card, updates, agents, backup }

    /// Every step there is, and the part that does it.
    private static let groupOfStep: [String: StepGroup] = [
        "wait": .timing, "clock": .timing, "at": .timing, "mark": .timing, "scanned": .timing, "quit": .timing,
        "report": .timing,
        "copies": .copies, "copyset": .copies, "copyrow": .copies, "copyopen": .copies, "copyopenrow": .copies, "copyline": .copies,
        "copykeep": .copies, "copylink": .copies, "copyact": .copies, "filekind": .copies, "copyhelp": .copies,
        "copytick": .copies, "benchcopy": .copies,
        "lens": .map, "focus": .map, "up": .map, "hover": .map, "links": .map, "lastuse": .map, "pointname": .map,
        "moveto": .map, "pointerpost": .map, "axlist": .map, "axpress": .map, "rightclick": .map, "target": .map, "where": .map, "select": .map,
        "back": .map, "forward": .map,
        "rings": .map, "changeinfo": .map, "ringbench": .map, "piece": .map, "pointer": .map, "labelpoint": .map,
        "labelleave": .map, "panelhover": .map, "ringpoint": .map, "ringat": .map, "ringclick": .map, "labelclick": .map, "window": .map,
        "search": .map, "found": .map, "smallfiles": .map, "volume": .map, "sizes": .map,
        "titlemenu": .menus, "menu": .menus, "action": .menus, "clipboard": .menus, "menubar": .menus, "key": .menus,
        "menuitem": .menus, "copyroute": .menus, "keydown": .menus, "keys": .menus,
        "tick": .plan, "plan": .plan, "recommended": .plan, "boxes": .plan, "box": .plan, "point": .plan, "pointat": .plan,
        "open": .plan, "review": .plan, "checked": .plan, "clean": .plan, "empty": .plan, "undo": .plan,
        "othercopies": .plan, "refreshcheck": .plan, "othercopy": .plan, "moveplan": .plan, "tryagain": .plan,
        "uninstallplan": .plan, "keep": .plan, "after": .plan, "expand": .plan, "busy": .plan, "cleananyway": .plan,
        "button": .plan,
        "speed": .measuring, "meter": .measuring, "pacing": .measuring, "touch": .measuring, "sweep": .measuring,
        "bench": .measuring, "memory": .measuring, "footprint": .measuring, "gpu": .measuring, "headroom": .measuring,
        "frames": .measuring, "layers": .measuring, "names": .measuring, "labels": .measuring, "memoryshort": .measuring, "palette": .measuring,
        "glow": .measuring, "exporttree": .measuring, "middle": .measuring, "stretches": .measuring, "state": .measuring, "pointon": .measuring,
        "clickon": .measuring, "clickplace": .measuring, "mapkey": .measuring, "menufor": .measuring, "leaks": .measuring, "format": .measuring,
        "panel": .window, "scrolls": .window, "voiceover": .window, "size": .window, "jiggle": .window, "collide": .window,
        "timescale": .window, "shotwindow": .window, "shot": .window, "drawn": .window, "film": .window, "mouse": .window, "click": .window,
        "activate": .window, "float": .window, "hide": .window, "unhide": .window, "minimize": .window, "restore": .window,
        "lose": .window, "redraw": .window, "stopwhenhidden": .window, "windowid": .window, "frame": .window,
        "press": .window, "about": .window,
        "look": .card, "cardpress": .card, "carddrag": .card, "cardframe": .card, "card": .card,
        "checkupdates": .updates, "installupdate": .updates, "signedlikethis": .updates, "updatestate": .updates,
        "agents": .agents, "agentanswer": .agents, "agentremove": .agents, "agentswindow": .agents,
        "drives": .backup, "litdump": .backup, "locations": .backup, "backupfolder": .backup, "backupdrive": .backup, "backupselect": .backup,
        "backupdeselect": .backup, "backupmove": .backup, "backupcopy": .backup,
        "backupwait": .backup, "backupstate": .backup, "ghosts": .backup, "bringback": .backup, "verifymoved": .backup, "deletelast": .backup,
        "backupcandidates": .backup, "undomove": .backup, "driveside": .backup, "drivepick": .backup, "drivecopy": .backup,
        "drivecheck": .backup, "drivedelete": .backup, "selectonlymac": .backup, "backupactions": .backup, "hoverpiece": .backup,
        "openpiece": .backup, "labelsdump": .backup,
    ]

    private static func run(_ command: String, _ argument: String, _ model: AppModel) async {
        switch groupOfStep[command] {
        case .timing: await runTimingStep(command, argument, model)
        case .copies: await runCopiesStep(command, argument, model)
        case .map: await runMapStep(command, argument, model)
        case .menus: await runMenusStep(command, argument, model)
        case .plan: await runPlanStep(command, argument, model)
        case .measuring: await runMeasuringStep(command, argument, model)
        case .window: await runWindowStep(command, argument, model)
        case .card: await runCardStep(command, argument, model)
        case .updates: await runUpdatesStep(command, argument, model)
        case .agents: await runAgentsStep(command, argument)
        case .backup: await runBackupStep(command, argument, model)
        case nil:
            print("unknown step: \(command)")
        }
    }

    /// Backup: the drives, its list, a move or copy and what it did, ghosts, and the moved files. Moves only ever happen
    /// between the two test disks: see `Cleaner.mayAct`.
    private static func runBackupStep(_ command: String, _ argument: String, _ model: AppModel) async {
        func notes(_ which: String) -> [MovedNote] {
            which.isEmpty || which == "all" ? model.movedNotes : model.movedNotes.filter { $0.originalPath == which || $0.name == which }
        }
        switch command {
        case "drives":
            model.refreshDrives()
            for drive in model.drives {
                print(
                    "drive \(drive.name) at \(drive.mountPath): \(drive.fileSystemTitle), \(formatBytes(drive.free)) free\(drive.isReadOnly ? ", read-only" : "")\(model.whyNotDestination(drive).map { ", not for Backup: \($0)" } ?? "")"
                )
            }
        case "litdump":
            // litdump: every piece lit now, and how: pointed at, lit whole, or on the way out.
            guard let tree = model.tree else { return }
            let pieces = model.engine.layout.pieces, emphasis = model.engine.emphasis, shares = model.engine.tintShares
            // When only some of what's lit takes the tint, those are marked.
            let some = shares.contains { $0 < 0.5 }
            for (i, e) in emphasis.enumerated() where e > 0.5 && i < pieces.count {
                let p = pieces[i]
                let how = e > 1.5 ? "pointed" : e > 0.9 ? "whole" : "way out"
                print(
                    "  lit \(how) \(p.isSmaller ? "smaller items in " : "")\(tree.friendlyPath(p.node))\(some && shares[i] > 0.5 ? " (coloured)" : "")"
                )
            }
        case "locations":
            // The right capsule's list as it shows it: the locations used, a divider, the other drives.
            model.refreshDrives()
            for place in model.usedLocations {
                let current = model.backup.destination?.isSame(as: place) == true ? " (current)" : ""
                print(
                    "used \(place.title) at \(place.root)\(place.drive.isConnected ? "" : ", not connected")\(current)\(place.drive.isNetwork ? ", network" : "")"
                )
            }
            print("---")
            for drive in model.otherDrives {
                print("other \(drive.name)\(model.whyNotDestination(drive).map { ", \($0)" } ?? "")")
            }
        case "backupfolder":
            // backupfolder path: a folder chosen in Choose Folder….
            print(
                "backupfolder \(argument): \(model.chooseDestination(folder: argument) ?? "now \(model.backup.destination?.title ?? "nothing") at \(model.backup.destination?.root ?? "")")"
            )
        case "backupdrive":
            model.refreshDrives()
            guard let drive = model.drives.first(where: { $0.name == argument || $0.mountPath == argument }) else {
                print("backupdrive: no drive \(argument)"); return
            }
            model.chooseDestination(drive)
            print("backupdrive: \(model.backup.destination?.title ?? "not chosen")")
        case "backupselect":
            // backupselect path, or backupselect path by Agent Name: as that agent selecting it.
            let parts = argument.components(separatedBy: " by ")
            let agent = parts.count > 1 ? parts.dropFirst().joined(separator: " by ") : nil
            for pick in model.selectForBackup([parts[0]], agent: agent, reason: agent.map { _ in "Finished render, a copy is in Films" }) {
                print("backupselect \(pick.path): \(pick.outcome.text)")
            }
        case "backupdeselect":
            for pick in model.deselectForBackup([argument]) { print("backupdeselect \(pick.path): \(pick.outcome.text)") }
        case "backupcandidates":
            let tree = model.workTree
            for node in model.backupCandidates().prefix(20) {
                print("candidate \(tree?.friendlyPath(node) ?? "") \(formatBytes(tree?.totals[Int(node)] ?? 0))")
            }
        case "backupmove", "backupcopy":
            let ready = model.backupReady()
            print("\(command): \(ready.problem ?? "\(ready.items.count) files, \(formatBytes(ready.items.reduce(0) { $0 &+ $1.bytes }))")")
            model.runBackup(copyOnly: command == "backupcopy")
        case "backupwait":
            let started = Date()
            while model.driveJob?.isRunning == true, Date().timeIntervalSince(started) < 120 { try? await Task.sleep(for: .milliseconds(100)) }
            guard let job = model.driveJob else { print("backupwait: no run"); return }
            print("backupwait: \(job.summary)")
            for entry in job.entries { print("  \(entry.title): \(entry.step)") }
        case "backupstate":
            print(
                "backup: to \(model.backup.destination?.title ?? "nothing") (\(model.destinationDrive == nil ? "not connected" : "connected")), \(model.backup.items.count) selected, \(formatBytes(model.backupBytes)); Free Up has \(model.plan.count)"
            )
            for item in model.backup.items { print("  selected \(item.path) \(formatBytes(item.bytes))\(item.agent.map { " by \($0)" } ?? "")") }
            let summary = model.backupSummary()
            print(
                "  summary: \(summary.files) files, \(formatBytes(summary.bytes)), frees \(formatBytes(summary.frees)), \(summary.freesNothing.count) free nothing"
            )
            for note in model.movedNotes {
                print(
                    "  moved \(note.originalPath) → \(note.driveName):\(note.drivePath) \(formatBytes(note.size)) \(model.drive(of: note) == nil ? "(not connected)" : "")"
                )
            }
            print(
                "  ghosts \(model.showGhosts ? "on" : "off"), on screen: \(model.tree?.ghosts.count ?? 0); ready: \(model.backupReady().problem ?? "yes")"
            )
        case "driveside":
            model.setShowDriveSide(argument != "off")
            let started = Date()
            // The two disks as they are now: a picture of where files went before doesn't count.
            let root = model.backup.destination?.root ?? ""
            while argument != "off", model.pair.map({ !$0.drivePath.hasPrefix(root) }) ?? true, Date().timeIntervalSince(started) < 20 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let pair = model.pair else { print("driveside \(argument): not shown, focus \(model.focus)"); return }
            print("driveside: \(pair.macPath) beside \(pair.drivePath), \(pair.tree.count) nodes, on screen \(model.tree === pair.tree)")
            for place in PairPlace.allCases {
                if let c = pair.counts[place] { print("  \(place.title(drive: pair.driveName)): \(c.files) files, \(formatBytes(c.bytes))") }
            }
            let pieces = model.engine.layout.pieces
            for p in pieces where p.ring == 0 {
                print(
                    "  half \(pair.tree.name(p.node)) from \(String(format: "%.0f", p.a0 * 180 / .pi))° to \(String(format: "%.0f", p.a1 * 180 / .pi))°"
                )
            }
        case "drivepick":
            // drivepick name: picks a file on the drive's half, as a click on it does.
            guard let pair = model.pair, let node = pair.driveRel.first(where: { $0.value == argument || $0.value.hasSuffix("/" + argument) })?.key
            else {
                print("drivepick \(argument): not on the drive's half"); return
            }
            model.toggleDriveFile(node, in: pair)
            print("drivepick: \(model.driveSelection.map { "\($0.title) (\($0.place))" }.joined(separator: ", "))")
        case "hoverpiece":
            // hoverpiece path: the pointer on that thing's piece, as moving it there would.
            guard let tree = model.tree, let node = resolve(argument, model), let index = model.engine.layout.piece(of: node) else {
                print("hoverpiece \(argument): no piece"); return
            }
            model.chart.point(at: model.engine.layout.pieces[index].node)
            let other = model.pair.flatMap { $0.tree === tree ? $0.counterpart(node) : nil }
            print("hoverpiece \(tree.name(node)): \(model.hover?.note ?? ""), other half \(other.map { tree.path($0) ?? tree.name($0) } ?? "none")")
        case "labelsdump":
            // labelsdump: the names around and on the ring, and the top ring's pieces.
            for p in model.engine.layout.pieces where p.ring == 0 {
                print(
                    String(
                        format: "  ring 0 %@ %.0f°-%.0f° r %.3f-%.3f", model.tree?.name(p.node) ?? "?", p.a0 * 180 / .pi, p.a1 * 180 / .pi, p.r0, p.r1
                    ))
            }
            for label in model.chart.labels { print("  label \(label.title) \(label.value) \(label.place)") }
        case "openpiece":
            // openpiece path: a click on that thing's piece.
            guard let tree = model.tree, let node = resolve(argument, model), let index = model.engine.layout.piece(of: node) else {
                print("openpiece \(argument): no piece"); return
            }
            model.click(piece: index)
            print("openpiece \(tree.name(node))")
        case "selectonlymac":
            model.selectOnlyOnMac()
            print("selectonlymac: \(model.backup.items.count) selected, \(model.tip ?? "")")
        case "backupactions":
            for action in model.backupActions { print("  action \(action.title): \(action.detail)\(action.blocked.map { " (\($0))" } ?? "")") }
            if let pair = model.pair { print("  pair online \(pair.online), read \(pair.readAt.map { "\($0)" } ?? "never")") }
        case "drivecopy":
            model.copyToMac(model.driveSelection)
        case "drivecheck":
            model.checkOnDrive(model.driveSelection)
        case "drivedelete":
            // As the panel's Delete does once it's been confirmed.
            model.deleteFromDrive(model.driveSelection)
        case "ghosts":
            model.setShowGhosts(argument != "off")
            try? await Task.sleep(for: .milliseconds(400))
            print("ghosts \(argument): \(model.tree?.ghosts.count ?? 0) drawn, real map kept: \(model.bareTree != nil)")
        case "bringback":
            model.bringBack(notes(argument))
        case "verifymoved":
            model.verifyMoved(notes(argument))
        case "deletelast":
            // The confirmation is the user's in the app. A scripted check only ever reaches its own test disks.
            model.deleteLastCopy(notes(argument))
        case "undomove":
            // What ⌘Z does after a move.
            model.undoCommand()
        default:
            break
        }
    }

    /// Agents: who is connected, asking and allowed, and your answer to one that asks.
    private static func runAgentsStep(_ command: String, _ argument: String) async {
        let agents = Agents.shared
        func line(_ identities: [AgentIdentity]) -> String {
            identities.isEmpty ? "none" : identities.map { "\($0.name) (\($0.program), \($0.signer ?? "not signed"))" }.joined(separator: "; ")
        }
        switch command {
        case "agents":
            print("agents: socket \(AgentServer.door.host.socketPath)")
            print("  connected: " + line(agents.connected.map(\.identity)))
            print("  asking: " + line(agents.requests.map(\.identity)))
            print("  allowed: " + line(agents.allowed.map(\.identity)))
            for one in agents.activity.suffix(12) { print("  did: \(one.agent): \(one.what)") }
        case "agentanswer":
            // The answer is given the moment an agent asks, so the question isn't left on screen for anyone else to answer.
            let started = Date()
            while agents.requests.isEmpty, Date().timeIntervalSince(started) < 20 { try? await Task.sleep(for: .milliseconds(30)) }
            guard let request = agents.requests.first else { print("agentanswer \(argument): nobody asked"); return }
            agents.answer(request, argument == "allow" ? .allow : (argument == "look" ? .lookOnly : .deny))
            print("agentanswer \(argument): \(request.identity.name)")
        case "agentremove":
            let gone = agents.allowed
            for one in gone { agents.remove(one) }
            print("agentremove: \(gone.count) removed")
        default:
            // The Agents window, as the app menu opens it, and every window there is, by the number a photograph is asked for.
            if !chooseFromAppMenu("Agents…") { print("no Agents item") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                for w in NSApp.windows where w.isVisible {
                    print(
                        "agentswindow: window \(w.windowNumber) \"\(w.title)\" \(Int(w.frame.width))x\(Int(w.frame.height))\(w.isSheet ? " sheet" : "")"
                    )
                }
            }
        }
    }

    /// Waiting, the clock, and the end of a run.
    private static func runTimingStep(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "wait":
            guard let seconds = seconds(argument.isEmpty ? "1" : argument, for: "wait") else { return }
            try? await Task.sleep(for: .seconds(seconds))
        case "clock":
            // A director's clock starts here: `at` counts from this moment, on the clock every process shares.
            clockStart = ProcessInfo.processInfo.systemUptime
            print(String(format: "clock at %.4f", clockStart))
        case "at":
            // at 3.25: wait until 3.25 s after `clock`. A step that's late runs at once, so lateness never adds up.
            guard let at = seconds(argument.isEmpty ? "0" : argument, for: "at") else { return }
            let wait = clockStart + at - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        case "scanned":
            // Nothing reading the disk and nothing on screen after 30 s means the window never opened, and nothing ever will.
            let started = Date()
            while model.isScanning || model.tree == nil || model.mapsOnTheirWay > 0 {
                if model.tree == nil, !model.isScanning, Date().timeIntervalSince(started) > 30 {
                    print("scanned: nothing is reading the disk after 30 s, and \(NSApp.windows.filter(\.isVisible).count) windows are open")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(400))
        case "mark":
            // mark name: a moment another program can wait for and line up with, on the clock every process shares.
            print(String(format: "mark %@ at %.4f", argument, ProcessInfo.processInfo.systemUptime))
        case "report":
            report(model)
        case "quit":
            fflush(stdout)
            // As the Quit menu does it, so a quit that waits for a clean works here too.
            NSApp.terminateSoon()
        default:
            break
        }
    }

    /// The Copies view.
    private static func runCopiesStep(_ command: String, _ argument: String, _ model: AppModel) async {
        /// The nth row of duplicates in Copies.
        func duplicate(_ at: Int?) -> CopyGroup? {
            let dups = model.copyGroupsHere.filter { $0.kind == .duplicate }
            return at.flatMap { dups.indices.contains($0) ? dups[$0] : nil }
        }
        func toggleOpen(_ id: String) {
            if model.copiesOpen.contains(id) { model.copiesOpen.remove(id) } else { model.copiesOpen.insert(id) }
        }
        switch command {
        case "copyset":
            // copyset path: the set that holds this, pointed at in the inspector, as leaving one of its copies' lines does.
            guard let node = resolve(argument, model), let group = model.copyGroupsHere.first(where: { $0.nodes.contains(node) }) else {
                print("copyset \(argument): no set"); return
            }
            model.pointAtCopyGroup(group)
            print("copyset \(argument): \(group.title), \(group.nodes.count) places")
        case "copies":
            // Copies looks only when it's open, so this waits for it to finish, then says what it found and what it cost.
            let started = CFAbsoluteTimeGetCurrent()
            while model.copies == nil || model.copiesReading, CFAbsoluteTimeGetCurrent() - started < 40 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let copies = model.copies, !model.copiesReading else {
                print(
                    "copies: not done after \(Int(CFAbsoluteTimeGetCurrent() - started)) s: map \(model.copies == nil ? "none" : "there"), reading \(model.copiesReading), \(model.copiesGroupsDone) of \(model.copiesGroupsTotal), partial \(model.tree?.isPartial == true)"
                )
                break
            }
            for kind in CopyGroup.Kind.allCases {
                let groups = copies.groups.filter { $0.kind == kind }
                let bytes = groups.reduce(UInt64(0)) { $0 &+ (kind == .duplicate ? $1.back : $1.size) }
                print("copies \(kind.title): \(groups.count), \(formatBytes(bytes))")
            }
            print(
                "copies back \(formatBytes(copies.back)), stored once \(formatBytes(copies.storedOnce)); read \(formatBytes(model.copiesBytesRead)) of \(model.copiesGroupsTotal) same-size sets in \(String(format: "%.2f", model.copiesSeconds ?? 0)) s, \(model.copiesRemembered) remembered"
            )
            for g in copies.groups.prefix(14) {
                print(
                    "  \(g.kind.title): \(g.title) · \(formatBytes(g.kind == .duplicate ? g.back : g.size)) · \(g.others.count + (g.home != 0 ? 1 : 0)) places"
                )
            }
        case "copyrow":
            // copyrow 2: point at the nth row in Copies, as the pointer would. Nothing after it: the pointer leaves.
            if let at = Int(argument), model.copyGroupsHere.indices.contains(at) {
                model.pointAtCopyGroup(model.copyGroupsHere[at])
            } else {
                model.pointAtCopyGroup(nil)
            }
        case "copyopen":
            // copyopen links: open one of Copies' folded lists, or close it if it's open.
            toggleOpen(argument)
        case "copyopenrow":
            // copyopenrow 0: open the nth row of duplicates in Copies, or close it.
            if let group = duplicate(Int(argument)) { toggleOpen(group.id) }
        case "copyline":
            // copyline 0 1: point at the second copy listed in the first row of duplicates, as the pointer would on its line.
            let parts = argument.split(separator: " ").compactMap { Int($0) }
            if parts.count == 2, let g = duplicate(parts[0]) {
                let lines = g.files > 1 ? [g.home] + g.others : g.keepers + g.extras
                if lines.indices.contains(parts[1]) { model.pointAtCopy(lines[parts[1]], of: g) } else { print("copyline \(argument): no such line") }
            }
        case "copykeep":
            // copykeep 0: keep the first extra copy of the nth row of duplicates instead of the one that stays now.
            if let group = duplicate(Int(argument)), let first = group.files > 1 ? group.others.first : group.extras.first {
                model.keepCopy(first, of: group)
            }
        case "copylink", "copyact":
            // copylink 0: hardlink the nth row of duplicates; copyact 0 symlink (or delete, hardlink): what its buttons do. Like
            // clean, only ever inside the throwaway test disk.
            let parts = argument.split(separator: " ")
            let action = command == "copyact" ? parts.dropFirst().first.flatMap { AppModel.CopyAction(rawValue: String($0)) } : .hardlink
            if let group = duplicate(parts.first.flatMap { Int($0) }), let action { model.takeCopies(group, action) }
            while model.cleanProgress != nil { try? await Task.sleep(for: .milliseconds(100)) }
        case "filekind":
            // filekind /a/path: what's there now, a file, a symlink and where it points, or nothing, for checking an action.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: argument) {
                print("filekind symlink -> \(target)")
            } else if FileManager.default.fileExists(atPath: argument) {
                print("filekind file")
            } else {
                print("filekind missing")
            }
        case "copyhelp":
            // copyhelp: open or close the ? at the top of Copies.
            model.copiesHelpShown.toggle()
        case "copytick":
            // copytick 2: tick the nth row of duplicates in Copies, so its extra copies go with the next clean.
            if let group = duplicate(Int(argument)) { model.toggleDuplicate(group) }
        case "benchcopy":
            // benchcopy /from -> /into: the real copy and check, timed. Only ever inside the throwaway test disk.
            let parts = argument.components(separatedBy: " -> ")
            guard parts.count == 2 else { return }
            let started = DispatchTime.now()
            do {
                try Cleaner.copyAndVerify(parts[0], into: parts[1], stop: LockedFlag()) { _ in }
                print(String(format: "benchcopy: %.0f ms", milliseconds(since: started)))
            } catch {
                print("benchcopy failed: \(error)")
            }
        default:
            break
        }
    }

    /// Moving around the map, and pointing at things on it.
    private static func runMapStep(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "piece":
            // piece /some/folder: where its piece is on the ring now, in points from the window's top left.
            guard let node = resolve(argument, model), let i = model.engine.layout.pieces.firstIndex(where: { $0.node == node }) else {
                print("piece \(argument): not on the ring"); return
            }
            let at = middle(of: model.engine.layout.pieces[i], model)
            print(
                String(
                    format: "piece %@ at %.1f %.1f (ring %.1f %.1f radius %.1f)", argument, at.x, at.y, model.ring.center.x,
                    model.ring.center.y, model.ring.radius))
        case "pointer":
            // pointer x y: the pointer is here now, in points from the window's top left. Quiet and quick, for a pointer
            // moved sixty times a second. Your real pointer doesn't move.
            guard let w = mainWindow, let p = point(in: argument) else { return }
            let at = flipped(p.x, p.y, in: w)
            guard let event = mouseEvent(.mouseMoved, at: at, in: w) else { return }
            let view = w.contentView?.superview?.hitTest(at)
            view?.mouseMoved(with: event)
            if view !== w.contentView { w.contentView?.mouseMoved(with: event) }
        case "lens":
            // As a click on the switcher does it.
            let lens: Lens =
                argument == "changes"
                ? .changes : argument == "freeUp" ? .freeUp : argument == "copies" ? .copies : argument == "backup" ? .backup : .map
            Motion.animate(Motion.switching) { model.setLens(lens) }
        case "focus":
            if let node = resolve(argument, model), let tree = model.tree {
                model.zoom(into: RingLayout.chainTail(tree: tree, node))
            } else {
                print("no such folder: \(argument)")
            }
        case "up":
            model.goUp()
        case "hover":
            if argument.isEmpty {
                model.chart.point(at: nil)
            } else if let node = resolve(argument, model) {
                model.highlight(node: node)
            } else {
                print("no such folder: \(argument)")
            }
        case "links":
            if let node = resolve(argument, model), let tree = model.tree {
                let started = DispatchTime.now()
                let line = Accounting.hoverLine(node, bytes: tree.totals[Int(node)], in: tree)
                print(
                    "links \(argument): \(formatBytes(tree.totals[Int(node)])), \(line ?? "says nothing"), \(String(format: "%.1f", milliseconds(since: started))) ms"
                )
            } else {
                print("no such folder: \(argument)")
            }
        case "lastuse":
            if let node = resolve(argument, model), let tree = model.tree {
                let started = DispatchTime.now()
                let line = LastUse.line(node, in: tree)
                print("last use \(argument): \(line ?? "says nothing"), \(String(format: "%.3f", milliseconds(since: started))) ms")
            } else {
                print("no such folder: \(argument)")
            }
        case "pointname":
            model.pointedThing = resolve(argument, model).map { NamedThing($0) }
        case "moveto":
            guard let w = mainWindow, let p = point(in: argument) else { return }
            let at = flipped(p.x, p.y, in: w)
            guard let event = mouseEvent(.mouseMoved, at: at, in: w) else { return }
            let view = w.contentView?.superview?.hitTest(at)
            print("moveto \(argument): lands on \(viewKind(at: at, in: w, longest: 30))")
            view?.mouseMoved(with: event)
            w.contentView?.mouseMoved(with: event)
            // And as the app's own event loop would hand it out.
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(60))
        case "axlist", "axpress":
            // axlist: everything in the window that can be pressed, as an assistive app would find it. axpress Text: press
            // the first of them whose name has that text in it. This runs the control's own action, as a click on it does,
            // from inside the app: no pointer moves and nothing is asked of the system. It reaches the ring's pieces and
            // the toolbar. The inspector's rows don't show up: SwiftUI only describes those to a reader outside the app.
            guard let w = mainWindow, let top = w.contentView?.superview else { return }
            // SwiftUI only describes its views once something that reads them has said it's there, as VoiceOver does.
            if !axAnnounced {
                axAnnounced = true
                for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                    NSApp.accessibilitySetValue(true as NSNumber, forAttribute: NSAccessibility.Attribute(rawValue: name))
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
            var found: [(name: String, element: NSAccessibilityProtocol)] = []
            var seen = 0
            func walk(_ thing: Any, _ depth: Int) {
                guard depth < 40, seen < 6000, let element = thing as? NSAccessibilityProtocol else { return }
                seen += 1
                let role = element.accessibilityRole()?.rawValue ?? ""
                if role == NSAccessibility.Role.button.rawValue || role == NSAccessibility.Role.checkBox.rawValue {
                    let name = [
                        element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String,
                        element.accessibilityHelp(),
                    ]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
                    found.append((name, element))
                }
                for child in element.accessibilityChildren() ?? [] { walk(child, depth + 1) }
            }
            walk(top, 0)
            if command == "axlist" {
                print("axlist: \(found.count) pressable of \(seen) elements")
                for one in found.prefix(80) { print("  " + one.name.prefix(110)) }
            } else if let one = found.first(where: { $0.name.localizedCaseInsensitiveContains(argument) }) {
                let done = one.element.accessibilityPerformPress()
                print("axpress \(argument): pressed \"\(one.name.prefix(80))\" \(done ? "" : "(it said no)")")
                try? await Task.sleep(for: .milliseconds(150))
            } else {
                print("axpress \(argument): nothing with that name among \(found.count)")
            }
        case "pointerpost":
            // pointerpost x y: a pointer move handed to this copy of the app alone, through the system's own path for events,
            // so everything that follows the pointer (SwiftUI's hover included) takes it for a real one. The pointer on
            // screen doesn't move. Only when the system already lets this app post events: it's never asked for.
            guard let w = mainWindow, let screen = NSScreen.screens.first, let p = point(in: argument) else { return }
            guard CGPreflightPostEventAccess() else { print("pointerpost \(argument): not allowed to post events, so nothing was sent"); return }
            let global = CGPoint(x: w.frame.minX + p.x, y: screen.frame.height - w.frame.maxY + p.y)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: global, mouseButton: .left) else { return }
            move.postToPid(getpid())
            try? await Task.sleep(for: .milliseconds(120))
            print("pointerpost \(argument): sent")
        case "rightclick":
            guard let w = mainWindow, let p = point(in: argument) else { return }
            let at = flipped(p.x, p.y, in: w)
            // An event made this way can't say which button it is, and SwiftUI asks. For as long as this takes, it's the right one.
            guard let button = class_getInstanceMethod(NSEvent.self, #selector(getter: NSEvent.buttonNumber)) else {
                print("right-click \(argument): NSEvent has no buttonNumber")
                return
            }
            let usual = method_getImplementation(button)
            let right: @convention(block) (NSEvent) -> Int = { _ in 1 }
            method_setImplementation(button, imp_implementationWithBlock(right))
            defer { method_setImplementation(button, usual) }
            let opened = firstMenu(
                openedBy: {
                    for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                        if let event = mouseEvent(type, at: at, in: w, clicks: 1, pressure: 1) { NSApp.sendEvent(event) }
                    }
                },
                then: { menu in
                    print(
                        "right-click \(argument): "
                            + menu.items.map { item in
                                item.isSeparatorItem ? "|" : item.title + (item.keyEquivalent.isEmpty ? "" : " [key]")
                            }.joined(separator: ", "))
                    menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0.05, inModes: [.eventTracking, .common])
                })
            if !opened { print("right-click \(argument): no menu") }
        case "target":
            let pointed = model.pointedThing.map { $0.title ?? $0.nodes.map { model.realName(of: $0) }.joined(separator: ", ") } ?? "nothing"
            print(
                "target \(argument):\(model.actionTarget.nodes.map { model.realName(of: $0) }); pointed at: \(pointed); lit pieces: \(model.engine.litPieces)"
            )
        case "where":
            print(
                "where \(argument): in \(model.realName(of: model.focus)), selected \(model.selected.map { model.realName(of: $0) } ?? "nothing"), \(model.plan.items.count) planned, back \(model.canGoBack), forward \(model.canGoForward), \(model.afterClean?.things.count ?? 0) in the Trash from here"
            )
        case "select":
            model.selected = resolve(argument, model)
            try? await Task.sleep(for: .milliseconds(100))
        case "back":
            model.goBack()
            try? await Task.sleep(for: .milliseconds(400))
        case "forward":
            model.goForward()
            try? await Task.sleep(for: .milliseconds(400))
        case "rings":
            guard let tree = model.tree else { print("rings: no map"); return }
            let start = DispatchTime.now()
            let layout = RingLayout.build(tree: tree, focus: model.focus, colorer: { _ in .zero }, sizes: model.ringSizes)
            let took = milliseconds(since: start)
            // Around the whole disk, ring 0 is the band, and the rings of folders are 1 to n.
            let first: Int32 = model.focus == 0 ? 1 : 0
            let rings = (0..<Int32(layout.rings)).map { k in layout.pieces.filter { $0.ring == first + k } }
            let widths = rings.map { ring in ring.first.map { String(format: "%.0f", ($0.r1 - $0.r0) * RingLayout.typicalRadius) } ?? "-" }
            let edge = rings.last?.map(\.r1).max() ?? 0
            print(
                String(
                    format:
                        "rings: asked %d %@, drawn %d, could fill %d, menu ticks %d and offers up to %d, pieces per ring %@, widths in points %@, outer edge %.4f, %d lips, %.1f ms",
                    model.ringSizes.depth, model.ringSizes.style.rawValue, layout.rings, layout.reach, model.ringsDrawn, model.ringReach,
                    rings.map { String($0.count) }.joined(separator: " "), widths.joined(separator: " "), edge,
                    layout.pieces.filter { $0.deeper > 0 }.count, took))
            // Where the lips are: the middle of each piece, in degrees clockwise from 12 o'clock, and how strong it is.
            let lipped = layout.pieces.filter { $0.deeper > 0 }.sorted { $0.sweep > $1.sweep }.prefix(12)
            if !lipped.isEmpty {
                print(
                    "rings: lips at "
                        + lipped.map { String(format: "%.0f° %.0f%%", $0.midAngle * 180 / .pi, $0.deeper * 100) }.joined(separator: ", "))
            }
            // How far around each ring goes with the most rings there can be, as a share of the first ring.
            let fill = RingLayout.fill(tree: tree, focus: model.focus, parts: tree.parts(model.ringSizes))
            print("rings: at \(RingSizes.most), how far around each goes: " + fill.map { String(format: "%.1f%%", $0 * 100) }.joined(separator: " "))
        case "changeinfo":
            // changeinfo ~/some/folder: over the last day, how it changed, and what grew and shrank inside it, then the
            // same for each thing in it, with each one's place in the tree.
            guard let tree = model.tree, let node = resolve(argument, model) else { print("no such folder: \(argument)"); return }
            let map = AppModel.changeMap(tree: tree, window: .days(1), rules: model.rules, facts: model.facts)
            func line(_ id: UInt32) -> String {
                String(
                    format: "#%u in #%u %@: %+.2f GB, grew %.2f, shrank %.2f", id, tree.nodes[Int(id)].parent, tree.name(id) as NSString,
                    Double(map.value(of: id)) / 1e9, Double(map.amount(id, shrinking: false)) / 1e9, Double(map.amount(id, shrinking: true)) / 1e9)
            }
            print("changeinfo " + line(node))
            var child = tree.nodes[Int(node)].firstChild
            while child != 0 {
                print("  " + line(child))
                child = tree.nodes[Int(child)].nextSibling
            }
        case "ringbench":
            guard let tree = model.tree else { print("ringbench: no map"); return }
            for style in RingStyle.allCases {
                let sizes = RingSizes(depth: model.ringSizes.depth, style: style)
                var times: [Double] = []
                var layout = RingLayout()
                for _ in 0..<20 {
                    let start = DispatchTime.now()
                    layout = RingLayout.build(tree: tree, focus: model.focus, colorer: { _ in .zero }, sizes: sizes)
                    times.append(milliseconds(since: start))
                }
                times.sort()
                print(
                    String(
                        format: "ringbench %@, %@: %.2f ms median, %.2f slowest, %d pieces in %d rings", argument as NSString,
                        style.rawValue as NSString, times[times.count / 2], times.last ?? 0, layout.pieces.count, layout.rings))
            }
        case "sizes":
            guard let tree = model.tree else { print("sizes: no map"); return }
            let trash = model.trashNode(in: tree).map { formatBytes(tree.totals[Int($0)]) } ?? "none"
            let inside = tree.children(model.focus == 0 ? (tree.anchors.first?.id ?? 0) : model.focus).map {
                "\(tree.rawName($0)) \(formatBytes(tree.totals[Int($0)]))"
            }
            print(
                "sizes \(argument): disk \(formatBytes(tree.totals[0])), free \(formatBytes(tree.totals[Int(tree.free)])), trash \(trash), whole \(tree.isWhole), version \(model.treeVersion), "
                    + "pieces \(model.engine.layout.pieces.count); \(inside.joined(separator: ", "))")
        case "window":
            // window 7 is the last week, 0 the last scan, and -365 what's been untouched for a year.
            guard let d = Int(argument), d != .min else { print("window \(argument): needs a number of days"); return }
            model.setChangeWindow(d == 0 ? .lastScan : d < 0 ? .untouched(-d) : .days(d))
        case "search":
            model.searchActive = true
            model.searchText = argument
            model.runSearch()
        case "found":
            // The small files are searched off the main thread: wait a moment for them.
            let started = CFAbsoluteTimeGetCurrent()
            while model.smallFilesGap == nil, model.smallFound == nil, CFAbsoluteTimeGetCurrent() - started < 5 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard let tree = model.tree else { break }
            print("found on the map: \(model.searchResults.count)" + (model.searchFolderName.map { " in \($0)" } ?? ""))
            for node in model.searchResults.prefix(5) {
                let half = model.pair.map { $0.tree === tree ? ($0.isOnDrive(node) ? " · drive's half" : " · Mac's half") : "" } ?? ""
                print("  \(tree.friendlyPath(node)) · \(formatBytes(tree.totals[Int(node)]))\(half)")
            }
            guard model.searchesSmallFiles else {
                print("small files: not searched")
                break
            }
            guard model.smallFilesGap == nil, let found = model.smallFound else {
                print("small files: \(model.smallFilesGap == .onDrive ? "on the drive's half" : "no catalogue for this map")")
                break
            }
            print("found among small files: \(found.count) in \(String(format: "%.1f", model.smallSearchMilliseconds)) ms")
            for file in found.top.prefix(5) {
                print("  \(file.name) · \(DiskTree.friendly(file.folderPath)) · \(formatBytes(file.bytes))")
            }
        case "smallfiles":
            if argument == "on" || argument == "off" {
                model.setSearchesSmallFiles(argument == "on")
                print("search small files: \(model.searchesSmallFiles ? "on" : "off")")
            } else {
                let catalogue = model.tree.flatMap(model.catalogue(for:))
                let names =
                    (try? FileManager.default.attributesOfItem(atPath: SmallFiles.namesURL(model.tree?.volumeName ?? "").path)[.size] as? Int) ?? 0
                let index =
                    (try? FileManager.default.attributesOfItem(atPath: SmallFiles.indexURL(model.tree?.volumeName ?? "").path)[.size] as? Int) ?? 0
                print(
                    "search small files: \(model.searchesSmallFiles ? "on" : "off"); catalogue for this map: \(catalogue.map { "\($0.files) files" } ?? "none"); names \(formatBytes(UInt64(names))), index \(formatBytes(UInt64(index)))"
                )
            }
        case "labelpoint":
            // labelpoint 2: the pointer arrives on the name around the ring with this number, and moves a little while it's there.
            guard let w = mainWindow, let at = labelPoint(argument, model) else { print("no such name: \(argument)"); return }
            func move(_ x: Double, _ y: Double) {
                let p = flipped(x, y, in: w)
                guard let event = mouseEvent(.mouseMoved, at: p, in: w) else { return }
                w.contentView?.superview?.hitTest(p)?.mouseMoved(with: event)
                model.mapView?.mouseMoved(with: event)
            }
            let label = at.label
            print("name \"\(label.title)\" at \(Int(at.x)),\(Int(at.y)), lands on \(viewKind(at: flipped(at.x, at.y, in: w), in: w, longest: 24))")
            model.chart.pointerOnLabel(piece: label.pieceIndex)
            print("arrived: lit \(model.hover?.title ?? "nothing")")
            move(at.x, at.y)
            try? await Task.sleep(for: .milliseconds(60))
            print("after a small move: lit \(model.hover?.title ?? "nothing")")
            move(at.x + 2, at.y)
            try? await Task.sleep(for: .milliseconds(60))
            print("after another: lit \(model.hover?.title ?? "nothing")")
        case "labelleave":
            // labelleave 2: the pointer goes from that name to empty space beside the ring.
            guard let w = mainWindow, let at = labelPoint(argument, model) else { print("no such name: \(argument)"); return }
            model.chart.pointerLeftLabel(piece: at.label.pieceIndex)
            moveOnMap(to: flipped(8, 400, in: w), in: w, model)
            print("left: lit \(model.hover?.title ?? "nothing")")
        case "panelhover":
            // panelhover 2: the pointer on the row in the inspector for that name, then moving about on the row a little.
            guard let w = mainWindow, let at = labelPoint(argument, model) else { print("no such name: \(argument)"); return }
            model.highlight(node: at.label.node)
            print("on the row for \"\(at.label.title)\": lit \(model.hover?.title ?? "nothing")")
            for nudge in [0.0, 3.0, 6.0] {
                moveOnMap(to: flipped(w.frame.width - 200 + nudge, 500, in: w), in: w, model)
                try? await Task.sleep(for: .milliseconds(60))
                print("  after a move on the row: lit \(model.hover?.title ?? "nothing")")
            }
            model.highlight(node: nil)
            print("off the row: lit \(model.hover?.title ?? "nothing")")
        case "ringat":
            // ringat 90 0.2: the pointer moved onto the ring at this angle in degrees and share of the radius, handed to this
            // copy's ring alone. The pointer on screen doesn't move.
            guard let asked = point(in: argument), let w = mainWindow else { return }
            let p = onRing(angle: asked.x * .pi / 180, radius: asked.y * model.ring.radius, model)
            moveOnMap(to: flipped(p.x, p.y, in: w), in: w, model)
            print("ringat \(argument): lit \(model.hover?.title ?? "nothing")")
        case "ringpoint":
            // The pointer on the biggest piece of the ring itself.
            guard let w = mainWindow, let piece = biggestPiece(model) else { return }
            let spot = middle(of: piece, model)
            let p = flipped(spot.x, spot.y, in: w)
            print("ring: lands on \(viewKind(at: p, in: w, longest: 24))")
            moveOnMap(to: p, in: w, model)
            print("on the ring: lit \(model.hover?.title ?? "nothing")")
        case "ringclick":
            // ringclick 2 2: a double-click on this piece of the ring, counting what can be clicked. `ringclick 2` is one click.
            let numbers = argument.split(separator: " ").map(String.init)
            let pieces = model.engine.layout.pieces.filter { !$0.isSmaller }
            guard let at = Int(numbers.first ?? ""), pieces.indices.contains(at), let tree = model.tree else {
                print("no such piece: \(argument)"); return
            }
            let piece = pieces[at], spot = middle(of: piece, model)
            print("on the ring at \"\(tree.name(piece.node))\", in \(model.displayName(model.focus)), \(model.plan.count) selected")
            await run("press", "\(spot.x) \(spot.y) \(numbers.count > 1 ? numbers[1] : "1")", model)
            try? await Task.sleep(for: .milliseconds(700))
            print(
                "now in \(model.displayName(model.focus)), selected thing \(model.selected.map(model.displayName) ?? "none"), \(model.plan.count) selected"
            )
        case "labelclick":
            // labelclick 2: what a click on that name does. `labelclick 2 2` is the second click of a double-click.
            // `labelclick Containers` clicks the name that says that.
            var words = argument.split(separator: " ").map(String.init)
            let clicks = words.count > 1 ? words.last.flatMap { Int($0) } : nil
            if clicks != nil { words.removeLast() }
            guard let at = labelPoint(words.joined(separator: " "), model) else { print("no such name: \(argument)"); return }
            print("clicking \"\(at.label.title)\", in \(model.displayName(model.focus)), \(model.plan.count) selected")
            model.chart.labelClicked(piece: at.label.pieceIndex, count: clicks ?? 1)
            try? await Task.sleep(for: .milliseconds(700))
            print(
                "now in \(model.displayName(model.focus)), selected thing \(model.selected.map(model.displayName) ?? "none"), \(model.plan.count) selected"
            )
        case "volume":
            if let facts = VolumeFacts.read(path: argument) { model.switchVolume(facts) } else { print("no such disk: \(argument)") }
        default:
            break
        }
    }

    /// Menus, shortcuts and the clipboard.
    private static func runMenusStep(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "titlemenu":
            // titlemenu Travel SSD: the window title's menu, opened as a click on the title opens it; after a moment the item
            // with that name is chosen from inside it while it's open, and it closes. Nothing touches your real pointer.
            guard let w = mainWindow else { return }
            let wanted = argument, title = flipped(226, 19, in: w)
            _ = firstMenu(
                openedBy: {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = mouseEvent(type, at: title, in: w, clicks: 1, pressure: 1) { NSApp.sendEvent(event) }
                    }
                },
                then: { menu in
                    print("titlemenu: \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title })")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let index = menu.items.firstIndex { $0.title.contains(wanted) }
                        print("titlemenu: choosing \(index.map { menu.items[$0].title } ?? "nothing")")
                        if let index { menu.performActionForItem(at: index) }
                        menu.cancelTracking()
                    }
                })
        case "menu":
            let thing = resolve(argument, model).map { NamedThing($0) } ?? model.actionTarget
            let titles = model.actions(for: thing).map { action in
                (action.startsGroup ? "| " : "") + action.title
                    + (action.submenu.isEmpty
                        ? ""
                        : " > ["
                            + action.submenu.map { ($0.startsGroup ? "| " : "") + ($0.isNote ? "(\($0.title))" : $0.title) }.joined(separator: ", ")
                            + "]")
            }
            print("menu \(argument): \(titles.joined(separator: ", "))")
        case "action":
            let actions = model.actions(for: model.actionTarget)
            if let action = (actions + actions.flatMap(\.submenu)).first(where: { $0.title == argument }) {
                action.run()
            } else {
                print("no such action: \(argument)")
            }
            try? await Task.sleep(for: .milliseconds(60))
        case "clipboard":
            print("clipboard \(argument): \(AppModel.clipboard.string(forType: .string) ?? "nothing") | pill: \(model.tip ?? "none")")
        case "menubar":
            func refresh(_ menu: NSMenu) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                menu.items.compactMap(\.submenu).forEach(refresh)
            }
            func words(_ items: [NSMenuItem]) -> String {
                // Hidden items are only there for their keys, such as the Globe key's, and nobody sees them.
                items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
                    let mask = item.keyEquivalentModifierMask
                    let keys = [(NSEvent.ModifierFlags.control, "⌃"), (.shift, "⇧"), (.option, "⌥"), (.command, "⌘")]
                        .filter { mask.contains($0.0) }.map(\.1).joined()
                    let key =
                        item.keyEquivalent.isEmpty
                        ? "" : " [\(keys)\(item.keyEquivalent == "\u{7F}" || item.keyEquivalent == "\u{8}" ? "⌫" : item.keyEquivalent)]"
                    return (item.state == .on ? "✓" : "") + item.title + (item.isEnabled ? "" : " (off)") + key
                        + (item.submenu.map { " > (" + words($0.items) + ")" } ?? "")
                }.joined(separator: ", ")
            }
            for top in NSApp.mainMenu?.items ?? [] {
                let items = top.submenu?.items ?? []
                top.submenu.map(refresh)
                print("\(top.title): " + words(items))
            }
        case "key":
            guard let w = mainWindow else { return }
            let parts = argument.split(separator: " ").map(String.init)
            guard let key = parts.first else { return }
            var flags: NSEvent.ModifierFlags = []
            if parts.contains("cmd") { flags.insert(.command) }
            if parts.contains("opt") { flags.insert(.option) }
            if parts.contains("shift") { flags.insert(.shift) }
            let characters = key == "delete" ? String(KeyEquivalent.delete.character) : (parts.contains("shift") ? key.uppercased() : key)
            let codes: [String: UInt16] = ["c": 8, "o": 31, "r": 15, "y": 16, "z": 6, "[": 33, "]": 30, "delete": 51]
            guard let event = keyDown(codes[key] ?? 0, typing: characters, flags: flags, in: w) else { return }
            print("key \(argument): \(NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? "handled" : "not handled")")
            try? await Task.sleep(for: .milliseconds(60))
        case "menuitem":
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, var menu = NSApp.mainMenu?.items.first(where: { $0.title == parts[0] })?.submenu else {
                print("no such menu item: \(argument)")
                return
            }
            let path = parts[1].components(separatedBy: " > ")
            for (step, title) in path.enumerated() {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                guard let at = menu.items.firstIndex(where: { $0.title == title }) else {
                    print("no such menu item: \(argument)")
                    return
                }
                if step == path.count - 1 {
                    menu.performActionForItem(at: at)
                } else if let submenu = menu.items[at].submenu {
                    menu = submenu
                } else {
                    print("no submenu at \(title)")
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(60))
        case "copyroute":
            print(
                "⌘C \(argument): \(model.wouldCopySelectedText ? "selected text" : "the name of \(model.actionTarget.nodes.map { model.realName(of: $0) })"), first responder \(mainWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
            )
        case "keys":
            for character in argument { model.handleScriptKey(character) }
        case "keydown":
            // A key as the app gets it, not the menu bar: keydown 49 is space, keydown 123 cmd is ⌘←.
            let words = argument.split(separator: " ")
            guard let w = mainWindow, let first = words.first, let code = UInt16(first) else { return }
            var flags: NSEvent.ModifierFlags = []
            for word in words.dropFirst() {
                switch word {
                case "cmd": flags.insert(.command)
                case "opt": flags.insert(.option)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            if let event = keyDown(code, typing: " ", flags: flags, in: w) { NSApp.sendEvent(event) }
            try? await Task.sleep(for: .milliseconds(120))
        default:
            break
        }
    }

    /// Free Up: ticking, checking, cleaning and undoing.
    private static func runPlanStep(_ command: String, _ argument: String, _ model: AppModel) async {
        /// A suggestion in Free Up, by its title.
        func shownRow(_ title: String) -> WinRow? {
            let row = model.shownRows.first { $0.title == title }
            if row == nil { print("no such row: \(title)") }
            return row
        }
        /// Something planned, by its first path.
        func plannedItem(_ path: String) -> PlanItem? {
            let item = model.plan.items.first { $0.paths.first == path }
            if item == nil { print("no such planned thing: \(path)") }
            return item
        }
        switch command {
        case "tick":
            let rows = model.shownRows.filter(\.isPlannable)
            if let i = Int(argument) {
                if rows.indices.contains(i) { model.toggle(rows[i]) } else { print("no row \(i): \(rows.count) can be ticked") }
            } else if let row = rows.first(where: { $0.title == argument }) {
                model.toggle(row)
            } else {
                print("no such row: \(argument)")
            }
        case "plan":
            if let node = resolve(argument, model) { model.togglePiece(node) } else { print("no such path: \(argument)") }
        case "recommended":
            // recommended: presses Select recommended. recommended point / recommended leave: the pointer on it, and off it.
            if argument == "point" {
                model.pointAtRecommended(true)
            } else if argument == "leave" {
                model.pointAtRecommended(false)
            } else {
                model.selectRecommended()
            }
        case "boxes":
            // boxes: every box in Free Up as it's listed, with what's in it.
            for box in model.boxes {
                print(
                    "box \(box.title) · \(box.isShortlist ? "shortlist" : formatBytes(box.bytes)) · \(box.detail) · \(box.rows.count) rows, \(box.recommended.count) recommended"
                )
            }
        case "box":
            // box quick, box models: ticks a box in the inspector, by its id or its title.
            if let box = model.boxes.first(where: { $0.id == argument || $0.title == argument }) {
                model.toggle(box)
            } else {
                print("no such box: \(argument)")
            }
        case "point":
            // point models: as if the pointer were on that box in the inspector. With nothing after it, the pointer leaves.
            if argument.isEmpty {
                model.point(at: nil)
            } else if let box = model.boxes.first(where: { $0.id == argument || $0.title == argument }) {
                model.point(at: box)
            } else {
                print("no such box: \(argument)")
            }
        case "pointat":
            // pointat Title: as if the pointer were on one thing in the inspector.
            if let box = model.boxes.first(where: { $0.rows.contains { $0.title == argument } }),
                let row = box.rows.first(where: { $0.title == argument })
            {
                model.point(at: box, row: row)
            } else {
                print("no such thing: \(argument)")
            }
        case "open":
            model.openBoxes.insert(argument)
        case "review":
            // Looks at what's selected now.
            model.runChecks()
        case "checked":
            // Waits for the checks to finish, and says how long they took.
            let start = DispatchTime.now()
            while model.isChecking { try? await Task.sleep(for: .milliseconds(50)) }
            print(String(format: "checks took %.2f s", seconds(since: start)))
        case "clean":
            // Only ever acts inside the throwaway test disk: see Cleaner.onlyInside.
            model.cleanNow()
            if argument != "nowait" { while model.cleanProgress != nil { try? await Task.sleep(for: .milliseconds(50)) } }
        case "empty":
            model.emptyNow()
            if argument != "nowait" { while model.afterClean?.isEmptying == true { try? await Task.sleep(for: .milliseconds(50)) } }
        case "undo":
            model.undoClean()
            if argument != "nowait" { while model.isPuttingBack { try? await Task.sleep(for: .milliseconds(50)) } }
        case "othercopies":
            // othercopies Title: what's known about the other copies of a suggestion in Free Up.
            guard let tree = model.tree, let row = model.shownRows.first(where: { $0.title == argument }) else {
                print("no such row: \(argument)"); return
            }
            let video = tree.links.filter { $0.kind == Kind.video.rawValue }
            let found = Accounting.otherCopies(of: row.nodes, in: tree)
            let viaVideo = Accounting.otherCopies(of: row.nodes, in: tree, links: video)
            print(
                "row bytes \(formatBytes(row.bytes)) paper \(formatBytes(row.paperBytes)) copies \(row.otherCopies.count); via video \(viaVideo.folders.count) \(formatBytes(viaVideo.bytes)); nodes \(row.nodes.map { tree.friendlyPath($0) })"
            )
            print(
                "links \(tree.links.count), video links \(video.count), found \(found.folders.count) folders, \(formatBytes(found.bytes)): \(found.folders.prefix(3).map { tree.friendlyPath($0) })"
            )
        case "refreshcheck":
            // A refresh of the map on screen, then a full read straight after, and what differs between them. Reads only.
            guard let tree = model.tree, let volume = model.volume, let journal = model.journal, journal.base == tree.journal else {
                print("refreshcheck: nothing to refresh (whole \(model.tree?.isWhole ?? false), journal \(model.journal != nil))")
                return
            }
            let rules = model.rules
            let access = model.hasFullAccess
            let result = await Task.detached(priority: .userInitiated) { () -> String in
                Self.compareRefresh(of: tree, volume: volume, journal: journal, rules: rules, fullAccess: access)
            }.value
            print(result)
        case "othercopy":
            if let row = shownRow(argument) { model.toggleOtherCopies(of: row) }
        case "moveplan":
            // moveplan /path/to/thing -> /folder/it/goes/into
            let parts = argument.components(separatedBy: " -> ")
            if parts.count == 2, let item = model.plan.items.first(where: { $0.paths.first == parts[0] }) {
                model.setStep(.move(folder: parts[1]), for: item.id)
            } else {
                print("no such planned thing: \(argument)")
            }
        case "tryagain":
            if let item = plannedItem(argument) { model.tryAgain(item) }
        case "uninstallplan":
            // uninstallplan /path/to/Some.app: the planned thing becomes an uninstall, as an unused app's suggestion is.
            if let item = plannedItem(argument) { model.setStep(.uninstall, for: item.id) }
        case "keep":
            if let row = shownRow(argument) { model.keep(row) }
        case "after":
            model.setPreviewAfter(argument != "off")
        case "expand":
            if let row = shownRow(argument) { model.toggleExpanded(row) }
        case "busy":
            // busy anyway|cancel: what Send to Trash is asking, because something is using the folder, and the answer.
            print("busy: \(model.busyToSend.map { "\($0.title) is in use. \($0.why)" } ?? "nothing asked")")
            guard let busy = model.busyToSend else { return }
            if argument.hasPrefix("/") {
                // A picture of the question, which stays open.
                try? await Task.sleep(for: .milliseconds(500))
                if let sheet = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent != nil }) {
                    await picture(of: sheet, to: argument)
                } else {
                    print("no sheet to picture: \(NSApp.windows.map(\.title))")
                }
                return
            }
            model.busyToSend = nil
            if argument == "anyway" {
                model.sendAnyway(busy)
                while model.cleanProgress != nil { try? await Task.sleep(for: .milliseconds(50)) }
            }
        case "cleananyway":
            if let item = plannedItem(argument) { model.acceptInUse(for: item.id) }
        case "button":
            // What the button under the Free Up list says, what's held back, and why.
            print(
                "ready \(model.readyItems.count) of \(model.plan.count); held: \(model.heldBackItems.map { "\($0.title): \(model.checks[$0.id]?.problems.map(\.text) ?? [])" })"
            )
        default:
            break
        }
    }

    /// What things cost: time, memory, frames.
    private static func runMeasuringStep(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "speed":
            // How long things take, from the click to the new picture being ready.
            guard let tree = model.tree else { return }
            if let big = model.boxes.max(by: { $0.rows.count < $1.rows.count }) {
                let tick = averageMilliseconds(20) { model.toggle(big) }
                print(String(format: "a tick on \(big.title), \(big.rows.count) things: %.1f ms", tick))
                let point = averageMilliseconds(20) {
                    model.pointing = nil; model.point(at: big)
                }
                print(String(format: "pointing at it: %.1f ms", point))
                model.pointing = nil
            }
            let list = averageMilliseconds(20) { model.refreshShownRows() }
            print(String(format: "the list for this picture: %.1f ms", list))
            let draw = averageMilliseconds(20) { _ = model.chart.makeLayout() }
            print(String(format: "one picture: %.1f ms", draw))
            let facts = model.facts
            let wins = averageMilliseconds(3) { _ = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts) }
            let all = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts)
            let sections = averageMilliseconds(3) { _ = Sections.build(from: all, tree: tree, facts: facts) }
            let left = averageMilliseconds(3) { _ = Leftovers.find(in: tree) }
            print(String(format: "suggestions %.1f ms, sorting them into sections %.1f ms, of which leftovers %.1f ms", wins, sections, left))
        case "meter":
            // meter start, then meter what it was
            if argument == "start" {
                meter = MainThreadMeter()
            } else {
                meter?.report(argument)
                meter = nil
            }
        case "pacing":
            guard let view = model.mapView else { return }
            if argument == "start" {
                view.drawer.beginNotes()
                meter = MainThreadMeter()
                pacingStarted = CACurrentMediaTime()
                return
            }
            // The last frames say when they reached the screen a moment after they're drawn.
            try? await Task.sleep(for: .milliseconds(200))
            print(
                pacing(
                    view.drawer.endNotes(), interval: mainWindow?.screen?.minimumRefreshInterval ?? 1.0 / 60, since: pacingStarted, label: argument))
            meter?.report(argument)
            meter = nil
        case "touch":
            // So that something outside can tell how far this has got.
            FileManager.default.createFile(atPath: argument, contents: nil)
        case "sweep":
            // sweep ring 5, sweep panel 5: the pointer travelling over the ring or the inspector for that many seconds, without
            // your real one moving.
            guard let w = mainWindow else { return }
            let parts = argument.split(separator: " ").map(String.init)
            // The last word is how many seconds, when it's a number at all: 3 when it isn't.
            let asked = parts.last.flatMap { Double($0) == nil ? nil : $0 } ?? "3"
            guard let seconds = seconds(asked, for: "sweep") else { return }
            let start = Date()
            var step = 0.0
            var moves = 0
            var busy = 0.0, slowest = 0.0, asking = 0.0
            while Date().timeIntervalSince(start) < seconds {
                step += 1
                let at: NSPoint
                if parts.first == "panel" {
                    at = flipped(w.frame.width - 180, 300 + (step.truncatingRemainder(dividingBy: 40)) * 12, in: w)
                } else {
                    let p = onRing(angle: step * 0.19, radius: model.ring.radius * (0.45 + 0.45 * abs(sin(step * 0.03))), model)
                    at = flipped(p.x, p.y, in: w)
                }
                guard let event = mouseEvent(.mouseMoved, at: at, in: w) else { continue }
                let began = DispatchTime.now()
                if parts.first == "panel" { w.contentView?.mouseMoved(with: event) } else { model.mapView?.mouseMoved(with: event) }
                let took = milliseconds(since: began)
                busy += took
                slowest = max(slowest, took)
                moves += 1
                // Part of each move is asking the window what's under the pointer, timed here on its own.
                let asked = DispatchTime.now()
                _ = w.contentView?.superview?.hitTest(at)
                asking += milliseconds(since: asked)
                try? await Task.sleep(for: .milliseconds(12))
            }
            print(
                String(
                    format: "sweep %@: %d moves, %.2f ms each in the call itself, %.1f ms the slowest; asking what's under the pointer takes %.2f ms",
                    argument, moves, busy / Double(max(moves, 1)), slowest, asking / Double(max(moves, 1))))
        case "bench":
            // What everything costs on this disk, in milliseconds. Nothing here changes anything on disk.
            guard let tree = model.tree else { return }
            func time(_ label: String, rounds: Int = 5, _ body: () -> Void) {
                print(String(format: "bench %-34@ %9.2f ms", label as NSString, averageMilliseconds(rounds, body)))
            }
            let home = NSHomeDirectory()
            let facts = model.facts
            let biggest = model.flatTop(tree).first ?? 0
            let library = tree.find(visible: home + "/Library") ?? biggest
            time("reclaimable, biggest") { _ = Accounting.reclaimable([biggest], in: tree) }
            time("story, biggest") { _ = Accounting.story(biggest, in: tree) }
            time("hover line, biggest") { _ = Accounting.hoverLine(biggest, bytes: tree.totals[Int(biggest)], in: tree) }
            time("the top list") { _ = model.flatTop(tree) }
            time("what's inside, Library") { _ = LookContents.rows(of: library, in: tree) }
            time("facts, Library") { _ = LookContents.facts(of: library, in: tree) }
            time("facts, your files") { _ = LookContents.facts(of: tree.home, in: tree) }
            time("pictures, biggest") { _ = LookContents.media(in: biggest, tree: tree) }
            time("the menu for it") { _ = model.actions(for: NamedThing(biggest)) }
            time("kinds, biggest") { _ = tree.kindBytes(biggest) }
            time("find by path") { _ = tree.find(visible: home + "/Library/Caches") }
            time("search: a", rounds: 3) { _ = Search.run("a", in: tree) }
            time("search: mkv", rounds: 3) { _ = Search.run("mkv", in: tree) }
            time("search: node_modules", rounds: 3) { _ = Search.run("node_modules", in: tree) }
            time("search: ø", rounds: 3) { _ = Search.run("ø", in: tree) }
            time("search: blåbær", rounds: 3) { _ = Search.run("blåbær", in: tree) }
            time("one picture") { _ = model.chart.makeLayout() }
            time("the names around it") { model.chart.relabel() }
            let pieces = model.engine.layout.pieces.count
            let middle = pieces > 0 ? model.engine.layout.pieces[pieces / 2].node : 0
            time("hover on, hover off", rounds: 20) {
                model.chart.point(at: middle); model.chart.point(at: nil)
            }
            time("zoom in and back", rounds: 3) {
                model.zoom(into: RingLayout.chainTail(tree: tree, biggest)); model.go(to: 0)
            }
            time("the list for this picture") { model.refreshShownRows() }
            time("Map to Free Up and back", rounds: 3) {
                model.setLens(.freeUp); model.setLens(.map)
            }
            time("open files", rounds: 3) { _ = OpenFiles.snapshot() }
            func check(_ items: [PlanItem], fresh: Bool = true, thorough: Bool = false) {
                _ = PlanChecks.run(items: items, trueBytes: [:], otherCopy: [:], runningApps: [], fullAccess: true, fresh: fresh, thorough: thorough)
            }
            let one = [
                PlanItem(id: "bench", title: "bench", note: "", tierRaw: Tier.yourCall.rawValue, paths: [home + "/Library"], lastKnownBytes: 0)
            ]
            time("check one thing", rounds: 1) { check(one) }
            time("check one thing, as a clean does", rounds: 1) { check(one, thorough: true) }
            let everything = model.shownRows.filter(\.isPlannable).compactMap { row -> PlanItem? in
                let paths = row.nodes.compactMap { tree.path($0).map(PathMath.visible) }
                return paths.isEmpty
                    ? nil : PlanItem(id: row.id, title: row.title, note: "", tierRaw: row.tier.rawValue, paths: paths, lastKnownBytes: row.bytes)
            }
            print("bench \(everything.count) things could be ticked, \(everything.reduce(0) { $0 + $1.paths.count }) paths")
            time("check them all, first time", rounds: 1) { check(everything) }
            time("check them all, again", rounds: 3) { check(everything) }
            time("check them all, while ticking", rounds: 3) { check(everything, fresh: false) }
            let tops = model.shownRows.filter(\.isPlannable).flatMap(\.nodes)
            print("bench \(tops.count) nodes in those")
            time("what they'd free", rounds: 3) { _ = Accounting.effect(of: tops, except: [], in: tree) }
            let effect = Accounting.effect(of: tops, except: [], in: tree)
            time("the disk as it'd be after", rounds: 3) { _ = AfterPlan(tree: tree, ids: tops, excluded: [], effect: effect) }
            time("the other copies of each", rounds: 1) { for row in model.shownRows { _ = Accounting.otherCopies(of: row.nodes, in: tree) } }
            if let volume = model.volume {
                time("save the map", rounds: 1) { TreeCache.save(tree, for: volume, rules: model.rules) }
                time("read the saved map", rounds: 3) { _ = TreeCache.load(for: volume, rules: model.rules) }
            }
            time("gather facts, afresh", rounds: 1) { _ = Facts.gather(tree: tree, running: [], fullAccess: true, reusing: nil) }
            time("gather facts, again", rounds: 2) { _ = Facts.gather(tree: tree, running: [], fullAccess: true, reusing: facts) }
            time("newest change, 40,000 files", rounds: 1) { _ = Walker.newestChange(in: home + "/Library", limit: 40_000) }
            time("size of ~/Media", rounds: 3) { _ = Walker.size(of: home + "/Media") }
            time("size of ~/dev", rounds: 1) { _ = Walker.size(of: home + "/dev") }
            time("size of ~/Library", rounds: 1) { _ = Walker.size(of: home + "/Library") }
            time("suggestions", rounds: 3) { _ = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts) }
            let all = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts)
            time("sorting them into boxes", rounds: 3) { _ = Sections.build(from: all, tree: tree, facts: facts) }
            time("changes map", rounds: 3) { _ = ChangeMap(tree: tree, window: model.changeWindow) }
            time("untouched for a year", rounds: 3) {
                _ = AppModel.changeMap(tree: tree, window: .untouched(365), rules: model.rules, facts: model.facts)
            }
            // What you've used lately counts as touched, so it has to be found on the map.
            let known = model.facts
            let since = Date().addingTimeInterval(-91 * 86_400)
            let apps = known.apps.filter { $0.isRunning || ($0.newestSign ?? .distantPast) >= since }.count
            let watched = known.plexFiles.values.filter { ($0.lastViewed ?? .distantPast) >= since }.count
            let played = known.games.filter { ($0.lastPlayed ?? .distantPast) >= since }.count
            let opened = known.lastOpened.values.filter { $0 >= since }.count
            let found = ChangeMap.usedRecently(known, in: tree, days: 91).count
            print(
                "used in the last 3 months: \(apps) apps, \(watched) watched, \(played) played, \(opened) opened; \(found) of them found on the map")
        case "leaks":
            findLeaks(in: model)
        case "format":
            // format wide|narrow|auto: the picture on screen in one format, for comparing them.
            MapHostView.forcedFormat =
                argument == "wide" ? SunburstRenderer.outputFormat : argument == "narrow" ? SunburstRenderer.narrowOutputFormat : nil
            model.mapView?.startAnimating()
            try? await Task.sleep(for: .milliseconds(400))
        case "gpu":
            // What the GPU holds for the ring, texture by texture.
            print("gpu \(model.engine.allocations())")
        case "headroom":
            // How far above white this screen can go now, and at most: what the picture's format has to hold.
            if let screen = mainWindow?.screen {
                print(
                    "headroom now \(screen.maximumExtendedDynamicRangeColorComponentValue), at most \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), reference \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)"
                )
            }
        case "memory":
            // memory label: how much memory the app is using now, and the most it has used so far.
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS {
                print(
                    String(
                        format: "memory %@: %.0f MB now, %.0f MB at most", argument, Double(info.phys_footprint) / 1e6,
                        Double(info.ledger_phys_footprint_peak) / 1e6))
            }
        case "state":
            // state label: one line saying what's on screen and selected, for checking what an action did.
            let pair = model.pair.flatMap { $0.tree === model.tree ? $0 : nil }
            let shown = pair.map { $0.realFolder == 0 ? "both disks" : "both disks at \($0.folderName)" } ?? model.realName(of: model.focus)
            let side =
                pair.map { p in model.focus == 0 ? "" : model.focus == p.macSide ? " (Mac half)" : model.focus == p.driveSide ? " (drive half)" : "" }
                ?? ""
            print(
                "state \(argument) | \(model.mode.title) | \(model.view.title) | in \(shown)\(side) | inspector \(model.selected.map { model.realName(of: $0) } ?? "nothing") | free up \(model.plan.items.count) | backup \(model.backup.items.count) | card \(model.look.map { model.realName(of: $0.node) } ?? "closed") | tip \(model.tip ?? "none")"
            )
        case "pointon", "clickon":
            // pointon path, clickon path [clicks]: the pointer on that thing's piece, and a click there, as the mouse makes them.
            let words = argument.split(separator: " ").map(String.init)
            let clicks = command == "clickon" && words.count > 1 ? words.last.flatMap { Int($0) } : nil
            let path = clicks == nil ? argument : words.dropLast().joined(separator: " ")
            guard let w = mainWindow, let view = model.mapView, let node = resolve(path, model),
                let i = model.engine.layout.pieces.firstIndex(where: { $0.node == node })
            else { print("\(command) \(path): not on the ring"); return }
            let spot = middle(of: model.engine.layout.pieces[i], model), at = flipped(spot.x, spot.y, in: w)
            func event(_ type: NSEvent.EventType, _ count: Int) -> NSEvent? { mouseEvent(type, at: at, in: w, clicks: count, pressure: 1) }
            if let moved = event(.mouseMoved, 0) { view.mouseMoved(with: moved) }
            try? await Task.sleep(for: .milliseconds(150))
            if command == "clickon" {
                for count in 1...clickCount(clicks ?? 1, for: command) {
                    if let down = event(.leftMouseDown, count), let up = event(.leftMouseUp, count) {
                        view.mouseDown(with: down)
                        view.mouseUp(with: up)
                    }
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        case "clickplace":
            // clickplace middle | empty | smaller | free | machalf: a click on the middle of the ring, away from it, on the first
            // "smaller items", on free space, or on the Mac's half.
            guard let w = mainWindow, let view = model.mapView else { return }
            let pieces = model.engine.layout.pieces
            var point: CGPoint?
            switch argument {
            case "middle": point = model.ring.center
            case "empty": point = CGPoint(x: 12, y: w.frame.height - 80)
            default:
                let found: Int?
                switch argument {
                case "smaller": found = pieces.firstIndex { $0.isSmaller && $0.ring > 0 }
                case "free": found = model.tree.flatMap { tree in pieces.firstIndex { $0.node == tree.free } }
                case "machalf": found = model.pair.flatMap { pair in pieces.firstIndex { $0.node == pair.macSide } }
                case "drivehalf": found = model.pair.flatMap { pair in pieces.firstIndex { $0.node == pair.driveSide } }
                default: found = nil
                }
                if let found {
                    point = middle(of: pieces[found], model)
                    if argument == "smaller", let tree = model.tree { print("clickplace smaller: in \(tree.name(pieces[found].node))") }
                }
            }
            guard let point else { print("clickplace \(argument): none"); return }
            let at = flipped(point.x, point.y, in: w)
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                guard let e = mouseEvent(type, at: at, in: w, clicks: 1, pressure: 1) else { continue }
                switch type {
                case .mouseMoved: view.mouseMoved(with: e)
                case .leftMouseDown: view.mouseDown(with: e)
                default: view.mouseUp(with: e)
                }
            }
            try? await Task.sleep(for: .milliseconds(900))
        case "menufor":
            // menufor path: the items of that thing's right-click menu on the ring, without showing it.
            guard let node = resolve(argument, model), let thing = model.thing(onRing: node), let menu = model.menu(for: thing) else {
                print("menufor \(argument): no menu"); return
            }
            print("menufor \(model.realName(of: node)): " + menu.items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ", "))
        case "mapkey":
            // mapkey 49 [shift] [cmd]: a key pressed while the ring has the keyboard, given to the ring's view alone, so no window
            // comes forward. 49 is Space, 53 Escape, 51 Delete.
            let words = argument.split(separator: " ")
            guard let w = mainWindow, let view = model.mapView, let first = words.first, let code = UInt16(first) else { return }
            var flags: NSEvent.ModifierFlags = []
            if words.contains("shift") { flags.insert(.shift) }
            if words.contains("cmd") { flags.insert(.command) }
            if let event = keyDown(code, typing: code == 49 ? " " : "", flags: flags, in: w) { view.keyDown(with: event) }
            try? await Task.sleep(for: .milliseconds(600))
        case "stretches":
            // stretches /some/folder: each piece the folder is drawn as, where it is in points, and what's first over it.
            guard let tree = model.tree, let node = resolve(argument, model) else { print("stretches \(argument): no such folder"); return }
            let pieces = model.engine.layout.pieces
            for (i, p) in pieces.enumerated() where p.node == node {
                let at = middle(of: p, model)
                let over = i + 1 < pieces.count && pieces[i + 1].parent == Int32(i) ? tree.name(pieces[i + 1].node) : "nothing"
                print(
                    String(
                        format: "stretch %d of %@: %.0f°-%.0f°, at %.1f %.1f, %@, colour %.2f %.2f %.2f, tail %@, first over it %@", i, argument,
                        Double(p.a0) * 180 / .pi, Double(p.a1) * 180 / .pi, at.x, at.y, formatBytes(p.size), p.color.x, p.color.y,
                        p.color.z, tree.name(p.tail), over))
            }
        case "middle":
            // What the middle of the ring says now, and what's under the pointer.
            print("middle \(argument): says \(model.hoverShown?.title ?? "nothing"), pointer on \(model.hover?.title ?? "nothing")")
        case "exporttree":
            // exporttree /path/out.json: the disk as read, for another program to draw: every folder and file of at least
            // 1/200,000 of the disk, with the rest of each folder only counted. Read-only.
            guard let tree = model.tree else { print("no tree"); return }
            let least = max(tree.capacityBytes / 200_000, 1)
            var count = 0
            func node(_ id: UInt32, depth: Int) -> [String: Any] {
                let n = tree.nodes[Int(id)]
                let role =
                    n.has(NodeFlag.free)
                    ? "free"
                    : n.has(NodeFlag.hidden)
                        ? "unreadable"
                        : n.has(NodeFlag.synthetic) ? "system" : "item"
                var out: [String: Any] = [
                    "n": id == 0 ? tree.volumeName : tree.name(id), "s": tree.totals[Int(id)],
                    "f": n.has(NodeFlag.directory) || n.has(NodeFlag.synthetic) ? 1 : 0, "r": role,
                ]
                count += 1
                let kids = tree.children(id)
                let shown = depth < 14 ? kids.filter { tree.totals[Int($0)] >= least } : []
                if !shown.isEmpty { out["c"] = shown.sorted { tree.totals[Int($0)] > tree.totals[Int($1)] }.map { node($0, depth: depth + 1) } }
                if kids.count > shown.count { out["o"] = kids.count - shown.count }
                return out
            }
            let root: [String: Any] = [
                "volume": tree.volumeName, "capacity": tree.capacityBytes, "free": tree.freeBytes,
                "root": node(0, depth: 0),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: argument))
                print("exported \(count) nodes, \(data.count / 1024) KB")
            }
        case "palette":
            // palette cool: the map in one of SunburstKit's palettes, by id.
            guard let palette = SunburstPalette.all.first(where: { $0.id == argument }) else { print("no palette \(argument)"); return }
            model.palette = palette
        case "glow":
            // glow off, glow on.
            model.showsGlow = argument != "off"
        case "memoryshort":
            // What happens when macOS says memory is short, without making it short: what was made ahead is let go.
            model.letGoOfReadyPair()
        case "labels":
            // Each name on the ring, where it is, and the ways its piece's name can be written.
            let layout = model.engine.layout
            for label in model.chart.labels {
                let full = label.pieceIndex < layout.pieces.count ? model.displayName(layout.pieces[label.pieceIndex].node) : "?"
                print("label \(label.place) \(label.title) | forms \(model.chart.nameForms(ofPiece: label.pieceIndex, full: full))")
            }
        case "names":
            // names off, names on: the names around the ring hidden or shown, to tell what they cost.
            model.chart.showsLabels = argument != "off"
        case "layers":
            // The window's layers that hold a drawing of their own, biggest first: what's redrawn whole when anything in it
            // changes.
            guard let root = mainWindow?.contentView?.superview?.layer else { print("no layers"); return }
            var found: [(area: CGFloat, line: String)] = []
            var count = 0
            func walk(_ layer: CALayer, depth: Int) {
                count += 1
                let size = layer.bounds.size
                if layer.contents != nil || !(layer.sublayers?.isEmpty == false) {
                    let name = String(describing: type(of: layer))
                    let at = layer.convert(layer.bounds, to: root)
                    found.append(
                        (
                            size.width * size.height,
                            String(
                                format: "%@ %.0f × %.0f at %.0f, %.0f%@", name, size.width, size.height,
                                at.minX, at.minY, layer.contents == nil ? "" : " drawn")
                        ))
                }
                for sub in layer.sublayers ?? [] { walk(sub, depth: depth + 1) }
            }
            walk(root, depth: 0)
            print("layers \(argument): \(count) in all")
            for item in found.sorted(by: { $0.area > $1.area }).prefix(max(Int(argument.split(separator: " ").last ?? "") ?? 25, 0)) {
                print("  " + item.line)
            }
        case "frames":
            print("frames drawn \(argument): \(model.mapView?.framesDrawn ?? -1), ring at \(model.engine.placeNow)")
        case "footprint":
            // What the memory is made of, by the tool macOS has for it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            print(String(decoding: data, as: UTF8.self))
        default:
            break
        }
    }

    /// The window itself: its size, its pictures, the pointer over it.
    private static func runWindowStep(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "panel":
            model.showPanel(argument != "off")
        case "scrolls":
            // Where each list in the window starts and is scrolled to, beside the room kept for the toolbar above it. A list
            // whose top is out of sight under the toolbar shows as scrolled past that room.
            guard let w = mainWindow, let root = w.contentView?.superview else { print("no window"); return }
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, scroll.frame.width > 40 {
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    print(
                        String(
                            format: "scroll x %.0f top %.0f, %.0f × %.0f: room %.0f, scrolled to %.0f, content %.0f tall",
                            frame.minX, w.frame.height - frame.maxY, frame.width, frame.height, scroll.contentInsets.top,
                            scroll.contentView.bounds.minY, scroll.documentView?.frame.height ?? 0))
                }
                view.subviews.forEach(walk)
            }
            walk(root)
        case "voiceover":
            guard let view = model.mapView else { return }
            func heard() -> String {
                (view.accessibilityChildren() ?? []).prefix(8).compactMap { $0 as? NSAccessibilityElement }.map {
                    "\($0.accessibilityLabel() ?? "?") (\(($0.accessibilityValue() as? String) ?? "?"))"
                }.joined(separator: ", ")
            }
            print("voiceover \(view.accessibilityLabel() ?? "?"): \(heard())")
            if argument == "press", let first = view.accessibilityChildren()?.first as? NSAccessibilityElement {
                _ = first.accessibilityPerformPress()
                try? await Task.sleep(for: .milliseconds(600))
                print("voiceover after pressing \(first.accessibilityLabel() ?? "?"): \(view.accessibilityLabel() ?? "?"): \(heard())")
            }
        case "size":
            // size w h [x y [fixed]]: with fixed (1) the window can't be resized from then on, so it keeps a size larger than
            // the screen (a recording at a size this screen can't show: macOS fits a resizable window between the menu bar
            // and the Dock, and still draws the part of a window past the screen's edges).
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard [2, 4, 5].contains(numbers.count), numbers.allSatisfy(\.isFinite) else {
                print("size \(argument): needs w h [x y [fixed]]"); return
            }
            guard let w = mainWindow else { print("size \(argument): no window"); return }
            guard let size = windowSize(numbers[0], numbers[1], of: w, for: "size \(argument)") else { return }
            if numbers.count == 5, numbers[4] != 0 { w.styleMask.remove(.resizable) }
            // At once, even in the same instant as the step before's animated change: `Motion.animate` makes that safe.
            var frame = w.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            if numbers.count >= 4, let screen = w.screen ?? NSScreen.main {
                frame.origin = CGPoint(x: screen.frame.minX + numbers[2], y: screen.frame.maxY - numbers[3] - size.height)
            }
            w.setFrame(frame, display: true)
        case "jiggle":
            // New frames all the time, so that animated changes meet them in the same turn of the run loop.
            guard let w = mainWindow, let seconds = seconds(argument, for: "jiggle") else { return }
            let start = w.frame.size
            let until = Date().addingTimeInterval(seconds)
            var flip = false, frames = 0
            let timer = Timer(timeInterval: 0.008, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard Date() < until else {
                        timer.invalidate()
                        print(
                            "jiggle: \(frames) new frames, from \(Int(start.width))x\(Int(start.height)) to \(Int(w.frame.width))x\(Int(w.frame.height))"
                        )
                        return
                    }
                    var frame = w.frame
                    frame.size.width += flip ? 3 : -3
                    flip.toggle()
                    w.setFrame(frame, display: true)
                    frames += 1
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        case "collide":
            // collide 860 620 asks for that size; without numbers, a little smaller than now.
            guard let w = mainWindow else { return }
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            var frame = w.frame
            let asked =
                numbers.count == 2 ? CGSize(width: numbers[0], height: numbers[1]) : CGSize(width: frame.width - 40, height: frame.height - 30)
            guard let size = windowSize(asked.width, asked.height, of: w, for: "collide \(argument)") else { return }
            Motion.animate(Motion.switching) { model.setView(model.view == .map ? .changes : .map) }
            frame.origin.y += frame.height - size.height
            frame.size = size
            w.setFrame(frame, display: true)
            print(String(format: "collide: asked for %.0fx%.0f", frame.width, frame.height))
        case "timescale":
            model.engine.timeScale = Float(argument) ?? 1
        case "shotwindow":
            // A picture of another window, by its title: "shotwindow Update Headroom /path.png".
            guard let cut = argument.range(of: " /") else { print("shotwindow needs a title and a path"); return }
            let title = String(argument[..<cut.lowerBound]), path = String(argument[argument.index(after: cut.lowerBound)...])
            guard let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else { print("no window called \(title)"); return }
            print(await picture(of: w, to: path) ? "shot \(path)" : "no shot at \(path)")
        case "shot":
            guard let w = mainWindow else { print("no window"); return }
            print(await picture(of: w, to: argument) ? "shot \(argument)" : "no shot at \(argument)")
        case "drawn":
            // drawn /path/to/picture.png: the window as the app itself draws it, with no screen needed: for when the screen is
            // locked or asleep, or can't be recorded. The ring is drawn again for it, and everything layered over the ring
            // is there as it is. Glass, blur and other effects the system adds on screen aren't.
            guard let w = mainWindow, let root = w.contentView?.superview, let rootLayer = root.layer, let map = model.mapView,
                let mapLayer = map.layer
            else { print("no window"); return }
            let scale = w.backingScaleFactor
            let width = Int(root.bounds.width * scale), height = Int(root.bounds.height * scale)
            // A window nobody can see draws no frames, so nothing on the ring has moved since it last could be.
            model.engine.settle()
            guard let space = CGColorSpace(name: CGColorSpace.displayP3),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { print("no picture"); return }
            // The ring's own layer is drawn by the GPU, which a layer drawn here knows nothing of. So the ring is drawn into
            // an image, held by a layer inside its own for as long as this takes: never long enough to reach the screen.
            let stand = CALayer()
            stand.frame = mapLayer.bounds
            stand.contents = model.chart.picture(
                width: Int(map.bounds.width * scale), height: Int(map.bounds.height * scale), scale: scale, inPlace: true)
            stand.contentsGravity = .resize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mapLayer.addSublayer(stand)
            context.setFillColor(NSColor(Palette.window).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            // What the system draws for glass and blur comes out as flat white or black here, over what's behind it. Those
            // layers are left out, and put back before anything reaches the screen.
            var left: [CALayer] = []
            func leaveOutEffects(_ layer: CALayer) {
                let kind = String(describing: type(of: layer))
                if !layer.isHidden, ["Backdrop", "Chameleon", "Portal", "SDF"].contains(where: kind.contains) {
                    layer.isHidden = true
                    left.append(layer)
                    return
                }
                for sub in layer.sublayers ?? [] { leaveOutEffects(sub) }
            }
            leaveOutEffects(rootLayer)
            rootLayer.render(in: context)
            for layer in left { layer.isHidden = false }
            stand.removeFromSuperlayer()
            CATransaction.commit()
            guard let image = context.makeImage(),
                let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: argument) as CFURL, "public.png" as CFString, 1, nil)
            else {
                print("no picture"); return
            }
            CGImageDestinationAddImage(out, image, nil)
            print(CGImageDestinationFinalize(out) ? "drawn \(argument)" : "couldn't write \(argument)")
        case "about":
            // about /path/to/picture.png: About Headroom from the app menu, as a click on it would open it.
            let titles = { NSApp.windows.filter(\.isVisible).map(\.title) }
            print("open before: \(titles())")
            guard chooseFromAppMenu("About Headroom") else { print("no About item"); return }
            try? await Task.sleep(for: .milliseconds(600))
            print("open after: \(titles())")
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "About Headroom" }) else {
                print("no About window")
                return
            }
            print(
                "about: \(w.frame.size), resizable \(w.styleMask.contains(.resizable)), minimize \(w.standardWindowButton(.miniaturizeButton)?.isEnabled == true), zoom \(w.standardWindowButton(.zoomButton)?.isEnabled == true)"
            )
            print(await picture(of: w, to: argument) ? "shot \(argument)" : "no shot at \(argument)")
        case "film":
            let parts = argument.split(separator: " ").map(String.init)
            guard parts.count == 3, let length = seconds(parts[0], for: "film"), let step = seconds(parts[1], for: "film") else { return }
            // A count of frames that can be made: a step of zero, or below it, would make it infinite or a trap.
            guard step >= 0.01, (0...360_000).contains(length / step) else {
                print("film \(argument): needs a step of 0.01 s or more, for at most 360,000 frames"); return
            }
            guard let window = mainWindow, mayTakePictures else { return }
            let number = window.windowNumber, name = parts[2], frames = Int(length / step)
            Task.detached {
                for frame in 0..<frames {
                    _ = photograph(window: number, to: name + String(format: "-%03d.png", frame))
                    try? await Task.sleep(for: .seconds(step))
                }
            }
        case "mouse", "click":
            guard let p = point(in: argument), let view = model.mapView, let w = mainWindow else { return }
            let at = flipped(p.x, p.y, in: w)
            func event(_ type: NSEvent.EventType) -> NSEvent? { mouseEvent(type, at: at, in: w, clicks: 1, pressure: 1) }
            if command == "mouse" {
                if let e = event(.mouseMoved) { view.mouseMoved(with: e) }
                print("mouse \(argument) hover: \(model.hover?.title ?? "nothing"), the middle says: \(model.hoverShown?.title ?? "nothing")")
            } else if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
                view.mouseDown(with: down)
                view.mouseUp(with: up)
            }
        case "activate":
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        case "float":
            // Stage Manager shrinks a window it can't bring forward, as on a locked screen. It leaves floating ones alone.
            mainWindow?.level = .floating
            mainWindow?.orderFrontRegardless()
        case "hide":
            NSApp.hide(nil)
        case "unhide":
            NSApp.unhide(nil)
        case "minimize":
            mainWindow?.miniaturize(nil)
        case "restore":
            mainWindow?.deminiaturize(nil)
        case "lose":
            model.mapView?.loseWhatItMayLose()
        case "redraw":
            model.mapView?.startAnimating()
        case "stopwhenhidden":
            // As in real use, where nothing is drawn while the window can't be seen.
            MapHostView.drawsWhenHidden = false
        case "windowid":
            // The window's number and frame, for a recorder outside the app.
            if let w = mainWindow {
                print(
                    "window \(w.windowNumber) at \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)), backing \(w.backingScaleFactor)"
                )
            }
        case "frame":
            // Where the window is, whether it fills the screen, and whether it has been told to move.
            if let w = mainWindow {
                print(
                    "frame \(argument): \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)) zoomed \(w.isZoomed); moves started \(model.mapView?.windowMovesStarted ?? -1); selected \(model.selected.map { model.displayName($0) } ?? "nothing")"
                )
            }
        case "press":
            // press x y clicks [dx dy]: a click, double-click or drag at points from the window's top left, given straight to
            // the app. Your real pointer doesn't move. `press piece` picks the middle of the biggest piece on the ring.
            guard let w = mainWindow else { return }
            var parts = argument.split(separator: " ").map(String.init)
            var x = 0.0, y = 0.0
            var flags: NSEvent.ModifierFlags = []
            if parts.first == "cmd" {
                parts.removeFirst()
                flags = .command
            }
            if parts.first == "piece" {
                parts.removeFirst()
                guard let piece = biggestPiece(model) else { print("press: no piece among \(model.engine.layout.pieces.count)"); return }
                let spot = middle(of: piece, model)
                x = spot.x
                y = spot.y
            } else {
                guard parts.count >= 3, let px = Double(parts[0]), let py = Double(parts[1]) else { return }
                x = px
                y = py
                parts.removeFirst(2)
            }
            let clicks = clickCount(Int(parts.first ?? "1") ?? 1, for: "press")
            let dx = parts.count > 2 ? Double(parts[1]) ?? 0 : 0, dy = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
            guard [x, y, dx, dy].allSatisfy({ $0.isFinite && abs($0) < 1e6 }) else { print("press \(argument): not a place in the window"); return }
            func send(_ type: NSEvent.EventType, _ px: Double, _ py: Double, count: Int) {
                if let event = mouseEvent(type, at: flipped(px, py, in: w), in: w, clicks: count, pressure: 1, flags: flags) {
                    NSApp.sendEvent(event)
                }
            }
            print("press at \(Int(x)),\(Int(y)) lands on \(viewKind(at: flipped(x, y, in: w), in: w))")
            for click in 1...clicks {
                send(.leftMouseDown, x, y, count: click)
                if dx != 0 || dy != 0 {
                    for step in 1...6 { send(.leftMouseDragged, x + dx * Double(step) / 6, y + dy * Double(step) / 6, count: click) }
                }
                send(.leftMouseUp, x + dx, y + dy, count: click)
                try? await Task.sleep(for: .milliseconds(80))
            }
        default:
            break
        }
    }

    /// The card that Shift-Space opens.
    private static func runCardStep(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "look":
            if let node = resolve(argument, model) { model.openLook(node) } else { model.toggleLook() }
            try? await Task.sleep(for: .milliseconds(400))
        case "cardpress":
            // cardpress x y [clicks]: a click on the card's window, at points from its top left, given to the app alone.
            guard let w = LookPanel.shared.window, w.isVisible else { print("cardpress: no card"); return }
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count >= 2, numbers.allSatisfy({ $0.isFinite && abs($0) < 1e6 }) else {
                print("cardpress \(argument): needs x y [clicks]"); return
            }
            let at = flipped(numbers[0], numbers[1], in: w)
            let target = w.contentView?.hitTest(at)
            print("cardpress at \(Int(numbers[0])),\(Int(numbers[1])) lands on \(target.map { String(describing: type(of: $0)) } ?? "nothing")")
            for click in 1...clickCount(numbers.count > 2 ? Int(numbers[2]) : 1, for: "cardpress") {
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    if let event = mouseEvent(type, at: at, in: w, clicks: click, pressure: 1) { NSApp.sendEvent(event) }
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
        case "carddrag":
            // carddrag x y dx dy: a press on the card's window that moves the pointer this far before letting go.
            guard let w = LookPanel.shared.window, w.isVisible else { print("carddrag: no card"); return }
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 4, numbers.allSatisfy({ $0.isFinite && abs($0) < 1e6 }) else {
                print("carddrag \(argument): needs x y dx dy"); return
            }
            let before = w.frame.origin
            func event(_ type: NSEvent.EventType, _ dx: Double, _ dy: Double) -> NSEvent? {
                mouseEvent(type, at: flipped(numbers[0] + dx, numbers[1] + dy, in: w), in: w, clicks: 1, pressure: 1)
            }
            // What follows the press is waiting before it, as when a hand drags.
            for step in 1...8 {
                if let e = event(.leftMouseDragged, numbers[2] * Double(step) / 8, numbers[3] * Double(step) / 8) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            if let up = event(.leftMouseUp, numbers[2], numbers[3]) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown, 0, 0) { NSApp.sendEvent(down) }
            try? await Task.sleep(for: .milliseconds(300))
            print("carddrag: moved from \(Int(before.x)),\(Int(before.y)) to \(Int(w.frame.minX)),\(Int(w.frame.minY))")
        case "cardframe":
            // cardframe x y w h: as if the card's window had been dragged and sized there, its top left from the screen's.
            guard let w = LookPanel.shared.window, let screen = w.screen ?? NSScreen.main else { print("cardframe: no card"); return }
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 4, numbers.allSatisfy({ $0.isFinite && abs($0) < 1e6 }), numbers[2] > 0, numbers[3] > 0 else {
                print("cardframe \(argument): needs x y w h"); return
            }
            w.setFrame(
                NSRect(x: screen.frame.minX + numbers[0], y: screen.frame.maxY - numbers[1] - numbers[3], width: numbers[2], height: numbers[3]),
                display: true)
        case "card":
            // What the card is showing, and what its first button would do.
            if let look = model.look, let tree = model.tree {
                print(
                    "card \(argument): \(model.realName(of: look.node)) on the \(look.onLeft ? "left" : "right"), \(model.lookRows(of: look.node, in: tree).count) rows, \(look.back.count) back, cursor \(model.lookCursor.map(String.init) ?? "none"), facts: \(model.facts(of: look.node) ?? "none"), lit: \(model.hover?.title ?? "nothing")"
                )
                let place =
                    LookPanel.shared.window.map { w in
                        "window \(Int(w.frame.width))x\(Int(w.frame.height)) at \(Int(w.frame.minX)),\(Int(w.frame.minY))\(w.isVisible ? "" : ", hidden"), key \(w.isKeyWindow), main window at \(Int(model.mapView?.window?.frame.minX ?? -1)),\(Int(model.mapView?.window?.frame.minY ?? -1))"
                    } ?? "no window"
                let details = model.lookDetails
                print(
                    "  \(place); media \(details.media ?? "none"), aspect \(details.aspect.map { String(format: "%.3f", $0) } ?? "none"), use \(details.lastUse ?? "none"), frees \(details.frees.map(formatBytes) ?? "?"); selected \(model.selected.map { model.realName(of: $0) } ?? "nothing"), planned \(model.isPlanned(look.node)), playing \(model.lookIsPlaying), main window key \(model.mapView?.window?.isKeyWindow == true)"
                )
            } else {
                print("card \(argument): closed")
            }
        default:
            break
        }
    }

    /// Looking for a new version and putting it in place.
    private static func runUpdatesStep(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "checkupdates":
            Updater.shared.checkNow()
            Updater.shared.bringForward()
        case "installupdate":
            if case .available(let release) = Updater.shared.state {
                Updater.shared.install(release)
            } else {
                print("no update to install: \(Updater.shared.state)")
            }
        case "signedlikethis":
            // Whether the updater would take the app at this path.
            print("signed like this app: \(Updater.isSignedLikeThis(URL(fileURLWithPath: argument))) — \(argument)")
        case "updatestate":
            print("update state \(Updater.shared.state)")
            if case .available(let release) = Updater.shared.state {
                print("update window: Headroom \(Updater.name(of: release)) is out. You have \(Updater.currentName(besides: release)).")
            }
        default:
            break
        }
    }

    /// Somewhere on a name around the ring, by its number among those names.
    private static func labelPoint(_ argument: String, _ model: AppModel) -> (label: SunburstLabel, x: Double, y: Double)? {
        let names = model.chart.labels.filter(\.isAtSide)
        // A number counts the names beside the ring; anything else is a name's own text.
        guard let label = Int(argument).flatMap({ names.indices.contains($0) ? names[$0] : nil }) ?? names.first(where: { $0.title == argument })
        else { return nil }
        return (label, label.position.x + (label.place == .right ? 18 : -18), label.position.y)
    }

    /// With --hide-names: everything the app has ready to show, checked against the real names on this disk. A hit is printed to
    /// be read, because a real folder can have an everyday name.
    private static func findLeaks(in model: AppModel) {
        guard let tree = model.tree else { return }
        var real = Set<String>()
        for id in tree.displayNames.keys {
            let raw = tree.rawName(id).lowercased()
            guard raw.count >= 4, !raw.hasPrefix("/") else { continue }
            real.insert(raw)
            real.insert((raw as NSString).deletingPathExtension)
        }
        real.insert(NSUserName().lowercased())
        for volume in model.volumes where !volume.isBoot { real.insert(volume.name.lowercased()) }
        for disk in model.facts.knownDisks { real.insert(disk.lowercased()) }

        // Strings that are never shown: what things are known by, and where they are for doing something with them.
        let unshown: Set<String> = ["id", "command", "bundleID", "appPath", "previewPath", "otherCopiesPath", "extraPaths", "key"]
        var lines: [(place: String, text: String)] = []
        func collect(_ place: String, _ value: Any) {
            if let text = value as? String {
                lines.append((place, text))
                return
            }
            for child in Mirror(reflecting: value).children {
                if let label = child.label, unshown.contains(label) { continue }
                collect(place, child.value)
            }
        }
        // Everything big enough to have a name on screen, and what's right inside it.
        var things = model.flatTop(tree)
        for top in things.prefix(60) { things += tree.children(top).prefix(12) }
        for lens in [Lens.map, .changes, .freeUp] {
            model.setLens(lens)
            collect("list", model.shownRows)
            model.chart.relabel()
            collect("names around the ring", model.chart.labels)
        }
        for window in [ChangeWindow.lastScan, .days(7), .days(30), .untouched(365)] {
            collect(
                "changes", AppModel.changeMap(tree: tree, window: window, rules: model.rules, facts: model.facts).rows(tree: tree, rules: model.rules)
            )
        }
        model.setLens(.map)
        collect("suggestions", model.shownRows)
        collect(
            "boxes", Sections.build(from: Wins.build(tree: tree, rules: model.rules, running: [], facts: model.facts), tree: tree, facts: model.facts)
        )
        collect("copy list", model.listText()?.text ?? "")
        for node in things {
            let thing = NamedThing(node)
            collect("name", [model.displayName(node), model.realName(of: node), tree.friendlyPath(node)])
            collect("menu", model.actions(for: thing).map(\.title))
            collect("delete menu", model.deleteActions(for: thing).map(\.title))
            collect("story", Accounting.story(node, in: tree))
            collect("middle of the ring", Accounting.hoverLine(node, bytes: tree.totals[Int(node)], in: tree) ?? "")
            collect("facts", LookContents.facts(of: node, in: tree) as Any)
            model.copyPath(of: thing)
            collect("tip", model.tip ?? "")
        }
        for query in ["a", "e", "s"] {
            for found in Search.run(query, in: tree).prefix(200) {
                collect("search", [tree.name(found), tree.path(tree.nodes[Int(found)].parent).map(DiskTree.friendly) ?? ""])
            }
        }
        collect("disks", model.volumes.map(\.shownName))

        var seen = Set<String>()
        var hits = 0
        for line in lines {
            let words = line.text.lowercased().split { " /,:;()\"“”›…·\n".contains($0) }.map {
                $0.hasSuffix(".") ? String($0.dropLast()) : String($0)
            }
            for start in words.indices {
                var run = ""
                for end in start..<min(start + 8, words.count) {
                    run += (end == start ? "" : " ") + words[end]
                    if real.contains(run), seen.insert(run + "|" + line.place).inserted {
                        hits += 1
                        print("leak? \"\(run)\" in \(line.place): \(line.text)")
                    }
                }
            }
        }
        print("leaks: looked at \(lines.count) lines against \(real.count) real names, \(hits) to read")
    }

    /// With the display off for a moment, as on a locked screen, a picture can fail. It works when it's back on. True when
    /// the picture is there.
    @discardableResult
    private static func picture(of window: NSWindow, to path: String) async -> Bool {
        guard mayTakePictures else { return false }
        for _ in 0..<8 where !FileManager.default.fileExists(atPath: path) {
            photograph(window: window.windowNumber, to: path).waitUntilExit()
            if !FileManager.default.fileExists(atPath: path) { try? await Task.sleep(for: .seconds(1)) }
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Pictures come from the window server, so only when Headroom may already record the screen. Asking would put
    /// macOS's question on the screen of whoever is at the Mac, which a check must never do. A copy started with `open` is
    /// an app of its own to macOS, without that permission, so its checks say so and go on without pictures.
    private static var mayTakePictures: Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        print("no picture: Headroom isn't allowed to record the screen, and a check never asks")
        return false
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 && !($0 is NSPanel) }
    }

    // MARK: What the steps share

    /// A point given from a window's top left, as AppKit counts it: from the bottom left.
    private static func flipped(_ x: Double, _ y: Double, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - y)
    }

    /// A mouse event for a window, made now, at a point counted AppKit's way.
    private static func mouseEvent(
        _ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, clicks: Int = 0,
        pressure: Float = 0, flags: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: pressure)
    }

    /// A key pressed in a window, made now.
    private static func keyDown(_ code: UInt16, typing characters: String, flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)
    }

    /// The pointer moved here, handed to the ring's view alone.
    private static func moveOnMap(to location: NSPoint, in window: NSWindow, _ model: AppModel) {
        if let event = mouseEvent(.mouseMoved, at: location, in: window) { model.mapView?.mouseMoved(with: event) }
    }

    /// The kind of view a click at this point would reach, cut to `longest` letters.
    private static func viewKind(at location: NSPoint, in window: NSWindow, longest: Int = .max) -> String {
        window.contentView?.superview?.hitTest(location).map { String(String(describing: type(of: $0)).prefix(longest)) } ?? "nothing"
    }

    /// A step's number of seconds, or nil after a line saying why it's skipped: it has to be a number, and no more than a day
    /// either way. That's longer than any check needs, and short enough for a `Duration`, which traps on more, or on NaN.
    private static func seconds(_ text: String, for step: String) -> Double? {
        guard let value = Double(text), value.isFinite, abs(value) <= 86_400 else {
            print("\(step) \(text): not a number of seconds up to a day, so skipped")
            return nil
        }
        return value
    }

    /// How many clicks a step asked for, from 1 to 10, saying so when it asked for more. Any more would only hold the run up.
    private static func clickCount(_ asked: Int, for step: String) -> Int {
        if asked > 10 { print("\(step): \(asked) clicks is too many, so 10") }
        return min(max(asked, 1), 10)
    }

    /// The window size a step asked for, at least the smallest the window can be, or nil after a line saying why not. A
    /// window smaller than that is no longer found as the main window, so every step after it would quietly do nothing,
    /// and one that isn't a number takes AppKit down.
    private static func windowSize(_ width: Double, _ height: Double, of window: NSWindow, for step: String) -> CGSize? {
        guard width.isFinite, height.isFinite else { print("\(step): \(width) × \(height) isn't a size"); return nil }
        let least = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let size = CGSize(width: max(width, least.width, window.minSize.width), height: max(height, least.height, window.minSize.height))
        if size.width != width || size.height != height {
            print(String(format: "%@: %.0f × %.0f is too small, so %.0f × %.0f", step, width, height, size.width, size.height))
        }
        return size
    }

    /// The two numbers of `x y`, or nil when there aren't two.
    private static func point(in argument: String) -> CGPoint? {
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        return numbers.count == 2 ? CGPoint(x: numbers[0], y: numbers[1]) : nil
    }

    /// The point at this angle, clockwise from 12 o'clock, and this far from the ring's centre, in points from the window's
    /// top left.
    private static func onRing(angle: Double, radius: Double, _ model: AppModel) -> CGPoint {
        CGPoint(x: model.ring.center.x + sin(angle) * radius, y: model.ring.center.y - cos(angle) * radius)
    }

    /// The middle of a piece of the ring, in points from the window's top left.
    private static func middle(of piece: Piece, _ model: AppModel) -> CGPoint {
        onRing(angle: Double(piece.a0 + piece.a1) / 2, radius: Double(piece.r0 + piece.r1) / 2 * model.ring.radius, model)
    }

    /// The biggest folder on the ring, leaving out "smaller items".
    private static func biggestPiece(_ model: AppModel) -> Piece? {
        model.engine.layout.pieces.filter { !$0.isSmaller && $0.role == .container }.max { $0.size < $1.size }
    }

    /// Chooses an item from the app menu, as a click on it does. False when there's no such item.
    private static func chooseFromAppMenu(_ title: String) -> Bool {
        guard let menu = NSApp.mainMenu?.items.first?.submenu, let at = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: at)
        return true
    }

    /// Runs `send`, and hands `opened` the first menu that opens while it does. False when none did.
    private static func firstMenu(openedBy send: () -> Void, then opened: @escaping (NSMenu) -> Void) -> Bool {
        var found = false
        let watch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, !found else { return }
            found = true
            opened(menu)
        }
        send()
        NotificationCenter.default.removeObserver(watch)
        return found
    }

    /// Starts macOS's own tool for photographing one window, with no sound and no shadow.
    nonisolated private static func photograph(window number: Int, to path: String) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(number), path]
        try? task.run()
        return task
    }

    nonisolated private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    nonisolated private static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    /// How long `body` takes, in milliseconds: the average over this many rounds.
    private static func averageMilliseconds(_ rounds: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        for _ in 0..<rounds { body() }
        return milliseconds(since: start) / Double(rounds)
    }

    /// What a refresh costs and whether it comes out as a full read does. Between the two, the disk carries on changing, so
    /// what differs is listed where it starts, to tell a busy folder from a mistake.
    nonisolated private static func compareRefresh(
        of tree: DiskTree, volume: VolumeFacts, journal: ChangeJournal.Watcher, rules: RuleBook,
        fullAccess: Bool
    ) -> String {
        guard let facts = VolumeFacts.read(path: volume.mountPath) else { return "refreshcheck: no disk" }
        var out: [String] = []
        let asked = DispatchTime.now()
        guard let place = tree.journal, let taken = journal.take(from: place) else { return "refreshcheck: the journal lost track" }
        let askedFor = seconds(since: asked)
        let refresh = DiskScan(facts: facts, rules: rules, fullAccess: fullAccess)
        guard refresh.refresh(from: tree, changes: taken.changes, place: taken.next) else { return "refreshcheck: the refresh said no" }
        var folders = 0
        for i in 0..<tree.count where tree.nodes[i].has(NodeFlag.directory) { folders += 1 }
        let started = DispatchTime.now()
        refresh.run(mode: .full)
        out.append(
            String(
                format:
                    "refresh %.2f s, after asking the journal for %.3f s: %d folders changed, %d with everything under; read %d of %d folders again, surprised: %@",
                seconds(since: started), askedFor, taken.changes.folders.count, taken.changes.everythingUnder.count, refresh.foldersToRead, folders,
                refresh.surprised ? "yes" : "no"))
        out.append("  read again: " + refresh.whyRead)
        guard !refresh.surprised else { return out.joined(separator: "\n") }
        let a = refresh.tree
        let saveStart = DispatchTime.now()
        TreeCache.save(a, for: facts, rules: rules)
        let saved = seconds(since: saveStart)
        let loadStart = DispatchTime.now()
        let loaded = TreeCache.load(for: facts, rules: rules)
        let size = (try? FileManager.default.attributesOfItem(atPath: TreeCache.url(facts.name).path)[.size] as? Int) ?? 0
        out.append(
            String(
                format: "saved map %.1f MB, saved in %.2f s, read back in %.2f s%@", Double(size) / 1e6, saved, seconds(since: loadStart),
                loaded == nil ? ", but it didn't read back" : ""))
        let full = DiskScan(facts: facts, rules: rules, fullAccess: fullAccess)
        let fullStart = DispatchTime.now()
        full.run(mode: .full)
        out.append(String(format: "full read %.2f s", seconds(since: fullStart)))
        let b = full.tree

        // The same path has the same key in both.
        let keysA = vmAlloc(UInt64.self, max(a.count, 1)), keysB = vmAlloc(UInt64.self, max(b.count, 1))
        defer { vmFree(keysA, max(a.count, 1)); vmFree(keysB, max(b.count, 1)) }
        History.fillKeys(tree: a, into: keysA)
        History.fillKeys(tree: b, into: keysB)
        var inB = [UInt64: UInt32](minimumCapacity: b.count)
        for i in 0..<b.count { inB[keysB[i]] = UInt32(i) }
        let differs = Mapped<Bool>(count: a.count)
        var differing = 0, missing = 0
        for i in 0..<a.count {
            guard let j = inB[keysA[i]] else { differs[i] = true; missing += 1; continue }
            if a.totals[i] != b.totals[Int(j)] || a.totalFiles[i] != b.totalFiles[Int(j)] { differs[i] = true; differing += 1 }
        }
        var sources: [(id: UInt32, change: Int64)] = []
        for i in 0..<a.count where differs[i] {
            var inside = false
            var c = a.nodes[i].firstChild
            while c != 0 { if differs[Int(c)] { inside = true; break }; c = a.nodes[Int(c)].nextSibling }
            if inside { continue }
            let other = inB[keysA[i]].map { Int64(b.totals[Int($0)]) } ?? 0
            sources.append((UInt32(i), Int64(a.totals[i]) - other))
        }
        let total = Int64(a.totals[0]) - Int64(b.totals[0])
        out.append(
            "differences: \(differing) nodes add up differently, \(missing) only in the refresh, \(b.count - (a.count - missing)) only in the read; whole disk \(total) bytes; \(sources.count) places they start"
        )
        for source in sources.sorted(by: { abs($0.change) > abs($1.change) }).prefix(12) {
            out.append(
                "  \(source.change > 0 ? "+" : "")\(formatBytes(UInt64(abs(source.change)))) \(source.change < 0 ? "less" : "more") in the refresh: \(a.friendlyPath(source.id))"
            )
        }
        let rowA = a.statRow(0), rowB = b.statRow(0)
        out.append("whole disk by kind and date, refresh: \((0..<DiskTree.statStride).map { String(rowA[$0]) }.joined(separator: " "))")
        out.append("whole disk by kind and date, read:    \((0..<DiskTree.statStride).map { String(rowB[$0]) }.joined(separator: " "))")
        out.append("links \(a.links.count) and \(a.singleLinks.count) single in the refresh, \(b.links.count) and \(b.singleLinks.count) in the read")
        return out.joined(separator: "\n")
    }

    private static func report(_ model: AppModel) {
        guard let tree = model.tree else {
            print(
                "no tree: disk \(model.volume?.mountPath ?? "none") of \(model.volumes.count), full access \(model.hasFullAccess), scanning \(model.isScanning)"
            )
            return
        }
        print(String(format: "scan %.2fs, %d files, %d nodes, %d link records", tree.scanSeconds, tree.totalFiles[0], tree.count, tree.links.count))
        if tree.isPartial { print("still reading \(formatBytes(tree.totals[Int(tree.hidden)])), \(model.scanFiles) files so far") }
        print(
            String(
                format: "pieces %d, labels %d, last scan loaded in %.1f ms", model.engine.layout.pieces.count, model.chart.labels.count,
                model.cacheLoadMilliseconds))
        print(
            "last scan \(model.lastScanNote); read in full \(Int(Date().timeIntervalSince(tree.fullReadAt))) s ago, journal \(tree.journal == nil ? "none" : "kept"), whole \(tree.isWhole)"
        )
        print(
            "focus \(model.displayName(model.focus)), planned \(model.plan.count), you'd get back \(formatBytes(model.planNumbers.total)), message: \(model.message ?? "none")"
        )
        print("plan:")
        for item in model.plan.items {
            let check = model.checks[item.id]
            print(
                "  \(item.title) — \(formatBytes(model.planNumbers.byItem[item.id] ?? 0)) step=\(item.step) paths=\(item.paths.count) excluded=\(item.excluded.count) problems=\(check?.problems.map(\.text) ?? [])"
            )
        }
        if let after = model.afterClean {
            print("after clean: \(formatBytes(after.bytes)) in the Trash, \(after.things.count) things, failed \(after.failed), state \(after.state)")
        }
        print("disks: \(model.otherDisks(for: "/").map { "\($0.name) \($0.isPluggedIn ? "plugged in" : "away")" })")
        print(
            "kept: \(model.plan.kept.map(\.title))  other copies: \(model.otherCopies.map { "\($0.key) → \($0.value.title) \(formatBytes($0.value.bytes))" })"
        )
        var denied = 0
        for i in 0..<tree.count where tree.nodes[i].has(NodeFlag.denied) { denied += 1 }
        print(
            "folders that wouldn't open: \(denied), of \(tree.count) nodes, \(tree.totalFiles[0]) files, hidden \(formatBytes(tree.totals[Int(tree.hidden)]))"
        )
        print(
            "boxes: "
                + model.boxes.map { "\($0.title) \(formatBytes($0.bytes)) [\($0.rows.count)] \(model.rowStates[$0.id] ?? .none)" }.joined(
                    separator: " | "))
        print("shown \(model.shownRows.count) of \(model.suggestions.everything.count) suggestions:")
        for row in model.shownRows {
            print(
                "  [\(row.tier.title)\(row.isQuick ? " quick" : "")\(row.inUse.map { " in use: \($0)" } ?? "")] \(row.title) — \(formatBytes(row.bytes)) (paper \(formatBytes(row.paperBytes))) \(row.subtitle) action=\(row.action) tick=\(model.rowStates[row.id] ?? .none)\(row.otherCopies.isEmpty ? "" : " copies: \(row.otherCopiesTitle ?? "") \(row.otherCopiesNote ?? "")")"
            )
            for part in row.parts {
                print("      · \(part.title) — \(formatBytes(part.bytes)) \(part.subtitle)\(part.alsoTitle.map { " | " + $0 } ?? "")")
            }
        }
        print("changes (\(model.changeCaption)):")
        for row in model.changeRows.prefix(12) { print("  +\(formatBytes(UInt64(max(row.delta, 0)))) \(row.title)  \(row.subtitle)") }
        for row in model.changeShrank.prefix(12) { print("  -\(formatBytes(UInt64(max(-row.delta, 0)))) \(row.title)  \(row.subtitle)") }
    }
}

/// How busy the main thread is, and the longest it has been away: what you'd feel as a hitch.
private final class MainThreadMeter {
    private var observer: CFRunLoopObserver?
    private var wokeAt = 0.0
    private(set) var busy = 0.0, longest = 0.0, over16 = 0, over50 = 0
    /// How many times the main thread woke for under 1 ms, 1 to 2, 2 to 4, 4 to 8, 8 to 16, and longer, and the time in each.
    private(set) var wakes = [Int](repeating: 0, count: 6), wakeTime = [Double](repeating: 0, count: 6)
    /// When each stall over 16 ms began, in ms from the start, and how long it was.
    private(set) var stalls: [(at: Double, ms: Double)] = []
    private let began = CFAbsoluteTimeGetCurrent()
    private let cpuAtStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)

    init() {
        observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, activity in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                self.wokeAt = now
            } else if self.wokeAt > 0 {
                let ms = (now - self.wokeAt) * 1000
                self.busy += ms
                self.longest = max(self.longest, ms)
                let bucket = ms < 1 ? 0 : ms < 2 ? 1 : ms < 4 ? 2 : ms < 8 ? 3 : ms < 16 ? 4 : 5
                self.wakes[bucket] += 1
                self.wakeTime[bucket] += ms
                if ms > 16 {
                    self.over16 += 1
                    self.stalls.append(((self.wokeAt - self.began) * 1000, ms))
                }
                if ms > 50 { self.over50 += 1 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func report(_ label: String) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        let total = (CFAbsoluteTimeGetCurrent() - began) * 1000
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuAtStart) / 1e6
        print(
            String(
                format: "meter %-30@ cpu %5.1f%%, main %4.1f%%, longest %5.1f ms, over 16 ms %3d, over 50 ms %3d", label as NSString,
                cpu / total * 100, busy / total * 100, longest, over16, over50))
        let names = ["under 1 ms", "1 to 2", "2 to 4", "4 to 8", "8 to 16", "over 16"]
        print("  wakes: " + zip(names, zip(wakes, wakeTime)).map { String(format: "%@ %d (%.0f ms)", $0, $1.0, $1.1) }.joined(separator: ", "))
        if !stalls.isEmpty { print("  stalls at " + stalls.map { String(format: "%.0f ms for %.0f", $0.at, $0.ms) }.joined(separator: ", ")) }
    }
}
