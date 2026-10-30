import AppKit
import SwiftUI

/// Floating status pill at the bottom of the screen: progress, results and errors.
@MainActor
final class HUD {
    static let shared = HUD()

    enum State: Equatable {
        case working(String)
        case done(String, detail: String?, outputs: [URL])
        case failed(String)
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func working(_ title: String) { show(.working(title), hideAfter: nil) }

    func done(_ title: String, detail: String? = nil, outputs: [URL] = []) {
        show(.done(title, detail: detail, outputs: outputs), hideAfter: detail != nil && detail!.count > 60 ? 8 : 4)
    }

    func failed(_ message: String) { show(.failed(message), hideAfter: 7) }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func show(_ state: State, hideAfter seconds: Double?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh hosting view sizes itself to the new content immediately.
        panel.contentView = NSHostingView(rootView: HUDView(state: state, hud: self))
        let size = panel.contentView!.fittingSize
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 60, width: size.width, height: size.height),
                           display: true)
        }
        panel.orderFrontRegardless()
        hideTask?.cancel()
        if let seconds {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct HUDView: View {
    let state: HUD.State
    let hud: HUD

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch state {
            case .working(let title):
                ProgressView().controlSize(.small)
                Text(title).font(.system(size: 13, weight: .medium))
            case .done(let title, let detail, let outputs):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 11, design: detail.contains("  ") ? .monospaced : .default))
                            .foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                    }
                }
                if !outputs.isEmpty {
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting(outputs)
                        hud.hide()
                    }
                    .controlSize(.small)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 18))
                Text(message).font(.system(size: 12)).lineLimit(5).frame(maxWidth: 420, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .onTapGesture { if case .failed = state { hud.hide() } }
    }
}

/// Runs operations off the main thread and reports through the HUD.
@MainActor
final class Runner: ObservableObject {
    static let shared = Runner()

    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let outputs: [URL]
        let date = Date()
    }

    @Published private(set) var history: [Entry] = []

    func run(_ op: FileOperation, on urls: [URL], mode: WheelMode) {
        guard let first = urls.first else { return }
        if let reason = op.unavailableReason {
            HUD.shared.failed(reason)
            return
        }
        let subject = urls.count == 1 ? first.lastPathComponent : "\(urls.count) files"
        let verb = mode == .convert ? "Converting \(subject) to \(op.title)" : "\(op.title) — \(subject)"
        // Actions are instant; only show progress for real work.
        if mode != .actions { HUD.shared.working(verb + "…") }

        Task.detached(priority: .userInitiated) {
            do {
                let result = try await op.perform(urls)
                await MainActor.run { self.finish(op, mode: mode, result: result) }
            } catch is CancellationError {
                await MainActor.run { HUD.shared.hide() }
            } catch {
                await MainActor.run {
                    HUD.shared.failed(error.localizedDescription)
                    NSSound(named: "Basso")?.play()
                }
            }
        }
    }

    private func finish(_ op: FileOperation, mode: WheelMode, result: OperationResult) {
        if result.copiedText, let message = result.message {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
        }
        if !result.outputs.isEmpty {
            Prefs.conversionCount += 1
            history.insert(Entry(title: result.outputs.count == 1 ? result.outputs[0].lastPathComponent
                                    : "\(op.title) · \(result.outputs.count) files", outputs: result.outputs), at: 0)
            if history.count > 15 { history.removeLast() }
            if Prefs.revealWhenDone && mode != .actions { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
        }

        if mode == .actions && result.message == nil && result.outputs.isEmpty {
            HUD.shared.hide()
            return
        }
        let title: String
        if let message = result.message, result.outputs.isEmpty {
            title = result.copiedText ? "\(op.title) copied" : op.title
            HUD.shared.done(title, detail: message)
        } else {
            title = result.outputs.count == 1 ? "Saved \(result.outputs[0].lastPathComponent)" : "Saved \(result.outputs.count) files"
            HUD.shared.done(title, detail: result.message, outputs: result.outputs)
        }
        if Prefs.playSound && mode != .actions { NSSound(named: "Glass")?.play() }
    }
}
