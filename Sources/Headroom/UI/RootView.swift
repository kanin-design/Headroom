import AppKit
import SwiftUI

struct RootView: View {
    @State private var model = AppModel.shared

    var body: some View {
        GeometryReader { geometry in
            let ring = RingGeometry.make(size: geometry.size, panelOpen: model.panelOpen, lens: model.lens)
            ZStack(alignment: .topLeading) {
                MapView(model: model, ring: ring)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                LabelsLayer(model: model)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)

                CenterReadout(model: model, ring: ring)

                LookLayer(model: model, ring: ring, height: geometry.size.height)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)

                // Centred over the ring, unless the window is so narrow that it would meet the disk chip.
                LensSwitcher(model: model)
                    .position(x: max(ring.center.x, 432), y: 31)

                DiskChip(model: model)
                    .padding(.leading, 82)
                    .padding(.top, 11)

                HStack {
                    Spacer()
                    ToolCluster(model: model)
                        .padding(.trailing, 14)
                        .padding(.top, 11)
                }

                if model.panelOpen {
                    HStack {
                        Spacer()
                        SidePanel(model: model)
                            .frame(width: RingGeometry.panelWidth(for: model.lens))
                            .padding(.trailing, 14)
                            .padding(.top, 60)
                            .padding(.bottom, 14)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                BottomArea(model: model, ring: ring)
                    .frame(width: ring.mapWidth, height: geometry.size.height, alignment: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onChange(of: ring, initial: true) { _, new in model.setRing(new) }
        }
        .ignoresSafeArea()
        .background(Color(red: 0.03, green: 0.03, blue: 0.042))
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: model.panelOpen)
        .alert("\(model.busyToSend?.title ?? "This") is in use", isPresented: Binding(get: { model.busyToSend != nil }, set: { if !$0 { model.busyToSend = nil } }), presenting: model.busyToSend) { busy in
            Button("Send to Trash Anyway", role: .destructive) { model.sendAnyway(busy) }
            Button("Cancel", role: .cancel) {}
        } message: { busy in
            Text(busy.why + " You can undo this until the Trash is emptied.")
        }
        .onAppear { model.start() }
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
}

// MARK: Top

struct LensSwitcher: View {
    let model: AppModel
    @Namespace private var space

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 2) {
                ForEach(Lens.allCases) { lens in
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(lens) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: lens.symbol)
                                .font(.system(size: 12, weight: .semibold))
                            Text(lens.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                            // How many things are selected, wherever you are.
                            if lens == .freeUp, !model.plan.isEmpty {
                                Text("\(model.plan.count)")
                                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.black.opacity(0.8))
                                    .padding(.horizontal, 5)
                                    .frame(minHeight: 15)
                                    .background(Capsule().fill(Palette.reclaim(.rebuilds).swiftUI))
                                    .help("\(model.plan.count) selected. Nothing happens until you clean.")
                            }
                        }
                        .foregroundStyle(model.lens == lens ? Color.white : Color.white.opacity(0.62))
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background {
                            if model.lens == lens {
                                Capsule()
                                    .fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "selected", in: space)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(help(lens))
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
        }
    }

    private func help(_ lens: Lens) -> String {
        switch lens {
        case .map: "What's on the disk, by kind"
        case .changes: "What has grown lately"
        case .freeUp: "Get space back, what you'd miss least first"
        }
    }
}

struct DiskChip: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(model.volumes, id: \.mountPath) { volume in
                Button {
                    model.switchVolume(volume)
                } label: {
                    Label("\(volume.shownName)  ·  \(formatBytes(volume.free)) free of \(formatBytes(volume.capacity))",
                          systemImage: volume.isBoot ? "internaldrive" : "externaldrive")
                }
            }
        } label: {
            HStack(spacing: 7) {
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: (model.volume?.isBoot ?? true) ? "internaldrive" : "externaldrive")
                        .font(.system(size: 12, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: -1) {
                    Text(model.volume?.shownName ?? "Disk")
                        .font(.system(size: 12, weight: .semibold))
                    if model.isScanning {
                        Text(model.scanFiles > 0 ? "Reading \(formatCount(model.scanFiles)) files" : "Reading")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    } else if model.scanFiles > 0 {
                        Text("\(formatCount(model.scanFiles)) files")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusable(false)
        .focusEffectDisabled()
        .fixedSize()
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct ToolCluster: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if model.searchActive {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        TextField("Find a file or folder", text: $model.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($searchFocused)
                            .frame(width: 170)
                            .onChange(of: model.searchText) { _, _ in model.runSearch() }
                            .onSubmit { model.runSearch() }
                            .onExitCommand { closeSearch() }
                            .onAppear { searchFocused = true }
                        Button(action: closeSearch) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .glassEffect(.regular, in: Capsule())
                } else {
                    toolButton("magnifyingglass", "Find (⌘F)") {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { model.searchActive = true; model.panelOpen = true }
                    }
                }
                toolButton("arrow.clockwise", "Scan again (⌘R)") { model.scan(hurry: true) }
                    .disabled(model.scanIsHurrying)
                toolButton("sidebar.right", model.panelOpen ? "Hide the panel" : "Show the panel") {
                    model.panelOpen.toggle()
                }
            }
        }
    }

    private func closeSearch() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            model.searchActive = false
            model.searchText = ""
            model.searchResults = []
        }
        model.engine.setEmphasis(primary: nil, related: [])
        model.mapView?.window?.makeFirstResponder(model.mapView)
    }

    private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
            if !model.hasFullAccess && !model.askPerFolder && !model.accessCardDismissed && !model.forceTouchGuarded, model.volume?.isBoot == true {
                AccessCard(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

/// Explains the hatched piece: macOS hides these folders until you say otherwise.
struct AccessCard: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text("Some folders are locked")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("macOS keeps Downloads, Desktop, Documents and a few others private until you give permission.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 330, alignment: .leading)
            VStack(spacing: 5) {
                Button("Allow Full Disk Access") { model.openFullDiskAccess() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                Button("Ask for each folder") { model.useFolderPrompts() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
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
