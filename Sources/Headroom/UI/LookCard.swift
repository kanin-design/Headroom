import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

/// The card Space opens, on the side of the ring away from what it's about.
struct LookLayer: View {
    let model: AppModel
    let ring: RingGeometry
    let height: CGFloat

    var body: some View {
        if let look = model.look, let tree = model.tree {
            let isFolder = LookContents.isFolder(look.node, in: tree)
            let width = min(isFolder ? 400 : 620, ring.mapWidth - 32)
            LookCard(model: model, look: look, isFolder: isFolder, width: width, tallest: max(height - 130, 300))
                .position(x: look.onLeft ? 16 + width / 2 : ring.mapWidth - 16 - width / 2, y: height / 2 + 12)
                .transition(.scale(scale: 0.94, anchor: look.onLeft ? .trailing : .leading).combined(with: .opacity))
        }
    }
}

private struct LookCard: View {
    let model: AppModel
    let look: Look
    let isFolder: Bool
    let width: CGFloat
    let tallest: CGFloat

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        if let tree = model.tree {
            let _ = model.treeVersion
            VStack(alignment: .leading, spacing: 0) {
                header(tree)
                content
                    .background(FrameReader { model.lookContentFrame = $0 })
                footer(tree)
            }
            .frame(width: width)
            .background(FrameReader { model.lookCardFrame = $0 })
            .clipShape(shape)
            .glassEffect(.regular.tint(.black.opacity(0.42)), in: shape)
            .contentShape(shape)
            // A click on the card is for the card, not for what's behind it.
            .onTapGesture {}
        }
    }

    private func header(_ tree: DiskTree) -> some View {
        let node = look.node
        let thing = NamedThing(node)
        let tail = RingLayout.chainTail(tree: tree, node)
        let name = node == 0 ? model.realName(of: 0) : model.displayName(node) + (tail == node ? "" : " › " + tree.name(tail))
        let path = node == 0 || HiddenNames.isOn ? nil : tree.path(node).map(DiskTree.friendly)
        let bytes = tree.totals[Int(node)]
        return HStack(alignment: .top, spacing: 10) {
            if !look.back.isEmpty {
                Button {
                    model.lookBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back to what you were looking at")
            }
            if !HiddenNames.isOn, let real = model.realPath(of: node) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: real))
                    .resizable()
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                PanelTitle(title: name, subtitle: path, copyTitle: { model.copyName(of: thing) }, copySubtitle: { model.copyPath(of: thing) })
                if let facts = model.facts(of: node) {
                    Text(facts)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if node != 0, let links = Accounting.hoverLine(node, bytes: bytes, in: tree) {
                    Text(links)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.74, blue: 0.42))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    model.closeLook()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close. Space does the same")
                Text(tree.sizeText(node))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .named(thing, in: model)
    }

    @ViewBuilder
    private var content: some View {
        if isFolder {
            LookFolder(model: model, node: look.node, tallest: tallest - 180)
        } else if !HiddenNames.isOn, let path = model.realPath(of: look.node) {
            LookPreview(url: URL(fileURLWithPath: path))
                .frame(height: min(tallest - 180, width * 0.72))
                .background(.black.opacity(0.55))
        }
    }

    private func footer(_ tree: DiskTree) -> some View {
        let node = look.node
        let goesIn = model.lookGoesIn(node, in: tree)
        return HStack(spacing: 8) {
            Button {
                model.openLooked()
            } label: {
                Label(goesIn ? "Go Into" : "Open", systemImage: goesIn ? "arrow.right.circle" : "arrow.up.forward.app")
            }
            .buttonStyle(.glass)
            if node != 0 {
                Button {
                    model.reveal(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.glass)
            }
            Spacer(minLength: 4)
            if node != 0 {
                DeleteMenu(model: model, node: node)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// What's inside, biggest first, in the ring's colours. The size is already known, so it's there at once.
private struct LookFolder: View {
    let model: AppModel
    let node: UInt32
    let tallest: CGFloat

    private let rowHeight: CGFloat = 33.5
    private let pictureHeight: CGFloat = 78

    var body: some View {
        if let tree = model.tree {
            let rows = model.lookRows(of: node, in: tree)
            let top = Array(rows.prefix(300))
            let biggest = Double(max(top.first.map { tree.totals[Int($0)] } ?? 1, 1))
            let own = node == 0 ? 0 : tree.nodes[Int(RingLayout.chainTail(tree: tree, node))].bytes
            let pictures = HiddenNames.isOn ? [] : LookContents.media(in: node, tree: tree)
            let pictureRows = CGFloat((pictures.count + 2) / 3)
            let wanted = CGFloat(top.count + (own > 0 ? 1 : 0)) * rowHeight + pictureRows * (pictureHeight + 6) + 16
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if !pictures.isEmpty {
                            LookPictures(model: model, files: pictures, height: pictureHeight)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(Array(top.enumerated()), id: \.element) { index, row in
                                NodeRow(title: model.displayName(row), subtitle: nil, value: tree.sizeText(row),
                                        share: Double(tree.totals[Int(row)]) / biggest, color: model.listColor(row, in: tree),
                                        isLit: model.lookCursor == index,
                                        onHover: { inside in model.highlight(node: inside ? row : nil) },
                                        onTap: { model.showInLook(row) })
                                    .named(NamedThing(row), in: model)
                                    .id(row)
                            }
                            if own > 0 {
                                NodeRow(title: "Smaller items here", subtitle: nil, value: formatBytes(own),
                                        share: Double(own) / biggest, color: .white.opacity(0.3), onHover: { _ in }, onTap: {})
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
                .frame(height: min(max(wanted, rowHeight + 16), tallest))
                .onChange(of: model.lookCursor) { _, cursor in
                    if let cursor, top.indices.contains(cursor) {
                        withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(top[cursor]) }
                    }
                }
            }
        }
    }
}

/// The biggest photos and videos inside, so a folder can be recognised without reading a name.
private struct LookPictures: View {
    let model: AppModel
    let files: [UInt32]
    let height: CGFloat
    @State private var pictures: [UInt32: NSImage] = [:]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(files, id: \.self) { file in
                ZStack {
                    Rectangle().fill(.white.opacity(0.06))
                    if let picture = pictures[file] {
                        Image(nsImage: picture)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
                .onHover { inside in model.highlight(node: inside ? file : nil) }
                .onTapGesture { model.showInLook(file) }
                .named(NamedThing(file), in: model)
                .help(model.realName(of: file))
            }
        }
        .task(id: files) {
            pictures = [:]
            for file in files {
                guard !Task.isCancelled, let path = model.realPath(of: file) else { return }
                let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 240, height: 160), scale: 2, representationTypes: .thumbnail)
                if let drawn = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request), !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.16)) { pictures[file] = drawn.nsImage }
                }
            }
        }
    }
}

/// macOS's own preview: a video plays, a PDF scrolls, and whatever else it can read looks as it does in the Finder.
private struct LookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Where something ended up in the window.
private struct FrameReader: View {
    let report: (CGRect) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, frame in report(frame) }
        }
    }
}
