import AppKit
import SwiftUI

struct RootView: View {
    @State private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geometry in
            // The inspector has a column of its own, so all of this is the map's.
            let ring = RingGeometry.make(size: geometry.size)
            ZStack(alignment: .topLeading) {
                MapView(model: model)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                RingPlace(center: ring.center, radius: ring.radius, size: geometry.size, model: model)

                LabelsLayer(model: model)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)

                CenterReadout(model: model, ring: ring)

                BottomArea(model: model, ring: ring)
                    .frame(width: ring.mapWidth, height: geometry.size.height, alignment: .bottom)

                // The folder's own icon beside the title, as a Finder window has: drag it to another app, or ⌘-click the
                // title for where it is. Not with names hidden, since that would show them.
                if let url = proxyURL {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .navigationDocument(url)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onChange(of: ring, initial: true) { _, new in model.setRing(new) }
        }
        // The map goes on under the toolbar, which has no background of its own over it.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(red: 0.03, green: 0.03, blue: 0.042))
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbarTitleMenu { TitleMenu(model: model) }
        .toolbar { MainToolbar(model: model) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(text: $model.searchText, isPresented: $model.searchActive, placement: .toolbar, prompt: "Find a file or folder")
        .onChange(of: model.searchText) { _, text in
            model.runSearch()
            // What's found is listed in the inspector.
            if !text.isEmpty { model.showPanel(true) }
        }
        // Done searching: the keyboard goes back to the map, so Esc and Space work on it again.
        .onChange(of: model.searchActive) { _, active in
            if !active { model.mapView?.window?.makeFirstResponder(model.mapView) }
        }
        .inspector(isPresented: Binding(get: { model.panelOpen }, set: { model.showPanel($0) })) {
            SidePanel(model: model)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, width in model.noteInspectorWidth(width) }
                // Last, or SwiftUI doesn't see it and the inspector is its own default 270 points wide, neither more nor less.
                .inspectorColumnWidth(min: 340, ideal: AppModel.savedInspectorWidth, max: 520)
                .toolbar {
                    // Just before the search field, whether the inspector is open or not, as in Apple's apps.
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.showPanel(!model.panelOpen) } label: {
                            Label(model.panelOpen ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                        }
                        .help(model.panelOpen ? "Hide Inspector" : "Show Inspector")
                    }
                }
        }
        // With Reduce Motion, nothing springs past where it's going, and everything is quick.
        .transaction { transaction in
            if transaction.animation != nil, Motion.isReduced { transaction.animation = .easeInOut(duration: 0.2) }
        }
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .alert("\(model.busyToSend?.title ?? "This") is in use", isPresented: Binding(get: { model.busyToSend != nil }, set: { if !$0 { model.busyToSend = nil } }), presenting: model.busyToSend) { busy in
            Button("Send to Trash Anyway", role: .destructive) { model.sendAnyway(busy) }
            Button("Cancel", role: .cancel) {}
        } message: { busy in
            Text(busy.why + " You can undo this until the Trash is emptied.")
        }
        .onAppear { model.start() }
        // A new version found at launch brings its window forward, and so does a launch without Full Disk Access.
        .onChange(of: Updater.shared.windowRequests) { openWindow(id: "update") }
        .onChange(of: model.accessGuideRequests) { openWindow(id: "access") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.didBecomeActive()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.volumesChanged()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.volumesChanged()
        }
    }

    /// Where you are, as a Finder window says it: the folder you're in, or the disk itself.
    private var title: String {
        guard model.focus != 0, model.tree != nil else { return model.volume?.shownName ?? "Headroom" }
        return model.displayName(model.focus)
    }

    /// Under the title: how far the scan has got, or how much is free, the same as in the middle of the ring. Inside a
    /// folder, which disk it's on as well.
    private var subtitle: String {
        if model.isScanning { return model.scanFiles > 0 ? "Reading \(formatCount(model.scanFiles)) files" : "Reading" }
        if !model.hasFullAccess, model.volume?.isBoot == true { return "Waiting for Full Disk Access" }
        guard let free = model.tree.map({ $0.totals[Int($0.free)] }) ?? model.volume?.free else { return "" }
        if model.focus != 0 { return "\(model.volume?.shownName ?? "Disk")  ·  \(formatBytes(free)) free" }
        let capacity = model.tree?.capacityBytes ?? model.volume?.capacity ?? 0
        return "\(formatBytes(free)) free of \(formatBytes(capacity))"
    }

    /// The real place on the disk the title stands for. Groups Headroom makes up, such as macOS's own parts, have none.
    private var proxyURL: URL? {
        guard !HiddenNames.isOn, let tree = model.tree, let volume = model.volume else { return nil }
        if model.focus == 0 { return URL(fileURLWithPath: volume.mountPath) }
        return tree.path(model.focus).map { URL(fileURLWithPath: $0) }
    }
}

