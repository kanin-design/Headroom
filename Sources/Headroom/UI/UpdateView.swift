import AppKit
import SwiftUI

/// The update window: what the new version brings and the choice to take it, then how the download is going.
struct UpdateView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL
    private let updater = Updater.shared

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            content
        }
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 24)
        .frame(width: 440)
        .containerBackground(Color(red: 0.03, green: 0.03, blue: 0.042), for: .window)
        .animation(.smooth(duration: 0.3), value: updater.state)
        .onExitCommand { close() }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .idle, .checking:
            heading("Looking for a new version…", "You have \(Updater.currentShown).")
            ProgressView()
                .controlSize(.small)
                .padding(.top, 18)
        case .upToDate:
            heading("Headroom is up to date", "\(Updater.currentShown) is the newest version.")
            buttons {
                Spacer()
                Button("OK") { close() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .couldNotCheck(let why):
            heading("Couldn't look for a new version", why)
            buttons {
                Button("OK") { close() }
                    .buttonStyle(.glass)
                Spacer()
                Button("Try Again") { updater.checkNow() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .available(let release):
            heading("Headroom \(release.shown) is out", "You have \(Updater.currentShown).")
            whatsNew(release)
            Text("Headroom opens again by itself when it's done.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            buttons {
                Button("Not This Version") {
                    updater.skip(release)
                    dismissWindow()
                }
                .buttonStyle(.glass)
                .help("You'll be asked again when there's a newer one")
                Spacer()
                Button("Update") { updater.install(release) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let release, let received):
            heading("Downloading \(release.shown)", "\(formatBytes(UInt64(max(received, 0)))) of \(formatBytes(UInt64(max(release.size, 0))))")
            ProgressView(value: Double(received), total: Double(max(release.size, 1)))
                .progressViewStyle(.linear)
                .padding(.top, 18)
            buttons {
                Spacer()
                Button("Cancel") { updater.cancel() }
                    .buttonStyle(.glass)
            }
        case .installing(let release):
            heading("Putting \(release.shown) in place", "Headroom opens again in a moment.")
            ProgressView()
                .controlSize(.small)
                .padding(.top, 18)
        case .failed(let release, let why):
            heading("The update didn't go through", why)
            buttons {
                Button("Download Page") { openURL(release.page) }
                    .buttonStyle(.glass)
                Spacer()
                Button("Try Again") { updater.install(release) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text(detail)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    /// The notes' list of what's new, on glass. A long list scrolls rather than stretching the window.
    private func whatsNew(_ release: Updater.Release) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's new")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                ForEach(Array(release.whatsNew.enumerated()), id: \.offset) { _, thing in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.white.opacity(0.4))
                        Text(Self.markdown(thing))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: 230)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 20)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .controlSize(.large)
            .padding(.top, 22)
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func close() {
        updater.dismiss()
        dismissWindow()
    }
}
