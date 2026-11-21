import AppKit
import SwiftUI

/// The bottom row: the disk the map is of at the left, the folder you're in in the middle, and in Backup, where its files go
/// at the right. Its height is kept free in every view, so nothing moves when the right capsule appears.
struct DriveRow: View {
    let model: AppModel

    /// How tall the row is, which the ring and its names keep clear of.
    static let height: CGFloat = 34

    var body: some View {
        ZStack {
            if model.focus != 0 {
                Breadcrumbs(model: model)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                SourceCapsule(model: model)
                Spacer(minLength: 12)
                if model.mode == .backup {
                    DestinationCapsule(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                }
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.18), value: model.mode == .backup)
    }
}

/// One drive in a capsule of glass: its icon, its name, and how much is free on it.
private struct DriveCapsuleLabel: View {
    let icon: String
    let title: String
    let detail: String
    var dim = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(dim ? 0.45 : 0.8))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(dim ? 0.55 : 0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: DriveRow.height)
        .frame(maxWidth: 260, alignment: .leading)
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private func icon(_ drive: DriveInfo) -> String {
    if drive.isNetwork { return "externaldrive.connected.to.line.below" }
    return drive.isBoot || drive.isInternal ? "internaldrive" : "externaldrive"
}

private func detail(_ drive: DriveInfo) -> String {
    guard drive.isConnected else { return "Not connected · \(drive.fileSystemTitle)" }
    return "\(formatBytes(drive.free)) free of \(formatBytes(drive.capacity)) · \(drive.fileSystemTitle)"
}

/// The disk the map is of. Choosing another reads that one.
private struct SourceCapsule: View {
    let model: AppModel

    var body: some View {
        let current = model.volume
        let drive = model.sourceDrive
        Menu {
            ForEach(model.volumes, id: \.mountPath) { volume in
                let info = model.drives.first { $0.mountPath == volume.mountPath }
                Button {
                    model.switchVolume(volume)
                } label: {
                    Label {
                        Text(volume.shownName)
                        Text(info.map(detail) ?? "\(formatBytes(volume.free)) free of \(formatBytes(volume.capacity))")
                    } icon: {
                        Image(systemName: volume.mountPath == current?.mountPath ? "checkmark" : (volume.isBoot ? "internaldrive" : "externaldrive"))
                    }
                }
                .disabled(model.isCleaning)
            }
        } label: {
            // What's free as the map counts it, so the capsule, the title and the middle of the ring say the same.
            let free = model.shownFree ?? drive?.free ?? current?.free ?? 0
            DriveCapsuleLabel(icon: current?.isBoot == false ? "externaldrive" : "internaldrive",
                         title: current?.shownName ?? "Disk",
                         detail: drive.map { "\(formatBytes(free)) free · \($0.fileSystemTitle)" } ?? (current == nil ? "" : "\(formatBytes(free)) free"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the disk to show")
        .accessibilityLabel("Disk shown")
    }
}

/// Where Backup's files go: the locations used before, then the other drives connected now, or any folder at all, a
/// server's share included.
private struct DestinationCapsule: View {
    let model: AppModel

    var body: some View {
        let destination = model.backup.destination
        let connected = destination.flatMap { model.connected($0.drive) }
        let used = model.usedLocations
        Menu {
            ForEach(used) { place in
                choice(place.title, on: place.drive, isCurrent: destination?.isSame(as: place) == true) {
                    model.chooseDestination(place.drive, folder: place.folder)
                }
            }
            if !used.isEmpty { Divider() }
            ForEach(model.otherDrives) { drive in
                choice(drive.name, on: drive, isCurrent: false) { model.chooseDestination(drive) }
            }
            Divider()
            Button("Choose Folder…") { model.chooseDestinationFolder() }
                .disabled(model.isCleaning)
        } label: {
            if let destination {
                DriveCapsuleLabel(icon: icon(destination.drive), title: destination.title,
                             detail: connected.map { "\(formatBytes($0.free)) free · \($0.fileSystemTitle)" } ?? "Not connected", dim: connected == nil)
            } else {
                DriveCapsuleLabel(icon: "externaldrive.badge.plus", title: "Choose a location", detail: "Backup location", dim: true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose where Backup puts files")
        .accessibilityLabel("Backup location")
    }

    /// One place to choose: its name, how full its drive is, and why it can't be chosen when it can't.
    private func choice(_ title: String, on drive: DriveInfo, isCurrent: Bool, choose: @escaping () -> Void) -> some View {
        let why = model.whyNotDestination(drive)
        return Button(action: choose) {
            Label {
                Text(title)
                Text(why.map { "\($0) · \(drive.fileSystemTitle)" } ?? (drive.largestFile != nil ? detail(drive) + " · No files over 4 GB" : detail(drive)))
            } icon: {
                Image(systemName: isCurrent ? "checkmark" : icon(drive))
            }
        }
        .disabled(why != nil || model.isCleaning)
    }
}
