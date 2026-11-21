import AppKit
import SwiftUI

/// A sunburst chart of a tree: the ring, names on and beside it, a centre in the middle, pointing to light a branch, a
/// click to zoom into it, and a click in the middle (or Esc) to zoom back out.
///
/// ```swift
/// Sunburst(tree, name: { tree.name(of: $0) })
/// ```
///
/// To drive it from code, keep a `SunburstChart` and show that: `Sunburst(chart)`. A chart is shown in one view at a time,
/// so give each window its own chart. The centre is a slot: by default the kit's readout, or anything of the app's own,
/// given what the chart would say and the room the centre has.
public struct Sunburst<Tree: SunburstTree, Centre: View>: View {
    private let given: SunburstChart<Tree>?
    private let make: (@MainActor () -> SunburstChart<Tree>)?
    private let centre: (SunburstReadout, CGFloat) -> Centre
    /// A chart made by this view, made once: SwiftUI makes a view's value again on every change around it, and a chart
    /// isn't cheap to make.
    @State private var made = MadeOnce<SunburstChart<Tree>>()

    /// A chart you keep, to drive from code, with a centre of your own: `centre` is given what the chart would say there and
    /// the centre's diameter.
    public init(_ chart: SunburstChart<Tree>, @ViewBuilder centre: @escaping (SunburstReadout, CGFloat) -> Centre) {
        given = chart
        make = nil
        self.centre = centre
    }

    public var body: some View {
        let chart = given ?? made.value { make!() }
        GeometryReader { geometry in
            let size = geometry.size
            let ring = Self.ring(in: size)
            ZStack(alignment: .topLeading) {
                SunburstCanvas(chart: chart)
                RingPlace(center: ring.center, radius: ring.radius, size: size, engine: chart.engine, view: { [chart] in chart.view })
                SunburstChartLabels(chart, width: size.width)
                centre(chart.readout, ring.radius * CGFloat(RingLayout.hole) * 2 * 0.86)
                    .position(ring.center)
                    .allowsHitTesting(false)
            }
            // A different chart is a different view: the ring's own view draws one engine for its whole life.
            .id(ObjectIdentifier(chart))
            .onAppear { chart.place(center: ring.center, radius: ring.radius, size: size) }
            .onChange(of: size) { _, new in
                let ring = Self.ring(in: new)
                chart.place(center: ring.center, radius: ring.radius, size: new)
            }
        }
        .background(Color(red: 0.02, green: 0.02, blue: 0.027))
    }

    /// Where the ring goes in a view of this size: in the middle, leaving room for names at the sides when there's width
    /// for them.
    static func ring(in size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let fits = max(min(size.width, size.height) / 2 - 30, 10)
        let besideNames = (size.width - 340) / 2
        let radius = min(fits, max(besideNames, fits * 0.78))
        return (CGPoint(x: size.width / 2, y: size.height / 2), radius)
    }
}

public extension Sunburst where Centre == SunburstReadoutView {
    /// A chart you keep, to drive from code, with the kit's centre.
    init(_ chart: SunburstChart<Tree>) {
        self.init(chart) { SunburstReadoutView($0, diameter: $1) }
    }

    /// A chart of this tree. `name` says what each node is called; sizes are written in bytes unless `sizeText` says
    /// otherwise, and `valueText`, if given, is written for a node in place of its size. `parts` are the chart's parts. The
    /// chart is made when the view first appears, from the tree it's given then. To show a tree that changes, keep a
    /// `SunburstChart` and set its `tree`.
    init(_ tree: Tree, name: @escaping (UInt32) -> String, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
         valueText: ((UInt32) -> String)? = nil, parts: SunburstParts = SunburstParts()) {
        given = nil
        make = { SunburstChart(tree: tree, name: name, sizeText: sizeText, valueText: valueText, parts: parts) }
        centre = { SunburstReadoutView($0, diameter: $1) }
    }

    /// A chart of an `ItemTree`, each piece named from its item.
    init<Item>(_ tree: ItemTree<Item>, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
               valueText: ((UInt32) -> String)? = nil, parts: SunburstParts = SunburstParts()) where Tree == ItemTree<Item> {
        given = nil
        make = { SunburstChart(tree: tree, sizeText: sizeText, valueText: valueText, parts: parts) }
        centre = { SunburstReadoutView($0, diameter: $1) }
    }
}

/// Holds something made the first time it's asked for. A class, so asking from `body` changes no state SwiftUI watches.
@MainActor
final class MadeOnce<Value> {
    private var made: Value?

    func value(_ make: () -> Value) -> Value {
        if let made { return made }
        let new = make()
        made = new
        return new
    }
}

/// The ring's own view, connected to a chart.
struct SunburstCanvas<Tree: SunburstTree>: NSViewRepresentable {
    let chart: SunburstChart<Tree>

    func makeNSView(context: Context) -> SunburstView {
        let view = SunburstView(engine: chart.engine)
        chart.attach(to: view)
        return view
    }

    func updateNSView(_ view: SunburstView, context: Context) {}
}
