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
            VStack(spacing: 6) {
                Text("Allow Full Disk Access")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(why)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            steps
            Text("Nothing about your disk leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            HStack(spacing: 10) {
                Button("Not Now") { notNow() }
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
        .containerBackground(Color(red: 0.03, green: 0.03, blue: 0.042), for: .window)
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
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Open System Settings › Privacy & Security › Full Disk Access.")
            step(2, "Turn on Headroom. If it's already on, turn it off and on again. If it's not listed, click + and add it.")
            step(3, "If asked, click Quit & Reopen. The scan starts by itself.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 20)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.12), in: Circle())
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.82))
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
