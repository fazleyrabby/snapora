import AppKit
import SwiftUI

@MainActor
enum HistoryWindow {
    /// Injectable: how image items are opened (e.g. the editor). Default: NSWorkspace.
    static var onOpenImage: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Snapora History"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 520, height: 360)
            w.contentView = NSHostingView(rootView: HistoryView(service: .shared))
            w.setFrameAutosaveName("SnaporaHistoryWindow")
            w.center()
            window = w
        }
        HistoryService.shared.runMaintenance()
        HistoryService.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Actions

    static func open(_ r: CaptureRecord) {
        let url = URL(fileURLWithPath: r.filePath)
        guard FileManager.default.fileExists(atPath: r.filePath) else { return }
        if r.kind == .screenshot || r.kind == .scrolling { onOpenImage(url) } else { VideoEditor.open(url: url) }
    }

    static func copy(_ r: CaptureRecord) {
        let url = URL(fileURLWithPath: r.filePath)
        let pb = NSPasteboard.general
        pb.clearContents()
        if r.kind == .screenshot || r.kind == .scrolling {
            guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { NSSound.beep(); return }
            pb.writeObjects([img])
            pb.setData(data, forType: .png)
        } else {
            pb.writeObjects([url as NSURL])
        }
    }

    static func reveal(_ r: CaptureRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.filePath)])
    }

    static func confirmDelete(_ r: CaptureRecord) {
        let a = NSAlert()
        a.messageText = "Delete this capture?"
        let managed = HistoryService.isManaged(URL(fileURLWithPath: r.filePath))
        a.informativeText = managed
            ? "The capture and its file will be permanently deleted."
            : "It will be removed from history. The file outside Snapora's storage is kept."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { HistoryService.shared.delete(r) }
    }
}

private struct HistoryView: View {
    @ObservedObject var service: HistoryService

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]

    private var filterTag: Binding<Int> {
        Binding(get: {
            switch service.kindFilter {
            case nil: return 0
            case .some(.screenshot), .some(.scrolling): return 1
            case .some(.recording): return 2
            case .some(.gif): return 3
            }
        }, set: {
            switch $0 {
            case 1: service.kindFilter = .screenshot
            case 2: service.kindFilter = .recording
            case 3: service.kindFilter = .gif
            default: service.kindFilter = nil
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search", text: $service.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Picker("", selection: filterTag) {
                    Text("All").tag(0)
                    Text("Screenshots").tag(1)
                    Text("Recordings").tag(2)
                    Text("GIFs").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                Toggle(isOn: $service.favoritesOnly) {
                    Image(systemName: service.favoritesOnly ? "star.fill" : "star")
                }
                .toggleStyle(.button)
                .help("Favorites only")
                Spacer()
                Text("\(service.items.count) items").foregroundStyle(.secondary).font(.caption)
            }
            .padding(10)
            Divider()
            if service.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(service.isAvailable ? "No captures" : "History unavailable").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(service.items, id: \.id) { r in
                            HistoryCell(record: r, service: service)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct HistoryCell: View {
    let record: CaptureRecord
    let service: HistoryService
    @State private var hover = false

    private var exists: Bool { FileManager.default.fileExists(atPath: record.filePath) }
    private var isImage: Bool { record.kind == .screenshot || record.kind == .scrolling }
    private var url: URL { URL(fileURLWithPath: record.filePath) }

    var body: some View {
        let present = exists
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                if present, let t = record.thumbnailPath, let img = NSImage(contentsOfFile: t) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Image(systemName: present ? (isImage ? "photo" : "film") : "exclamationmark.triangle")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                }
                if present && !isImage {
                    Image(systemName: "play.circle.fill").font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.9)).shadow(radius: 2)
                }
                if hover { hoverButtons(present: present) }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if record.favorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).padding(6)
                }
            }
            HStack {
                Text(present ? Self.relative(record.createdAt) : "File missing")
                    .font(.caption).foregroundStyle(present ? Color.secondary : Color.red)
                Spacer()
                if let ms = record.durationMs { Text(Self.duration(ms)).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(record.title ?? url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if present { HistoryWindow.open(record) } }
        .contextMenu {
            if present {
                Button("Open") { HistoryWindow.open(record) }
                Button("Copy") { HistoryWindow.copy(record) }
                Button("Reveal in Finder") { HistoryWindow.reveal(record) }
                if isImage { Button("Pin to Screen") { PinnedImage.pin(url: url) } }
            } else {
                Button("Remove from History") { service.removeRecordOnly(record) }
            }
            Button(record.favorite ? "Remove Favorite" : "Favorite") { service.toggleFavorite(record) }
            Divider()
            Button("Delete…") { HistoryWindow.confirmDelete(record) }
        }
    }

    @ViewBuilder
    private func hoverButtons(present: Bool) -> some View {
        HStack(spacing: 6) {
            if present {
                btn("arrow.up.forward.app", "Open") { HistoryWindow.open(record) }
                btn("doc.on.doc", "Copy") { HistoryWindow.copy(record) }
                btn("folder", "Reveal in Finder") { HistoryWindow.reveal(record) }
                if isImage { btn("pin", "Pin") { PinnedImage.pin(url: url) } }
            } else {
                btn("xmark.bin", "Remove") { service.removeRecordOnly(record) }
            }
            btn(record.favorite ? "star.fill" : "star", "Favorite") { service.toggleFavorite(record) }
            btn("trash", "Delete") { HistoryWindow.confirmDelete(record) }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(6)
    }

    private func btn(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless).help(help)
    }

    private static func relative(_ unix: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: Date())
    }

    private static func duration(_ ms: UInt64) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
