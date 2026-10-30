import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: "Flipdial")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !DragMonitor.shared.start() {
            DragMonitor.requestAccessibility()
            SettingsWindow.shared.show(tab: .general)
            // Start listening as soon as the user flips the switch in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    if DragMonitor.shared.start() {
                        timer.invalidate()
                        self?.permissionTimer = nil
                        HUD.shared.done("Flipdial is ready", detail: "Drag a file and press ⇧, ⌘ or ⌃")
                    }
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !DragMonitor.shared.isRunning {
            let warn = NSMenuItem(title: "⚠︎ Grant Accessibility Access…", action: #selector(openGeneral), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        for mode in [WheelMode.convert, .tools, .actions] {
            let item = NSMenuItem(title: "\(mode.rawValue) Files…", action: #selector(pickFiles(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if Runner.shared.history.isEmpty {
            submenu.addItem(NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: ""))
        }
        for entry in Runner.shared.history {
            let item = NSMenuItem(title: entry.title, action: #selector(revealEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.outputs
            submenu.addItem(item)
        }
        recent.submenu = submenu
        menu.addItem(recent)

        menu.addItem(.separator())
        let guide = NSMenuItem(title: "How to Use", action: #selector(openGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openGeneral), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Flipdial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func pickFiles(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = WheelMode(rawValue: raw) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        WheelController.shared.show(mode: mode, files: panel.urls, at: NSPoint(x: screen.midX, y: screen.midY))
    }

    @objc private func revealEntry(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func openGeneral() { SettingsWindow.shared.show(tab: .general) }
    @objc private func openGuide() { SettingsWindow.shared.show(tab: .guide) }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let args = Array(CommandLine.arguments.dropFirst())
        if let command = args.first, ["list", "run", "engines"].contains(command) {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await CLI.run(command, Array(args.dropFirst()))) }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// `Flipdial list <files…>` shows every operation; `Flipdial run <operation-id> <files…>` performs one;
/// `Flipdial engines` shows which helper programs were found.
enum CLI {
    @MainActor
    static func run(_ command: String, _ args: [String]) async -> Int32 {
        if command == "engines" {
            for engine in Engine.allCases { print("\(engine.displayName): \(Engines.path(engine)?.path ?? "not found")") }
            return 0
        }
        if command == "list" {
            let urls = args.map { URL(fileURLWithPath: $0) }
            for mode in [WheelMode.convert, .tools, .actions] {
                print("\(mode.rawValue):")
                for op in Catalog.operations(for: urls, mode: mode) {
                    print("  \(op.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(op.title)\(op.unavailableReason.map { "  [\($0)]" } ?? "")")
                }
            }
            return 0
        }
        guard args.count >= 2 else {
            print("usage: Flipdial run <operation-id> <file>…   (see: Flipdial list <file>)")
            return 2
        }
        let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
        let all = [WheelMode.convert, .tools, .actions].flatMap { Catalog.operations(for: urls, mode: $0) }
        guard let op = all.first(where: { $0.id == args[0] }) else {
            FileHandle.standardError.write("No operation \(args[0]) for these files\n".data(using: .utf8)!)
            return 2
        }
        if let reason = op.unavailableReason {
            FileHandle.standardError.write("\(reason)\n".data(using: .utf8)!)
            return 1
        }
        do {
            let result = try await op.perform(urls)
            result.outputs.forEach { print($0.path) }
            if let message = result.message { print(message) }
            return 0
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }
}
