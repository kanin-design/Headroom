import SunburstKit
import SwiftUI

/// A month's money: what's spent, and what isn't yet.
struct Cost {
    var name: String
    var cents = 0
    var parts: [Cost] = []
    /// Money not spent yet: room, drawn as a plain wedge that closes the circle.
    var isLeft = false
}

let month = Cost(name: "November", parts: [
    Cost(name: "Fixed", parts: [
        Cost(name: "Rent", cents: 120_000),
        Cost(name: "Bills", parts: [Cost(name: "Power", cents: 9_000), Cost(name: "Phone", cents: 3_500), Cost(name: "Internet", cents: 4_000)]),
        Cost(name: "Insurance", cents: 6_500),
    ]),
    Cost(name: "Variable", parts: [
        Cost(name: "Food", parts: [Cost(name: "Shop", cents: 32_000), Cost(name: "Out", cents: 18_000), Cost(name: "Coffee", cents: 4_200)]),
        Cost(name: "Travel", parts: [Cost(name: "Bus", cents: 6_000), Cost(name: "Train", cents: 9_500)]),
        Cost(name: "Fun", parts: [Cost(name: "Books", cents: 3_000), Cost(name: "Cinema", cents: 2_400), Cost(name: "Games", cents: 6_000)]),
    ]),
    Cost(name: "Not spent yet", cents: 52_000, isLeft: true),
])

@main
struct BudgetApp: App {
    @State private var chart = SunburstChart(
        tree: ItemTree(month, name: \.name, size: \.cents, children: \.parts, role: { $0.isLeft ? .room : nil }),
        sizeText: { "$\($0 / 100)" },
        // Fixed and variable in a thin band: what the month is made of. The costs in rings outside it.
        parts: SunburstParts(bands: [.init()], rings: .init(RingSizes(depth: 3))))

    var body: some Scene {
        WindowGroup("Budget") {
            Sunburst(chart)
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}
