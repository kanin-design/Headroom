import Foundation

let args = CommandLine.arguments
if args.contains("--bench") {
    let rules = RuleBook(homePath: NSHomeDirectory())
    let path = ProcessInfo.processInfo.environment["HR_PATH"] ?? "/"
    let scan = DiskScan(facts: VolumeFacts.read(path: path)!, rules: rules, fullAccess: false, askPerFolder: true)
    scan.run()
    let t = scan.tree
    print(String(format: "%.2fs  files %u  nodes %d  links %d  sum %@", t.scanSeconds, t.totalFiles[0], t.count, t.links.count, formatBytes(t.totals[0])))
    for c in t.children(0) {
        print("  \(t.name(c))  \(formatBytes(t.totals[Int(c)]))")
        if !t.nodes[Int(c)].has(NodeFlag.synthetic) || t.nodes[Int(c)].firstChild != 0 {
            for g in t.children(c).prefix(12) {
                let n = t.nodes[Int(g)]
                let links = t.aliasTotals[Int(g)] > 0 ? "  plus \(formatBytes(t.aliasTotals[Int(g)])) of links" : ""
                print("    \(t.name(g))  \(formatBytes(t.totals[Int(g)]))\(links)\(n.has(NodeFlag.denied) ? "  denied" : "")")
            }
        }
    }
    exit(0)
}
if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
    IconMaker.make(to: args[i + 1])
    exit(0)
}
HeadroomApp.main()
