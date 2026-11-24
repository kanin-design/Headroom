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
        .containerBackground(Palette.window, for: .window)
        .animation(.smooth(duration: 0.3), value: updater.state)
        .onExitCommand { close() }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .idle, .checking:
            heading("Checking for updates…", "You have \(Updater.currentShown).")
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
            heading("Couldn't check for updates", why)
            buttons {
                Button("OK") { close() }
                    .buttonStyle(.glass)
                Spacer()
                Button("Try again") { updater.checkNow() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .available(let release):
            heading("Headroom \(Updater.name(of: release)) is available", "You have \(Updater.currentName(besides: release)).")
            whatsNew(release)
            buttons {
                Button("Skip This Version") {
                    updater.skip(release)
                    dismissWindow()
                }
                .buttonStyle(.glass)
                .help("Don't offer this version again")
                Spacer()
                Button("Install Update") { updater.install(release) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Install and relaunch Headroom")
            }
        case .downloading(let release, let received):
            heading(
                "Downloading \(Updater.name(of: release))", "\(formatBytes(UInt64(max(received, 0)))) of \(formatBytes(UInt64(max(release.size, 0))))"
            )
            ProgressView(value: Double(received), total: Double(max(release.size, 1)))
                .progressViewStyle(.linear)
                .padding(.top, 18)
            buttons {
                Spacer()
                Button("Cancel") { updater.cancel() }
                    .buttonStyle(.glass)
            }
        case .installing(let release):
            heading("Installing \(Updater.name(of: release))…", "Headroom will relaunch.")
            ProgressView()
                .controlSize(.small)
                .padding(.top, 18)
        case .failed(let release, let why):
            heading("Update failed", why)
            buttons {
                Button("Download Page") { openURL(release.page) }
                    .buttonStyle(.glass)
                Spacer()
                Button("Try again") { updater.install(release) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(Kit.Font.title)
                .foregroundStyle(Kit.Text.primary)
            Text(detail)
                .font(Kit.Font.body.monospacedDigit())
                .foregroundStyle(Kit.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Kit.Space.large)
    }

    /// The notes' list of what's new, on glass. A long list scrolls rather than stretching the window.
    private func whatsNew(_ release: Updater.Release) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Kit.rowInset) {
                SectionHeading(text: "What's new", inset: 0)
                ForEach(Array(release.whatsNew.enumerated()), id: \.offset) { _, thing in
                    HStack(alignment: .firstTextBaseline, spacing: Kit.Space.regular) {
                        Text("•")
                            .foregroundStyle(Kit.Text.quaternary)
                        Text(Self.markdown(thing))
                            .foregroundStyle(Kit.Text.primary)
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Kit.Font.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: 230)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Kit.Radius.pane, style: .continuous))
        .padding(.top, 20)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Kit.rowInset) { content() }
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
