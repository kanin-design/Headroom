import AppKit
import SwiftUI

/// Full Disk Access, asked for once and explained: what macOS keeps private, what Headroom does with it, and where to switch
/// it on. It closes by itself once access is there.
struct AccessGuideView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    private let model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(spacing: Kit.Space.medium) {
                Text("Allow Full Disk Access")
                    .font(Kit.Font.title)
                    .foregroundStyle(Kit.Text.primary)
                Text(why)
                    .font(Kit.Font.body)
                    .foregroundStyle(Kit.Text.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Kit.Space.large)
            steps
            Text("Nothing about your disk leaves your Mac.")
                .font(Kit.Font.detail)
                .foregroundStyle(Kit.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Kit.Space.section)
            HStack(spacing: Kit.rowInset) {
                Button("Not now") { notNow() }
                    .buttonStyle(.glass)
                    .help("Hide until the next version")
                Spacer()
                Button("Open System Settings") { model.openFullDiskAccess() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 22)
        }
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 24)
        .frame(width: 440)
        .containerBackground(Palette.window, for: .window)
        .onAppear { model.accessGuideShowing = true }
        .onDisappear {
            model.accessGuideShowing = false
            Updater.shared.offerIfWaiting()
        }
        .onChange(of: model.hasFullAccess) { _, granted in if granted { dismissWindow() } }
        .onExitCommand { dismissWindow() }
    }

    /// What's private, and why Headroom waits rather than ask about each folder.
    private let why = "Required to scan Desktop, Documents, Downloads, Mail, Messages and other app data. Without it, Headroom reads nothing."

    private var steps: some View {
        VStack(alignment: .leading, spacing: Kit.Space.large) {
            step(1, "Open System Settings › Privacy & Security › Full Disk Access.")
            step(2, "Turn on Headroom. If it's already on, turn it off and on again. If it's not listed, click + and add it.")
            step(3, "If asked, click Quit & Reopen. The scan starts by itself.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Kit.Radius.pane, style: .continuous))
        .padding(.top, 20)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Kit.rowInset) {
            Text("\(number)")
                .font(Kit.Font.label.monospacedDigit())
                .foregroundStyle(Kit.Text.primary)
                .frame(width: 20, height: 20)
                .background(Kit.Fill.control, in: Circle())
            Text(text)
                .font(Kit.Font.body)
                .foregroundStyle(Kit.Text.primary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Not again at launch until the next version. The card on the map stays, for when you change your mind.
    private func notNow() {
        UserDefaults.standard.set(Updater.currentNumber, forKey: AppModel.accessGuideDeclinedKey)
        dismissWindow()
    }
}
