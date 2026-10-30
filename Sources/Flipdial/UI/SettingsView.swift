import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(tab: SettingsView.Tab = .general) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Flipdial"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.contentView = NSHostingView(rootView: SettingsView(tab: tab))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    enum Tab: Hashable { case general, guide, quality, engines }
    @State var tab: Tab

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            GuidePane().tabItem { Label("How to Use", systemImage: "hand.draw") }.tag(Tab.guide)
            QualityPane().tabItem { Label("Quality", systemImage: "slider.horizontal.3") }.tag(Tab.quality)
            EnginesPane().tabItem { Label("Formats", systemImage: "puzzlepiece.extension") }.tag(Tab.engines)
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }
}

private struct GeneralPane: View {
    @State private var trusted = DragMonitor.hasAccessibility
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var reveal = Prefs.revealWhenDone
    @State private var sound = Prefs.playSound
    @State private var folder = Prefs.customOutputFolder
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permission") {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(trusted ? "Accessibility access granted" : "Accessibility access needed")
                        Text("Lets Flipdial notice ⇧ ⌘ ⌃ while you drag files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !trusted {
                        Button("Grant Access…") {
                            DragMonitor.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            Section("Output") {
                HStack {
                    Text("Save results")
                    Spacer()
                    Text(folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Next to the original")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK { folder = panel.url; Prefs.customOutputFolder = panel.url }
                    }
                    if folder != nil {
                        Button("Reset") { folder = nil; Prefs.customOutputFolder = nil }
                    }
                }
                Toggle("Reveal results in Finder", isOn: $reveal).onChange(of: reveal) { _, value in Prefs.revealWhenDone = value }
                Toggle("Play a sound when done", isOn: $sound).onChange(of: sound) { _, value in Prefs.playSound = value }
            }
            Section("Startup") {
                Toggle("Open Flipdial at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        HUD.shared.failed("Couldn't change login item: \(error.localizedDescription)")
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            let now = DragMonitor.hasAccessibility
            if now != trusted {
                trusted = now
                if now { DragMonitor.shared.start() }
            }
        }
    }
}

private struct GuidePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Start dragging any file, then press a key without letting go.")
                .font(.headline)
            row("⇧", "Shift", "Convert", "Turn the file into another format: images, video, audio, documents, PDFs, slides, spreadsheets, subtitles and archives.")
            row("⌘", "Command", "Tools", "Compress, resize, rotate, trim, merge, split, protect, remove backgrounds and more.")
            row("⌃", "Control", "Actions", "AirDrop, float on top, copy, move, copy path, open in Terminal.")
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Use ← → to pick, ⏎ to apply, Esc to cancel. Tab switches wheels.", systemImage: "keyboard")
                Label("Or drop the file onto a slice of the wheel.", systemImage: "cursorarrow.and.square.on.square.dashed")
                Label("Results are saved next to the original. Nothing leaves your Mac.", systemImage: "lock.shield")
            }
            .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func row(_ key: String, _ name: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(key).font(.system(size: 20, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) → \(title)").font(.system(size: 13, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct QualityPane: View {
    @State private var quality = Prefs.imageQuality
    @State private var dpi = Prefs.pdfDPI
    @State private var metadata = Prefs.keepMetadata

    var body: some View {
        Form {
            Section("Images") {
                VStack(alignment: .leading) {
                    Slider(value: $quality, in: 0.3...1, step: 0.05) { Text("JPG / HEIC / WebP quality") }
                        .onChange(of: quality) { _, value in Prefs.imageQuality = value }
                    Text("\(Int(quality * 100))%").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep photo metadata (EXIF, GPS) when converting", isOn: $metadata)
                    .onChange(of: metadata) { _, value in Prefs.keepMetadata = value }
            }
            Section("PDF pages to images") {
                Picker("Resolution", selection: $dpi) {
                    Text("150 DPI").tag(150.0)
                    Text("300 DPI").tag(300.0)
                    Text("600 DPI").tag(600.0)
                }
                .onChange(of: dpi) { _, value in Prefs.pdfDPI = value }
            }
        }
        .formStyle(.grouped)
    }
}

private struct EnginesPane: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                row(ok: true, title: "Images, PDF, Word, RTF, HTML, ODT", detail: "Including OCR and background removal")
                row(ok: true, title: "Markdown, EPUB, Excel, ODS, CSV", detail: "Read and written natively")
                row(ok: true, title: "Subtitles and archives", detail: "SRT, VTT, ZIP, TAR, GZ, RAR, 7z")
                engine(.ffmpeg, installedText: "Included")
            } header: {
                Text("Built in")
            }
            Section {
                engine(.soffice, installedText: "Installed")
                engine(.pandoc, installedText: "Installed")
            } header: {
                Text("Optional (free)")
            } footer: {
                Text("Flipdial finds these automatically once they're installed.")
            }
            Button("Check Again") { Engines.refresh(); refresh += 1 }
        }
        .formStyle(.grouped)
        .id(refresh)
    }

    private func row(ok: Bool, title: String, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func engine(_ engine: Engine, installedText: String) -> some View {
        let installed = Engines.has(engine)
        return HStack {
            row(ok: installed, title: engine.displayName, detail: engine.purpose)
            Spacer()
            if installed {
                Text(installedText).font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Download") { NSWorkspace.shared.open(engine.downloadURL) }
            }
        }
    }
}
