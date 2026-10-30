import AppKit
import Quartz

/// File actions shown on the ⌃ wheel. These act on the files themselves rather than producing new ones.
enum Actions {
    static func all(_ urls: [URL]) -> [FileOperation] {
        [
            op("airdrop", "AirDrop", "airplayaudio") { urls in
                NSApp.activate(ignoringOtherApps: true)
                guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                    throw FlipdialError("AirDrop isn't available right now")
                }
                service.perform(withItems: urls)
                return OperationResult()
            },
            op("float", "Float", "pin") { urls in
                urls.forEach(FloatWindow.show)
                return OperationResult()
            },
            op("copy", "Copy", "doc.on.doc") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                return OperationResult(message: urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) files")
            },
            op("move", "Move To…", "folder") { urls in
                NSApp.activate(ignoringOtherApps: true)
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Move Here"
                panel.message = "Move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to…"
                guard panel.runModal() == .OK, let folder = panel.url else { throw CancellationError() }
                var moved: [URL] = []
                for url in urls {
                    let dest = Output.unique(folder.appendingPathComponent(url.lastPathComponent))
                    try FileManager.default.moveItem(at: url, to: dest)
                    moved.append(dest)
                }
                return OperationResult(outputs: moved)
            },
            op("path", "Copy Path", "link") { urls in
                let text = urls.map(\.path).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return OperationResult(message: urls.count == 1 ? text : "Copied \(urls.count) paths")
            },
            op("terminal", "Terminal", "terminal") { urls in
                let folders = Set(urls.map { $0.isDirectory ? $0 : $0.deletingLastPathComponent() })
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    throw FlipdialError("Terminal not found")
                }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                try await NSWorkspace.shared.open(Array(folders), withApplicationAt: terminal, configuration: config)
                return OperationResult()
            },
            op("reveal", "Reveal", "magnifyingglass") { urls in
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                return OperationResult()
            },
            op("duplicate", "Duplicate", "plus.square.on.square") { urls in
                var copies: [URL] = []
                for url in urls {
                    let base = Output.baseName(url) + " copy"
                    var dest = url.deletingLastPathComponent().appendingPathComponent(base)
                    if !url.pathExtension.isEmpty { dest.appendPathExtension(url.pathExtension) }
                    dest = Output.unique(dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                    copies.append(dest)
                }
                return OperationResult(outputs: copies)
            },
        ]
    }

    private static func op(_ id: String, _ title: String, _ symbol: String,
                           _ body: @escaping @MainActor ([URL]) async throws -> OperationResult) -> FileOperation {
        FileOperation(id: "action.\(id)", title: title, symbol: symbol) { urls in try await body(urls) }
    }
}

/// An always-on-top Quick Look window, handy for keeping a reference image or PDF in view.
@MainActor
enum FloatWindow {
    private static var windows: [NSPanel] = []

    static func show(_ url: URL) {
        let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 420, height: 320), style: .normal)!
        preview.previewItem = url as NSURL
        preview.autostarts = true

        var size = NSSize(width: 420, height: 320)
        if let image = NSImage(contentsOf: url), image.size.width > 0 {
            let scale = min(520 / image.size.width, 520 / image.size.height, 1)
            size = NSSize(width: max(200, image.size.width * scale), height: max(150, image.size.height * scale))
        }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = url.lastPathComponent
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = preview
        let mouse = NSEvent.mouseLocation
        panel.setFrameTopLeftPoint(NSPoint(x: mouse.x + 20, y: mouse.y - 20))
        panel.orderFrontRegardless()
        windows.append(panel)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { note in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === note.object as? NSPanel }
            }
        }
    }
}

/// Small modal form for tools that need a value (trim times, page ranges, passwords).
enum Prompt {
    struct Field {
        let label: String
        let placeholder: String
        var secure = false
    }

    @MainActor
    static func ask(title: String, message: String, fields: [Field]) async -> [String]? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let inputs: [NSTextField] = fields.map { field in
            let input = field.secure ? NSSecureTextField() : NSTextField()
            input.placeholderString = field.placeholder
            input.translatesAutoresizingMaskIntoConstraints = false
            input.widthAnchor.constraint(equalToConstant: 200).isActive = true
            return input
        }
        let grid = NSGridView(views: zip(fields, inputs).map { [NSTextField(labelWithString: $0.label + ":"), $1] })
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(fields.count) * 30)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = inputs.first

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
    }
}
