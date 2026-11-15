import AppKit
import SwiftUI

/// What's worth doing in the picture you're looking at. The rest is one click away.
struct WorthDoing: View {
    let model: AppModel

    var body: some View {
        let rows = model.shownRows.filter(\.isPlannable).sorted { $0.gain > $1.gain }.prefix(3)
        let insight = model.insightLine()
        if insight != nil || !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let insight {
                    Text(insight)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !rows.isEmpty, model.focus != 0 {
                    SectionHeading(text: "Suggestions")
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                    VStack(spacing: 0) {
                        ForEach(Array(rows)) { row in
                            ThingRow(model: model, row: row, color: model.rowColours[row.id] ?? Palette.Box.other)
                        }
                    }
                    .padding(.horizontal, -2)
                    Button {
                        Motion.animate(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(.freeUp) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text("Show all in Free Up")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.gain)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
            }
        }
    }
}