// MARK: Top

/// Back and forward at the start of the toolbar, the three views in the middle, and Scan Again at the end, before the search
/// field and the inspector's button. It can't be rearranged: on macOS 27 a toolbar that can be moves back and forward to the
/// other end and squeezes the inspector, and a small app built the same way stops at launch.
private struct MainToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward")
        }
        ToolbarItem(placement: .principal) {
            LensPicker(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.scan(hurry: true) } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                .disabled(model.scanIsHurrying)
                .help("Read the disk again, at full power")
        }
    }
}

/// Map, Changes and Free Up. Switching never moves the ring, only what its colours say.
struct LensPicker: View {
    let model: AppModel

    var body: some View {
        Picker("View", selection: Binding(get: { model.lens }, set: { lens in
            Motion.animate(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(lens) }
        })) {
            ForEach(Lens.allCases) { lens in
                Text(lens.rawValue)
                    .help(lens.help)
                    .tag(lens)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// The title's menu: the folders the one you're in is inside, to go straight back to one, then the disks.
private struct TitleMenu: View {
    let model: AppModel

    var body: some View {
        if let tree = model.tree, model.focus != 0 {
            ForEach(tree.ancestors(of: model.focus).dropLast().reversed(), id: \.self) { node in
                Button {
                    model.go(to: node)
                } label: {
                    if node == 0 {
                        Label(model.volume?.shownName ?? "Disk", systemImage: model.volume?.isBoot == false ? "externaldrive" : "internaldrive")
                    } else {
                        Label(model.displayName(node), systemImage: "folder")
                    }
                }
            }
            Divider()
        }
        ForEach(model.volumes, id: \.mountPath) { volume in
            Button {
                model.switchVolume(volume)
            } label: {
                Label("\(volume.shownName)  ·  \(formatBytes(volume.free)) free of \(formatBytes(volume.capacity))",
                      systemImage: volume.isBoot ? "internaldrive" : "externaldrive")
            }
        }
    }
}

// MARK: Bottom

struct BottomArea: View {
    let model: AppModel
    let ring: RingGeometry

    var body: some View {
        VStack(spacing: 10) {
            if let message = model.message {
                MessageCard(model: model, message: message)
                    .transition(Motion.arrival(from: .bottom))
            }
            if let tip = model.tip {
                HStack(spacing: 12) {
                    Text(tip)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if model.tipOffersUndo {
                        Button("Undo") { model.undoCommand() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.reclaim(.rebuilds).swiftUI)
                            .pointerStyle(.link)
                    }
                }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule())
                    .transition(.opacity)
            }
            if !model.hasFullAccess && !model.accessCardDismissed, model.volume?.isBoot == true {
                AccessCard(model: model)
                    .transition(Motion.arrival(from: .bottom))
            } else if model.focus != 0 {
                Breadcrumbs(model: model)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 12)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.message)
        .animation(.easeOut(duration: 0.18), value: model.tip)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.focus)
    }
}

struct Breadcrumbs: View {
    let model: AppModel

    var body: some View {
        if let tree = model.tree {
            let chain = tree.ancestors(of: model.focus)
            HStack(spacing: 4) {
                ForEach(Array(chain.enumerated()), id: \.element) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Button {
                        // You're already here, so a click on this one copies its name.
                        if node == model.focus { model.copyName(of: NamedThing(node)) } else { model.go(to: node) }
                    } label: {
                        Text(index == 0 ? (model.volume?.shownName ?? "Disk") : model.displayName(node))
                            .font(.system(size: 12, weight: node == model.focus ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(node == model.focus ? 0.95 : 0.6))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .named(NamedThing(node), in: model)
                    .help(node == model.focus ? "Click to copy the name" : "⌘-click to copy the name")
                }
            }
            .padding(.horizontal, 12)
            .glassEffect(.regular, in: Capsule())
        }
    }
}

struct MessageCard: View {
    let model: AppModel
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
            Button {
                model.message = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Explains the hatched piece: Headroom reads nothing until macOS lets it read everything.
struct AccessCard: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for Full Disk Access")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("macOS keeps Downloads, Desktop, Documents and other folders private, so Headroom reads nothing until it may read everything.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 330, alignment: .leading)
            Button("Allow Full Disk Access") { openWindow(id: "access") }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            Button {
                model.accessCardDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
