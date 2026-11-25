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
                RingPlace(center: ring.center, radius: ring.radius, size: geometry.size, engine: model.engine, view: { model.mapView })

                LabelsLayer(model: model, ring: ring)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)

                CenterIsland(model: model)
                    .frame(width: CenterIsland.diameter(in: ring), height: CenterIsland.diameter(in: ring))
                    .position(ring.center)
                    .allowsHitTesting(false)

                BottomArea(model: model, ring: ring)
                    .frame(width: ring.mapWidth, height: geometry.size.height, alignment: .bottom)

                AgentQuestion()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onChange(of: ring, initial: true) { _, new in model.setRing(new) }
        }
        // The map goes on under the toolbar, which has no background of its own over it.
        .ignoresSafeArea(.container, edges: .top)
        .background(Palette.window)
        // The window is named for where you are, in the Window menu and Mission Control, but the name isn't shown: the
        // disk selector and the path bar say it.
        .navigationTitle(title)
        .toolbar(removing: .title)
        .toolbar { MainToolbar(model: model) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The search field, on an empty view of its own: see `SearchField`.
        .background { Color.clear.modifier(SearchField(model: model)) }
        .inspector(isPresented: Binding(get: { model.panelOpen }, set: { model.showPanel($0) })) {
            SidePanel(model: model)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, width in model.noteInspectorWidth(width) }
                // Last, or SwiftUI doesn't see it and the inspector is its own default 270 points wide, neither more nor less.
                .inspectorColumnWidth(min: 340, ideal: AppModel.savedInspectorWidth, max: 520)
                .toolbar {
                    // Just before the search field, whether the inspector is open or not, as in Apple's apps.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showPanel(!model.panelOpen)
                        } label: {
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
        .alert(
            "\(model.busyToSend?.title ?? "This") is in use",
            isPresented: Binding(get: { model.busyToSend != nil }, set: { if !$0 { model.busyToSend = nil } }), presenting: model.busyToSend
        ) { busy in
            Button("Move to Trash Anyway", role: .destructive) { model.sendAnyway(busy) }
            Button("Cancel", role: .cancel) {}
        } message: { busy in
            Text(busy.why + " Undo works until the Trash is emptied.")
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

    /// Where you are, as a Finder window says it: the folder you're in, the path bar's last step, or the disk itself.
    private var title: String {
        model.pathSteps.last?.name ?? model.volume?.shownName ?? "Headroom"
    }
}

/// The toolbar's search field, and what typing in it does. It goes on an empty view behind the window's, not on the
/// window's own: SwiftUI keeps a search's state in the environment of everything under the field, so on the whole window
/// each key made the toolbar's buttons again, laid the toolbar out, and updated the map, the middle and the path bar.
/// And it's a modifier of its own because whatever reads the search text is worked out again on every key: here that's
/// this alone, not `RootView`. The field is the same one, in the same place in the toolbar.
private struct SearchField: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .searchable(text: $model.searchText, isPresented: $model.searchActive, placement: .toolbar, prompt: "Search")
            .onChange(of: model.searchText) { _, text in
                model.runSearch(typed: true)
                // What's found is listed in the inspector.
                if !text.isEmpty { model.showPanel(true) }
            }
            // Done searching: the keyboard goes back to the map, so Esc and Space work on it again.
            .onChange(of: model.searchActive) { _, active in
                if !active { model.mapView?.window?.makeFirstResponder(model.mapView) }
            }
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
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("Back")
            Button {
                model.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("Forward")
        }
        // Two pickers with room between: the view, and the mode. One fixed spacer is the system's gap between groups, about 10
        // points, and the two capsules nearly touch; two make it about 18, and they read as two.
        ToolbarItem(placement: .principal) {
            LensPicker(model: model, lenses: Lens.views, name: "View")
        }
        ToolbarSpacer(.fixed, placement: .principal)
        ToolbarSpacer(.fixed, placement: .principal)
        ToolbarItem(placement: .principal) {
            LensPicker(model: model, lenses: Lens.actions, name: "Mode")
        }
        // How a folder's contents are ordered, as the Finder's toolbar offers it, beside Scan Again.
        ToolbarItemGroup(placement: .primaryAction) {
            SortMenu(model: model)
            Button {
                model.scan(hurry: true)
            } label: {
                Label("Scan Again", systemImage: "arrow.clockwise")
            }
            .disabled(model.scanIsHurrying)
            .help("Rescan everything at full speed")
        }
    }
}

/// Sort By: what's in a folder by name or biggest first, on the ring and in the inspector's lists.
struct SortMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { model.sortBy }, set: { model.sortBy = $0 })) {
                ForEach(SortBy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort by name or size")
    }
}

/// One of the toolbar's two pickers: the view (Map, Changes, Copies) or the mode (Free Up, Backup). Each always has one
/// chosen, and choosing in one leaves the other as it is.
private struct LensPicker: View {
    let model: AppModel
    let lenses: [Lens]
    let name: String

    var body: some View {
        let isMode = lenses.first?.isAction == true
        // In Backup, Copies is Backed Up: what's on the drive and what isn't.
        let backedUp = { (lens: Lens) in lens == .copies && model.mode == .backup }
        Segmented(
            name: name, options: lenses, selection: isMode ? model.mode : model.view,
            title: { backedUp($0) ? "Backed Up" : $0.title }, help: { backedUp($0) ? "Backed up or not" : $0.help },
            size: nil,
            select: { lens in Motion.animate(Motion.switching) { isMode ? model.setMode(lens) : model.setView(lens) } })
    }
}

// MARK: Bottom

private struct BottomArea: View {
    let model: AppModel
    let ring: RingGeometry

    var body: some View {
        VStack(spacing: 10) {
            AgentsConnected()
            if let message = model.message {
                MessageCard(model: model, message: message)
                    .transition(Motion.arrival(from: .bottom))
            }
            if let tip = model.tip {
                HStack(spacing: 12) {
                    Text(tip)
                        .font(Kit.Font.name)
                        .foregroundStyle(Kit.Text.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if model.tipOffersUndo {
                        Button("Undo") { model.undoCommand() }
                            .buttonStyle(.textLink(Kit.green, font: Kit.Font.strong))
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
            }
            DriveRow(model: model)
        }
        .padding(.bottom, 12)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.message)
        .animation(.easeOut(duration: 0.18), value: model.tip)
        .animation(.easeOut(duration: 0.18), value: Agents.shared.connected)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.focus)
    }
}

private struct MessageCard: View {
    let model: AppModel
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(Kit.Font.name)
                .foregroundStyle(Kit.Text.primary)
            Button {
                model.message = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.symbol)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Explains the hatched piece: Headroom reads nothing until macOS lets it read everything.
private struct AccessCard: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(Kit.Font.headline)
                .foregroundStyle(Kit.Text.secondary)
            Text("Needs Full Disk Access")
                .font(Kit.Font.headline)
                .foregroundStyle(Kit.Text.primary)
            Button("Allow…") { openWindow(id: "access") }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help("Show how to allow access")
            Button {
                model.accessCardDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.symbol)
            .help("Not now")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
