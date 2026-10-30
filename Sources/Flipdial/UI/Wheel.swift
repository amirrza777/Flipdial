import AppKit
import SwiftUI

@MainActor
final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var files: [URL] = []
    @Published var operations: [FileOperation] = []
    @Published var selected: Int? = nil

    var radius: CGFloat { min(172, max(124, CGFloat(operations.count) * 12.5)) }

    var selectedOperation: FileOperation? {
        selected.flatMap { operations.indices.contains($0) ? operations[$0] : nil }
    }

    func reload() {
        operations = Catalog.operations(for: files, mode: mode)
        selected = operations.firstIndex(where: \.isAvailable) ?? (operations.isEmpty ? nil : 0)
    }

    /// Angle of item `i`, starting at 12 o'clock and going clockwise.
    func angle(of i: Int) -> Double {
        -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(operations.count, 1))
    }

    /// Item under an offset from the wheel centre (y up), or nil inside the hub.
    func index(atOffset dx: CGFloat, _ dy: CGFloat) -> Int? {
        guard !operations.isEmpty, hypot(dx, dy) > 62 else { return nil }
        var theta = atan2(-Double(dy), Double(dx)) + Double.pi / 2   // clockwise from top
        if theta < 0 { theta += 2 * Double.pi }
        let step = 2 * Double.pi / Double(operations.count)
        return Int((theta / step).rounded()) % operations.count
    }
}

@MainActor
final class WheelController {
    static let shared = WheelController()

    let model = WheelModel()
    private var panel: NSPanel?
    private(set) var isOpen = false
    private let side: CGFloat = 520

    func show(mode: WheelMode, files: [URL], at point: NSPoint? = nil) {
        model.files = files
        model.mode = mode
        model.reload()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !isOpen {
            let center = point ?? NSEvent.mouseLocation
            var origin = NSPoint(x: center.x - side / 2, y: center.y - side / 2)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                let f = screen.visibleFrame
                origin.x = min(max(origin.x, f.minX), f.maxX - side)
                origin.y = min(max(origin.y, f.minY), f.maxY - side)
            }
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        isOpen = true
    }

    func switchMode(_ mode: WheelMode) {
        guard isOpen, mode != model.mode else { return }
        model.mode = mode
        model.reload()
    }

    func cycleMode() {
        let order: [WheelMode] = [.convert, .tools, .actions]
        switchMode(order[(order.firstIndex(of: model.mode)! + 1) % order.count])
    }

    func move(_ delta: Int) {
        let n = model.operations.count
        guard n > 0 else { return }
        model.selected = ((model.selected ?? 0) + delta + n) % n
    }

    func select(at screenPoint: NSPoint) {
        guard let frame = panel?.frame else { return }
        model.selected = model.index(atOffset: screenPoint.x - frame.midX, screenPoint.y - frame.midY) ?? model.selected
    }

    func contains(_ screenPoint: NSPoint) -> Bool {
        guard isOpen, let frame = panel?.frame else { return false }
        return hypot(screenPoint.x - frame.midX, screenPoint.y - frame.midY) < model.radius + 64
    }

    func isOverHub(_ screenPoint: NSPoint) -> Bool {
        guard let frame = panel?.frame else { return true }
        return model.index(atOffset: screenPoint.x - frame.midX, screenPoint.y - frame.midY) == nil
    }

    func confirm() {
        guard let op = model.selectedOperation else { close(); return }
        let files = model.files, mode = model.mode
        close()
        Runner.shared.run(op, on: files, mode: mode)
    }

    func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if !self.isOpen { panel.orderOut(nil) } }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.becomesKeyOnlyIfNeeded = true
        let host = WheelHostView(frame: NSRect(x: 0, y: 0, width: side, height: side), controller: self)
        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.frame = host.bounds
        hosting.autoresizingMask = [.width, .height]
        host.addSubview(hosting)
        panel.contentView = host
        return panel
    }
}

/// Accepts the in-flight file drag: hovering picks a segment, dropping on it runs the operation.
/// Being the drop target also stops Finder from moving the file somewhere by accident.
final class WheelHostView: NSView {
    private unowned let controller: WheelController

    init(frame: NSRect, controller: WheelController) {
        self.controller = controller
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the round wheel is clickable; the transparent corners pass clicks through.
        let local = convert(point, from: superview)
        let r = MainActor.assumeIsolated { controller.model.radius } + 64
        return hypot(local.x - bounds.midX, local.y - bounds.midY) < r ? self : nil
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            let screen = window?.convertPoint(toScreen: sender.draggingLocation) ?? .zero
            controller.select(at: screen)
        }
        return .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            let screen = window?.convertPoint(toScreen: sender.draggingLocation) ?? .zero
            // Dropping on the hub cancels; the file springs back to where it came from.
            if controller.isOverHub(screen) { controller.close(); return false }
            controller.select(at: screen)
            controller.confirm()
            return true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated {
            let p = NSEvent.mouseLocation
            if !controller.isOverHub(p) { controller.select(at: p) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            let p = NSEvent.mouseLocation
            if controller.isOverHub(p) { controller.close() } else { controller.select(at: p); controller.confirm() }
        }
    }
}

// MARK: - SwiftUI

private let accent = Color(red: 1.0, green: 0.357, blue: 0.161)   // #FF5B29, the logo orange

struct WheelView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let r = model.radius
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .frame(width: (r + 64) * 2, height: (r + 64) * 2)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 6)

            ForEach(Array(model.operations.enumerated()), id: \.element.id) { i, op in
                let a = model.angle(of: i)
                WheelItem(op: op, selected: model.selected == i)
                    .offset(x: CGFloat(cos(a)) * r, y: CGFloat(sin(a)) * r)
            }

            hub
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: model.selected)
        .animation(.easeOut(duration: 0.15), value: model.mode)
    }

    private var hub: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach([WheelMode.convert, .tools, .actions], id: \.self) { mode in
                    Text(mode.shortcut)
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 18)
                        .background(model.mode == mode ? accent : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(model.mode == mode ? .white : .secondary)
                }
            }
            Text(model.mode.rawValue).font(.system(size: 14, weight: .bold))
            Text(model.files.count == 1 ? model.files[0].lastPathComponent : "\(model.files.count) files")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Group {
                if let op = model.selectedOperation, let reason = op.unavailableReason {
                    Text(reason).foregroundStyle(.orange)
                } else if model.operations.isEmpty {
                    Text("Nothing here for this file").foregroundStyle(.secondary)
                } else {
                    Text("← → choose\n⏎ apply · esc").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
        }
        .frame(width: 100)
        .background(Circle().fill(.background.opacity(0.55)).frame(width: 140, height: 140))
    }
}

private struct WheelItem: View {
    let op: FileOperation
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: op.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Circle().fill(selected ? accent : Color.primary.opacity(0.07)))
                .foregroundStyle(selected ? .white : .primary)
            // Fixed width with wrapping keeps long names inside the ring.
            Text(op.title)
                .font(.system(size: 10, weight: selected ? .bold : .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(width: 72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 72, height: 66, alignment: .top)
        .opacity(op.isAvailable ? 1 : 0.38)
        .scaleEffect(selected ? 1.1 : 1)
    }
}
