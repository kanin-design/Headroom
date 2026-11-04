import Foundation

let args = CommandLine.arguments
if args.contains("--bench") {
    // How fast the picture gets right: when each share of the bytes was known, what the quiet part cost, and the total.
    let env = ProcessInfo.processInfo.environment
    let rules = RuleBook(homePath: NSHomeDirectory())
    let scan = DiskScan(facts: VolumeFacts.read(path: env["HR_PATH"] ?? "/")!, rules: rules, fullAccess: false, askPerFolder: true)
    final class Samples: @unchecked Sendable { var list: [(Double, UInt64)] = []; var stop = false }
    let samples = Samples()
    let start = DispatchTime.now()
    func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 }
    func cpu() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    final class Mark: @unchecked Sendable { var cpuAtQuiet = 0.0; var timeAtQuiet = 0.0 }
    let mark = Mark()
    Thread.detachNewThread {
        while !samples.stop {
            Thread.sleep(forTimeInterval: 0.04)
            samples.list.append((seconds(), scan.knownBytes()))
            if mark.timeAtQuiet == 0, scan.scanner.isQuiet { mark.timeAtQuiet = seconds(); mark.cpuAtQuiet = cpu() }
        }
    }
    let mode: ScanMode = env["HR_MODE"] == "full" ? .full : (env["HR_MODE"] == "quiet" ? .quiet : .firstLook)
    scan.run(mode: mode, threads: env["HR_THREADS"].flatMap(Int.init) ?? max(8, ProcessInfo.processInfo.activeProcessorCount))
    samples.stop = true
    let t = scan.tree
    let final = t.totals[0] &- t.totals[Int(t.free)] &- t.totals[Int(t.hidden)]
    var scanned: UInt64 = 0
    for i in 0..<t.count where !t.nodes[i].has(NodeFlag.synthetic) { scanned &+= t.nodes[i].bytes }
    var line = ""
    for m in [0.5, 0.8, 0.9, 0.95, 0.99] {
        let hit = samples.list.first { Double($0.1) >= m * Double(scanned) }
        line += String(format: " %2.0f%%:%6.2fs", m * 100, hit?.0 ?? -1)
    }
    let after1 = samples.list.first { $0.0 >= 1 }.map { Double($0.1) / Double(max(scanned, 1)) * 100 } ?? 0
    let total = t.scanSeconds
    let quietCPU = mark.timeAtQuiet > 0 ? (cpu() - mark.cpuAtQuiet) / max(total - mark.timeAtQuiet, 0.01) : 0
    print(String(format: "%@  after 1 s: %.0f%%  quiet from %.2f s, using %.1f cores  total %.2f s  %u files  %d nodes  %@ on the ring", line, after1, mark.timeAtQuiet, quietCPU, total, t.totalFiles[0], t.count, formatBytes(final)))
    if env["HR_PATH"] != nil {
        for c in t.children(0) {
            print("  \(t.name(c))  \(formatBytes(t.totals[Int(c)]))")
            for g in t.children(c).prefix(8) { print("    \(t.name(g))  \(formatBytes(t.totals[Int(g)]))\(t.nodes[Int(g)].has(NodeFlag.denied) ? "  denied" : "")") }
        }
    }
    exit(0)
}
if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
    IconMaker.make(to: args[i + 1])
    exit(0)
}
HeadroomApp.main()
