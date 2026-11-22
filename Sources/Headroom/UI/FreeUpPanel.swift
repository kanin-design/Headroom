import AppKit
import SwiftUI

/// A short stack of boxes, what you'd miss least on top. Each box selects a whole section, and the ring wears the same colours:
/// one set of data, shown two ways.
struct FreeUpPanel: View {
    let model: AppModel

    var body: some View {
        let boxes = model.boxes
        // The shortlist's total isn't a suggestion, so it doesn't set the scale of the bars.
        let scale = max(boxes.filter { !$0.isShortlist }.map(\.bytes).max() ?? 1, 1)
        let others = model.shownRows.filter { !$0.isPlannable }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    FreeUpTopCard(model: model)
                    NeedsALook(model: model)
                    RecommendedButton(model: model)
                    ForEach(boxes) { box in
                        BoxView(model: model, box: box, scale: scale)
                            .id(box.id)
                    }
                    if boxes.isEmpty { emptyState }
                    if !others.isEmpty { TuckedAway(model: model, title: "Other actions", promise: "Done outside Headroom", rows: others).padding(.top, 8) }
                    keptLink
                }
                .padding(Kit.panelInset)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.never)
            .onChange(of: model.hotBox) { _, id in
                if let id { Motion.animate(.snappy(duration: 0.2)) { proxy.scrollTo(id) } }
            }
        }
    }

    private var emptyState: some View {
        // With nothing read, there's no knowing what could go.
        EmptyNote(title: !model.hasFullAccess ? "Needs Full Disk Access" : model.focus == 0 ? "No suggestions" : "No suggestions here",
                  detail: model.hasFullAccess ? "To select an item, point to it on the map and press Space." : nil)
    }

    @ViewBuilder
    private var keptLink: some View {
        if !model.plan.kept.isEmpty {
            Fold(title: "Kept", count: "\(model.plan.kept.count)") {
                ForEach(model.plan.kept) { kept in
                    KeptLine(title: kept.title) { model.stopKeeping(kept.id) }
                }
            }
            .padding(.top, 8)
        }
    }
}

/// What the last look found, right where you'd see it before pressing Clean, with what you can do about it.
/// One click for what's safe without a second thought: caches not in use, and junk. Nothing is ticked until it's pressed, and
/// pointing at it shows what it would take, in the list and on the ring.
private struct RecommendedButton: View {
    let model: AppModel
    @State private var isHovered = false

    var body: some View {
        let rows = model.recommendedLeft
        if !rows.isEmpty, !model.isCleaning {
            Button {
                Motion.animate(.snappy(duration: 0.2)) { model.selectRecommended() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Select recommended")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(formatBytes(rows.reduce(UInt64(0)) { $0 &+ $1.aTickFrees }))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Kit.green)
                .padding(.horizontal, Kit.rowInset)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Kit.cardRadius, style: .continuous).fill(Kit.green.opacity(isHovered ? 0.18 : 0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                isHovered = inside
                model.pointAtRecommended(inside)
            }
            .help("Caches not in use, and junk")
            .padding(.bottom, 6)
        }
    }
}

/// What can't be ticked, folded away until it's wanted.
private struct TuckedAway: View {
    let model: AppModel
    let title: String
    let promise: String
    let rows: [WinRow]

    var body: some View {
        Fold(title: title, count: rows.count == 1 ? "1 item" : "\(rows.count) items",
             trailing: formatBytes(rows.reduce(UInt64(0)) { $0 &+ $1.gain }), help: promise) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    ThingRow(model: model, row: row, color: Palette.Box.other)
                }
            }
        }
    }
}
