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
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.never)
            .onChange(of: model.hotBox) { _, id in
                if let id { Motion.animate(.snappy(duration: 0.2)) { proxy.scrollTo(id) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            // With nothing read, there's no knowing what could go.
            Text(!model.hasFullAccess ? "Needs Full Disk Access" : model.focus == 0 ? "No suggestions" : "No suggestions here")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if model.hasFullAccess {
                Text("Click a piece of the ring to select it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var keptLink: some View {
        if !model.plan.kept.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.plan.kept) { kept in
                        HStack {
                            Text(kept.title)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                            Spacer()
                            Button("Suggest again") { model.stopKeeping(kept.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("\(model.plan.kept.count) kept")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
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
                .foregroundStyle(Palette.gain)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.gain.opacity(isHovered ? 0.18 : 0.1)))
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

/// A section that stays folded until you want it.
private struct TuckedAway: View {
    let model: AppModel
    let title: String
    let promise: String
    let rows: [WinRow]
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Motion.animate(.snappy(duration: 0.22)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DisclosureChevron(isOpen: isOpen, size: 9)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(rows.count == 1 ? "1 item" : "\(rows.count) items")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text(formatBytes(rows.reduce(UInt64(0)) { $0 &+ $1.gain }))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .help(promise)
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ThingRow(model: model, row: row, color: Palette.Box.other)
                    }
                }
            }
        }
    }
}
