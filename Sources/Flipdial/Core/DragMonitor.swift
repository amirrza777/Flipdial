import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "dev.amirguliyev.flipdial", category: "drag")

/// Watches system-wide input with a CGEventTap. While files are being dragged anywhere, pressing
/// ⇧/⌘/⌃ opens the wheel; while the wheel is open, arrow/return/escape keys drive it and are
/// swallowed so they don't reach the app underneath.
@MainActor
final class DragMonitor {
    static let shared = DragMonitor()

    private var tap: CFMachPort?
    private var dragPasteboardCount = 0
    private var draggedFiles: [URL]? = nil
    private var mouseIsDown = false

    /// Marks events Flipdial posts itself so the tap lets them through untouched.
    private static let syntheticMarker: Int64 = 0x5A75_5A75

    var isRunning: Bool { tap != nil }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: eventTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.debug("event tap creation failed (trusted=\(AXIsProcessTrusted()))")
            return false
        }
        log.notice("event tap started")
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }
        let wheel = WheelController.shared

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.notice("tap disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .leftMouseDown:
            mouseIsDown = true
            draggedFiles = nil
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
            if wheel.isOpen && !wheel.contains(NSEvent.mouseLocation) { wheel.close() }

        case .leftMouseDragged:
            // A new drag session rewrites the drag pasteboard; that's how we know files are in flight.
            if draggedFiles == nil {
                let board = NSPasteboard(name: .drag)
                if board.changeCount != dragPasteboardCount {
                    dragPasteboardCount = board.changeCount
                    let urls = board.readObjects(forClasses: [NSURL.self],
                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                    draggedFiles = urls.isEmpty ? nil : urls
                }
            }

        case .leftMouseUp:
            mouseIsDown = false
            draggedFiles = nil

        case .flagsChanged:
            guard let mode = Self.mode(for: event.flags) else { break }
            if let files = draggedFiles, mouseIsDown, !wheel.isOpen {
                wheel.show(mode: mode, files: files)
            } else if wheel.isOpen {
                wheel.switchMode(mode)
            }

        case .keyDown:
            guard wheel.isOpen else { break }
            let dragging = mouseIsDown && draggedFiles != nil
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 123, 126: wheel.move(-1); return nil              // ← ↑
            case 124, 125: wheel.move(1); return nil               // → ↓
            case 48: wheel.cycleMode(); return nil                 // tab
            case 36, 76:                                           // return, enter
                wheel.confirm()
                if dragging { cancelSystemDrag() }
                return nil
            case 53:                                               // escape
                wheel.close()
                return dragging ? pass : nil                       // let Esc also cancel the drag
            default:
                return nil                                         // keep stray keys away from other apps
            }

        default:
            break
        }
        return pass
    }

    private static func mode(for flags: CGEventFlags) -> WheelMode? {
        if flags.contains(.maskShift) { return .convert }
        if flags.contains(.maskCommand) { return .tools }
        if flags.contains(.maskControl) { return .actions }
        return nil
    }

    /// Posts Escape so the file the user is holding slides back instead of being dropped somewhere.
    private func cancelSystemDrag() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) else { continue }
            key.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            key.post(tap: .cgSessionEventTap)
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<DragMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { monitor.handle(type, event) }
}
