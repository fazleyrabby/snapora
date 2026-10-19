import AppKit

/// Standard macOS About panel with Snapora's credits.
@MainActor
enum AboutWindow {
    static let authorName = "Fazley Rabbi"
    static let authorURL = URL(string: "https://fazleyrabbi.xyz/")!

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Snapora",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? coreVersion(),
            .version: "core \(coreVersion())",
            .credits: credits,
        ])
    }

    private static var credits: NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let text = NSMutableAttributedString(string: "Screenshots and screen recordings, kept local.\n\nCreated by ", attributes: base)
        text.append(NSAttributedString(string: authorName, attributes: base.merging([
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]) { $1 }))
        text.append(NSAttributedString(string: "\n", attributes: base))
        text.append(NSAttributedString(string: "fazleyrabbi.xyz", attributes: base.merging([
            .link: authorURL,
        ]) { $1 }))
        return text
    }
}
