import AppKit
import SwiftUI

/// A window for picking the part of an image to keep. Returns the selection normalised to 0…1
/// with the origin at the top-left, or nil if cancelled.
@MainActor
enum CropWindow {
    private static var window: NSWindow?

    static func ask(image: CGImage, title: String) async -> CGRect? {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: (CGRect?) -> Void = { result in
                guard !finished else { return }
                finished = true
                window?.orderOut(nil)
                window = nil
                continuation.resume(returning: result)
            }

            let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
            let maxSize = CGSize(width: min(1000, screen.width * 0.8), height: min(700, screen.height * 0.75))
            let scale = min(maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height), 1)
            let canvas = CGSize(width: max(360, CGFloat(image.width) * scale), height: max(240, CGFloat(image.height) * scale))

            let w = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: canvas.width + 40, height: canvas.height + 110)),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Crop — \(title)"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: CropView(image: image, onDone: finish))
            w.center()
            window = w
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { finish(nil) }
            }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }
}

private enum Aspect: String, CaseIterable, Identifiable {
    case free = "Free", original = "Original", square = "1:1", fourThree = "4:3", threeTwo = "3:2", wide = "16:9", tall = "9:16"
    var id: String { rawValue }

    func ratio(imageWidth: CGFloat, imageHeight: CGFloat) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageWidth / imageHeight
        case .square: return 1
        case .fourThree: return 4 / 3
        case .threeTwo: return 3 / 2
        case .wide: return 16 / 9
        case .tall: return 9 / 16
        }
    }
}

private struct CropView: View {
    let image: CGImage
    let onDone: (CGRect?) -> Void

    /// Selection in normalised image coordinates, origin top-left.
    @State private var selection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var aspect: Aspect = .free
    @State private var drag: DragKind? = nil
    @State private var dragStart = CGRect.zero

    private enum DragKind: Equatable { case move, create(CGPoint), handle(Int) }

    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    overlay(frame: frame)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(frame: frame))
            }
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 12) {
                Picker("Aspect", selection: $aspect) {
                    ForEach(Aspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .onChange(of: aspect) { applyAspect() }

                Text("\(Int(selection.width * imageSize.width)) × \(Int(selection.height * imageSize.height)) px")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { aspect = .free; selection = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Crop") { onDone(selection) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 360)
    }

    // MARK: Geometry

    private func fittedFrame(in size: CGSize) -> CGRect {
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func toView(_ r: CGRect, _ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
               width: r.width * frame.width, height: r.height * frame.height)
    }

    private func toNormal(_ p: CGPoint, _ frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - frame.minX) / frame.width, 0), 1), y: min(max((p.y - frame.minY) / frame.height, 0), 1))
    }

    /// Aspect ratio expressed in normalised units (width / height of the selection rect).
    private var normalRatio: CGFloat? {
        aspect.ratio(imageWidth: imageSize.width, imageHeight: imageSize.height).map { $0 * imageSize.height / imageSize.width }
    }

    /// Handle positions: corners 0–3 (TL, TR, BR, BL), then edges 4–7 (T, R, B, L).
    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    // MARK: Drawing

    @ViewBuilder
    private func overlay(frame: CGRect) -> some View {
        let r = toView(selection, frame)
        Path { p in
            p.addRect(frame)
            p.addRect(r)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

        Path { p in
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)

        Rectangle().path(in: r).stroke(Color.white, lineWidth: 1.5)

        ForEach(Array(handles(r).enumerated()), id: \.offset) { i, point in
            if i < 4 || normalRatio == nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: i < 4 ? 12 : 9, height: i < 4 ? 12 : 9)
                    .shadow(radius: 1)
                    .position(point)
            }
        }
    }

    // MARK: Interaction

    private func dragGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if drag == nil {
                    let viewRect = toView(selection, frame)
                    if let i = handles(viewRect).firstIndex(where: { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) < 14 }),
                       i < 4 || normalRatio == nil {
                        drag = .handle(i)
                    } else if viewRect.contains(value.startLocation) {
                        drag = .move
                    } else {
                        drag = .create(toNormal(value.startLocation, frame))
                    }
                    dragStart = selection
                }
                let current = toNormal(value.location, frame)
                switch drag {
                case .move:
                    let dx = value.translation.width / frame.width, dy = value.translation.height / frame.height
                    var r = dragStart.offsetBy(dx: dx, dy: dy)
                    r.origin.x = min(max(r.minX, 0), 1 - r.width)
                    r.origin.y = min(max(r.minY, 0), 1 - r.height)
                    selection = r
                case .create(let anchor):
                    selection = constrained(anchor: anchor, to: current)
                case .handle(let i):
                    selection = resized(dragStart, handle: i, to: current)
                case nil:
                    break
                }
            }
            .onEnded { _ in drag = nil }
    }

    /// A rectangle from a fixed corner to the pointer, honouring the aspect ratio.
    private func constrained(anchor: CGPoint, to point: CGPoint) -> CGRect {
        var w = point.x - anchor.x, h = point.y - anchor.y
        if let ratio = normalRatio {
            let width = max(abs(w), abs(h) * ratio)
            w = width * (w < 0 ? -1 : 1)
            h = width / ratio * (h < 0 ? -1 : 1)
            // Shrink to stay inside the image.
            let maxW = w < 0 ? anchor.x : 1 - anchor.x, maxH = h < 0 ? anchor.y : 1 - anchor.y
            let fit = min(1, maxW / max(abs(w), 0.0001), maxH / max(abs(h), 0.0001))
            w *= fit; h *= fit
        }
        let r = CGRect(x: min(anchor.x, anchor.x + w), y: min(anchor.y, anchor.y + h), width: abs(w), height: abs(h))
        return r.width < 0.01 || r.height < 0.01 ? selection : r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func resized(_ r: CGRect, handle i: Int, to p: CGPoint) -> CGRect {
        if i < 4 {
            // Drag a corner: the opposite corner stays put.
            let opposite = handles(r)[(i + 2) % 4]
            return constrained(anchor: opposite, to: p)
        }
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch i {
        case 4: minY = min(p.y, maxY - 0.02)
        case 5: maxX = max(p.x, minX + 0.02)
        case 6: maxY = max(p.y, minY + 0.02)
        default: minX = min(p.x, maxX - 0.02)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func applyAspect() {
        guard let ratio = normalRatio else { return }
        // Largest rectangle of that ratio centred on the current selection.
        var w = selection.width, h = w / ratio
        if h > selection.height { h = selection.height; w = h * ratio }
        if w > 1 { w = 1; h = w / ratio }
        if h > 1 { h = 1; w = h * ratio }
        var x = selection.midX - w / 2, y = selection.midY - h / 2
        x = min(max(x, 0), 1 - w); y = min(max(y, 0), 1 - h)
        selection = CGRect(x: x, y: y, width: w, height: h)
    }
}
