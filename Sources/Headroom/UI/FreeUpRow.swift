import AppKit
import SwiftUI

/// One thing: a series, an app, a folder. Inside an open box it's a small row. Given a `scale`, it's a box of its own.
struct ThingRow: View {
    let model: AppModel
    let row: WinRow
    let color: Lab
    var box: Box? = nil
    var scale: UInt64? = nil
    @State private var isHovered = false

    private var isLarge: Bool { scale != nil }
    private var isOpen: Bool { model.expandedRow == row.id }
    private var isLit: Bool { isHovered || model.hotRow == row.id || (box.map { model.cursorRow == $0.id } ?? false) }

    var body: some View {
        let state = model.rowStates[row.id] ?? .none
        let tint = color.swiftUI
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: isLarge ? 10 : 8) {
                leading(state, tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(spacing: 6) {
                            if let app = row.appPath { AppIcon(path: app) }
                            Text(row.title)
                                .font(.system(size: isLarge ? 13.5 : 12.5, weight: isLarge ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(0.94))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 2)
                        number(state)
                    }
                    HStack(spacing: 6) {
                        line
                        Spacer(minLength: 0)
                        if isHovered || isOpen { actions(state) }
                        if hasContents { chevron }
                    }
                    .frame(minHeight: 15)
                    if let scale, let box {
                        BoxBar(model: model, box: box, scale: scale, height: 5, isLit: isLit, hovered: { _ in })
                            .padding(.top, 1)
                    }
                }
            }
            if state != .none, let title = row.otherCopiesTitle { otherCopyRow(title, tint) }
            if state != .none, let title = row.alsoTitle { alsoRow(title, tint) }
            extra
            if isOpen { details(tint) }
        }
        .padding(.leading, isLarge ? Kit.rowInset : 8)
        .padding(.trailing, isLarge ? Kit.rowInset : 8)
        .padding(.vertical, isLarge ? 7 : 6)
        .background(RoundedRectangle(cornerRadius: isLarge ? Kit.cardRadius : Kit.rowRadius + 1, style: .continuous).fill(state.rowFill(tint, isLit: isLit, small: !isLarge)))
        .contentShape(Rectangle())
        .help(row.detail)
        .onHover { inside in
            isHovered = inside
            if let box {
                if inside { model.point(at: box, row: row) } else { model.point(at: nil) }
            } else if inside {
                model.highlight(nodes: row.nodes)
            } else {
                model.highlight(nodes: [])
            }
        }
        .onTapGesture {
            if row.isPlannable { Motion.animate(.snappy(duration: 0.18)) { model.toggle(row) } }
        }
        .named(thing, in: model)
        .animation(.easeOut(duration: 0.14), value: isLit)
    }

    private var thing: NamedThing {
        let model = model, row = row
        return NamedThing(nodes: row.nodes, title: row.title, toggle: row.isPlannable ? { model.toggle(row) } : nil)
    }

    @ViewBuilder
    private var line: some View {
        let font = Font.system(size: isLarge ? 11 : 10.5)
        if case .move(let folder)? = model.plan.item(row.id)?.step {
            // Moves are blue in this app, as Backup's are: they keep the files, somewhere else.
            Text("Moves to \(Self.shortPlace(folder))")
                .font(font.weight(.medium))
                .foregroundStyle(Kit.blue)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(DiskTree.friendly(folder))
        } else if let note = row.inUse ?? row.otherCopiesCaution.map({ _ in "May still be seeding" }) {
            Text(note)
                .font(font.weight(.medium))
                .foregroundStyle(Kit.amber.opacity(0.95))
                .lineLimit(1)
        } else if !row.subtitle.isEmpty {
            Text(row.subtitle)
                .font(font)
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(isOpen ? nil : 1)
                .fixedSize(horizontal: false, vertical: isOpen)
        }
    }

    /// A folder by its last name or two, the way you'd say where something went: `Backup`, `Archive/Films`.
    static func shortPlace(_ folder: String) -> String {
        var parts = DiskTree.friendly(folder).split(separator: "/").map(String.init)
        if parts.first == "Volumes", parts.count > 1 { parts.removeFirst() }
        if parts.first == "~", parts.count > 1 { parts.removeFirst() }
        return parts.isEmpty ? DiskTree.friendly(folder) : parts.suffix(2).joined(separator: "/")
    }

    /// See it for yourself, send it somewhere else instead of the Trash, or keep it.
    @ViewBuilder
    private func actions(_ state: TickState) -> some View {
        HStack(spacing: 4) {
            // A move is one thing going to one place.
            let disks = row.action == .trash && row.nodes.count == 1 ? (model.tree?.path(row.nodes[0]).map(model.otherDisks) ?? []) : []
            if model.plan.item(row.id)?.isMove == true {
                small("Trash instead") { model.setStep(.trash, for: row.id) }
            } else if disks.count == 1, let disk = disks.first {
                small("Move to \(disk.name)") { model.planMove(row, to: disk) }
                    .help(disk.isPluggedIn ? "Copy to \(disk.name), verify, then move the original to the Trash" : "Connect \(disk.name) before cleaning")
            } else if disks.count > 1 {
                Menu {
                    ForEach(disks, id: \.self) { disk in
                        Button(disk.isPluggedIn ? "Move to \(disk.name)" : "Move to \(disk.name) (not connected)") { model.planMove(row, to: disk) }
                    }
                } label: {
                    PillLabel(text: "Move")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if row.isPlannable { small("Keep") { model.keep(row) }.help("Don't suggest this again") }
        }
    }

    /// Whether there's anything to open: what it holds, or where it is.
    private var hasContents: Bool { !row.nodes.isEmpty || !row.extraPaths.isEmpty }

    /// Always there on a row that opens, so you can see that it does. The tick is the row; this is what's inside it.
    private var chevron: some View {
        Button {
            Motion.animate(.snappy(duration: 0.22)) { model.toggleExpanded(row) }
        } label: {
            DisclosureChevron(isOpen: isOpen, size: 9.5)
                .foregroundStyle(.white.opacity(isHovered || isOpen ? 0.7 : 0.28))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide contents" : "Show contents")
    }

    private func small(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(text) {
            Motion.animate(.snappy(duration: 0.2)) { action() }
        }
        .buttonStyle(.pill(nil, size: .small))
    }

    private func number(_ state: TickState) -> some View {
        let font = Font.system(size: isLarge ? 13.5 : 12, weight: isLarge ? .semibold : .medium).monospacedDigit()
        return VStack(alignment: .trailing, spacing: 0) {
            // A selected series whose files are also held somewhere else gives nothing back. Better to say so right here.
            if state != .none, !row.otherCopies.isEmpty, model.plan.covers(row.otherCopiesPath ?? "") == false {
                Text("\(row.bytes < 1_000_000 ? "0 B" : formatBytes(row.bytes)) of \(formatBytes(row.paperBytes))")
                    .font(font)
                    .foregroundStyle(Kit.amber)
            } else {
                Text(formatBytes(row.gain))
                    .font(font)
                    .foregroundStyle(.white.opacity(isLarge ? 0.92 : 0.82))
                if row.otherCopies.isEmpty, row.paperBytes > row.bytes, Double(row.bytes) < Double(row.paperBytes) * 0.9 {
                    Text("of \(formatBytes(row.paperBytes))")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(Kit.amber.opacity(0.85))
                }
            }
        }
    }

    @ViewBuilder
    private func leading(_ state: TickState, _ tint: Color) -> some View {
        switch row.action {
        case .trash, .uninstall, .emptyTrash: TickMark(state: state, color: tint, size: isLarge ? 20 : 16, isLit: isLit)
        case .restart: symbol("arrow.clockwise.circle")
        case .softwareUpdate: symbol("arrow.down.circle")
        case .openApp: symbol("arrow.up.forward.app")
        case .command: symbol("terminal")
        case .info: symbol("info.circle")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 16, height: 16)
    }

    /// The other copy has its own tick, because taking it has its own cost: it stops sharing.
    private func otherCopyRow(_ title: String, _ tint: Color) -> some View {
        let on = model.plan.covers(row.otherCopiesPath ?? "")
        return choice(title, note: row.otherCopiesNote, isOn: on, tint: tint) { model.toggleOtherCopies(of: row) }
    }

    private func alsoRow(_ title: String, _ tint: Color) -> some View {
        choice(title, note: row.alsoNote, isOn: model.plan.item(PlanItem.dataID(of: row.id)) != nil, tint: tint) { model.toggleAlso(of: row) }
    }

    private func choice(_ title: String, note: String?, isOn: Bool, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button {
            Motion.animate(.snappy(duration: 0.2)) { action() }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                TickMark(state: isOn ? .all : .none, color: tint, size: 14)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                    if let note {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, isLarge ? 30 : 24)
    }

    @ViewBuilder
    private var extra: some View {
        switch row.action {
        case .softwareUpdate:
            Button("Open Software Update") { model.openSoftwareUpdate() }
                .buttonStyle(.pill)
                .padding(.leading, 24)
        case .openApp:
            if let id = row.bundleID {
                Button("Open \(row.openAppName ?? row.title)") { model.openApp(bundleID: id) }
                    .buttonStyle(.pill)
                    .padding(.leading, 24)
            }
        case .command:
            if let command = row.command { CommandChip(command: command).padding(.leading, 24) }
        default:
            EmptyView()
        }
    }

    private func details(_ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            if let command = row.command, row.action != .command {
                HStack(spacing: 5) {
                    Text("Or run:")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                    CommandChip(command: command)
                }
            }
            if row.nodes.count == 1 || row.previewPath != nil, let node = row.nodes.first {
                Button("Show in Finder") { model.reveal(node) }
                    .buttonStyle(.pill)
            }
            InnerList(model: model, nodes: model.innerNodes(of: row), tint: tint)
            if !row.extraPaths.isEmpty { LooseList(model: model, row: row, tint: tint) }
        }
        .padding(.leading, isLarge ? 30 : 24)
        .padding(.top, 2)
    }
}

private struct CommandChip: View {
    let command: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } label: {
            HStack(spacing: 5) {
                Text(command)
                    .font(.system(size: 10.5, design: .monospaced))
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Kit.rowRadius - 2, style: .continuous).fill(.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help("Copy command")
    }
}
