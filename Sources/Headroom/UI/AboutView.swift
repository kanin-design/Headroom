import AppKit
import SwiftUI

/// About Headroom, in the app menu: the icon, the logo, and which version and build this is.
struct AboutView: View {
    private var version: String {
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // macOS wants the number to be only a number, so "beta" is kept apart from it.
        guard let stage = Bundle.main.object(forInfoDictionaryKey: "HeadroomStage") as? String else { return number }
        return number + " " + stage
    }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            logo
                .padding(.top, 6)
            Text("Version \(version)  ·  Build \(build)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 14)
        }
        .padding(.top, 4)
        .padding(.bottom, 28)
        .frame(width: 320)
        .containerBackground(Color(red: 0.03, green: 0.03, blue: 0.042), for: .window)
    }

    @ViewBuilder
    private var logo: some View {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 200)
                .accessibilityLabel("Headroom")
        } else {
            Text("Headroom")
                .font(.system(size: 24, weight: .semibold))
        }
    }
}
