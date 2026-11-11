import AVKit
import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

/// The card Space opens: what something is, what it's like, and what you can do about it. It fills its own window, which
/// `LookPanel` keeps.
struct LookCard: View {
    let model: AppModel
    let look: Look
    let isFolder: Bool
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        if let tree = model.tree {
            let _ = model.treeVersion
            VStack(alignment: .leading, spacing: 0) {
                header(tree)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in headerHeight = height }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FrameReader { model.lookContentFrame = $0 })
                footer(tree)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in footerHeight = height }
            }
            // How tall the card's own parts are, so its window can give a film or a picture the rest, in its own shape.
            .onChange(of: headerHeight + footerHeight, initial: true) { _, chrome in model.lookChrome = chrome }
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
                .help("Back")
            }
            if !HiddenNames.isOn, let real = model.realPath(of: node) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: real))
                    .resizable()
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                PanelTitle(title: name, subtitle: path, copyTitle: { model.copyName(of: thing) }, copySubtitle: { model.copyPath(of: thing) })
                let details = model.lookDetails.node == node ? model.lookDetails : LookDetails()
                if let facts = [model.facts(of: node), details.media].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(facts)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let decide = [details.lastUse, details.frees.map(Self.frees)].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(decide)
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
                .help("Close (Space)")
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
        // Anywhere on it but a button moves the window.
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    /// What sending it to the Trash and emptying it would give back, with other copies counted.
    private static func frees(_ bytes: UInt64) -> String {
        bytes == 0 ? "Frees nothing" : "Frees \(formatBytes(bytes))"
    }

    @ViewBuilder
    private var content: some View {
        if isFolder {
            LookFolder(model: model, node: look.node)
        } else if !HiddenNames.isOn, let path = model.realPath(of: look.node) {
            let url = URL(fileURLWithPath: path)
            Group {
                if LookMedia.isFilm(url) { LookFilm(model: model, url: url) } else { LookPreview(url: url) }
            }
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
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.glass)
            }
            Spacer(minLength: 4)
            if model.canPlan(node) {
                FreeUpTick(model: model, node: node)
            }
            if node != 0 {
                DeleteMenu(model: model, node: node)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

/// What's inside, biggest first, in the ring's colours. The size is already known, so it's there at once.
private struct LookFolder: View {
    let model: AppModel
    let node: UInt32

    private let rowHeight: CGFloat = 33.5
    private let pictureHeight: CGFloat = 78

    var body: some View {
        if let tree = model.tree {
            let rows = model.lookRows(of: node, in: tree)
            let top = Array(rows.prefix(300))
            let biggest = Double(max(top.first.map { tree.totals[Int($0)] } ?? 1, 1))
            let own = node == 0 ? 0 : tree.nodes[Int(RingLayout.chainTail(tree: tree, node))].bytes
            let pictures = HiddenNames.isOn ? [] : LookContents.media(in: node, tree: tree)
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
                .frame(maxHeight: .infinity, alignment: .top)
                .onChange(of: model.lookCursor) { _, cursor in
                    if let cursor, top.indices.contains(cursor) {
                        Motion.animate(.easeOut(duration: 0.14)) { proxy.scrollTo(top[cursor]) }
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
            let paths = files.compactMap { file in model.realPath(of: file).map { (file, $0) } }
            // All at once, and each shows as soon as it's ready.
            await withTaskGroup(of: (UInt32, NSImage?).self) { group in
                for (file, path) in paths {
                    group.addTask {
                        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 240, height: 160), scale: 2, representationTypes: .thumbnail)
                        return (file, try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage)
                    }
                }
                for await (file, picture) in group where !Task.isCancelled {
                    if let picture { Motion.animate(.easeOut(duration: 0.16)) { pictures[file] = picture } }
                }
            }
        }
    }
}

/// Ticks it for Free Up from the card, in the colour of the box it's suggested in, or as something picked by hand.
private struct FreeUpTick: View {
    let model: AppModel
    let node: UInt32

    var body: some View {
        let planned = model.isPlanned(node)
        Button {
            model.toggleSelection(of: NamedThing(node))
        } label: {
            HStack(spacing: 7) {
                TickMark(state: planned ? .all : .none, color: model.planColour(of: node), size: 15)
                Text("Free Up")
            }
        }
        .buttonStyle(.glass)
        .help(planned ? "Deselect in Free Up" : "Select in Free Up")
    }
}

/// A film, played where it is with macOS's own controls. A click on the picture plays it or pauses it, and the bar along
/// the bottom, which shows when the pointer is over the film, is the controls'.
private struct LookFilm: View {
    let model: AppModel
    let url: URL
    @State private var film: FilmPlayer?

    var body: some View {
        ZStack {
            FilmView(player: film?.player)
            Color.clear
                .contentShape(Rectangle())
                .padding(.bottom, 64)
                .onTapGesture { film?.toggle() }
            if film?.isPlaying != true {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 64, height: 64)
                    .glassEffect(.regular, in: Circle())
                    .allowsHitTesting(false)
                    .transition(Motion.arrival(from: .bottom).combined(with: .scale(scale: 0.9)))
            }
        }
        .task(id: url) {
            film?.stop()
            film = FilmPlayer(url: url, model: model)
        }
        .onDisappear {
            film?.stop()
            film = nil
        }
    }
}

/// A film's player, and whether it's playing, for as long as the card shows the film. Whatever starts or stops it, the
/// picture or the controls, the card hears of it.
@MainActor @Observable
private final class FilmPlayer {
    let player: AVPlayer
    private(set) var isPlaying = false
    @ObservationIgnored private var watch: NSKeyValueObservation?
    @ObservationIgnored private weak var model: AppModel?

    init(url: URL, model: AppModel) {
        player = AVPlayer(url: url)
        self.model = model
        model.lookIsPlaying = false
        watch = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playing(playing) }
        }
    }

    private func playing(_ now: Bool) {
        guard now != isPlaying else { return }
        Motion.animate(.easeOut(duration: 0.15)) { isPlaying = now }
        model?.lookIsPlaying = now
    }

    func toggle() {
        if player.timeControlStatus == .paused {
            // From the start again once it has reached the end.
            if let item = player.currentItem, item.currentTime() >= item.duration { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    func stop() {
        player.pause()
        watch = nil
        model?.lookIsPlaying = false
    }
}

private struct FilmView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// macOS's own preview: a PDF scrolls, a song plays, and whatever else it can read looks as it does in the Finder.
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
