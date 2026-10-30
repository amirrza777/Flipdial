import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ImageKit {
    static let utTypes: [String: String] = [
        "jpg": "public.jpeg", "jpeg": "public.jpeg", "png": "public.png", "heic": "public.heic",
        "heif": "public.heif", "tiff": "public.tiff", "tif": "public.tiff", "bmp": "com.microsoft.bmp",
        "gif": "com.compuserve.gif", "webp": "org.webmproject.webp", "avif": "public.avif",
        "ico": "com.microsoft.ico", "icns": "com.apple.icns", "jp2": "public.jpeg-2000",
    ]

    private static let writable: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    static func canWriteNatively(_ ext: String) -> Bool {
        guard let uti = utTypes[ext] else { return false }
        return writable.contains(uti)
    }

    static func canWrite(_ ext: String) -> Bool {
        if canWriteNatively(ext) { return true }
        switch ext {
        case "webp": return Engines.has(.cwebp) || Engines.has(.ffmpeg)
        case "avif": return Engines.has(.ffmpeg)
        default: return false
        }
    }

    // MARK: Loading

    struct Loaded {
        let image: CGImage
        let properties: [CFString: Any]
    }

    /// Loads the first frame with EXIF orientation already applied to the pixels.
    static func load(_ url: URL) throws -> Loaded {
        if url.ext == "svg" || url.ext == "pdf" {
            guard let ns = NSImage(contentsOf: url) else { throw FlipdialError("Can't read \(url.lastPathComponent)") }
            // Render vectors at 2x for crisp output.
            var rect = CGRect(origin: .zero, size: CGSize(width: ns.size.width * 2, height: ns.size.height * 2))
            guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw FlipdialError("Can't render \(url.lastPathComponent)")
            }
            return Loaded(image: cg, properties: [:])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FlipdialError("Can't read \(url.lastPathComponent)")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FlipdialError("Can't decode \(url.lastPathComponent)")
        }
        var cleaned = props
        cleaned[kCGImagePropertyOrientation] = 1
        cleaned[kCGImagePropertyPixelWidth] = nil
        cleaned[kCGImagePropertyPixelHeight] = nil
        if var tiff = cleaned[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            cleaned[kCGImagePropertyTIFFDictionary] = tiff
        }
        return Loaded(image: image, properties: cleaned)
    }

    // MARK: Saving

    /// Writes `image` in the format given by `ext`, using ImageIO or an external encoder.
    static func save(_ image: CGImage, to url: URL, ext: String, quality: Double? = nil,
                     properties: [CFString: Any] = [:]) async throws {
        var image = image
        if ["jpg", "jpeg", "bmp"].contains(ext) { image = flattened(image) }
        if ext == "icns" { return try await icns(squared(image, side: 1024), to: url) }
        if ext == "ico" { image = squared(image, side: 256) }
        let q = quality ?? Prefs.imageQuality

        if canWriteNatively(ext), let uti = utTypes[ext] {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
                throw FlipdialError("Can't create \(ext.uppercased()) file")
            }
            var props = properties
            props[kCGImageDestinationLossyCompressionQuality] = q
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw FlipdialError("Failed to write \(url.lastPathComponent)") }
            return
        }

        try await Temp.with { dir in
            let png = dir.appendingPathComponent("frame.png")
            try await save(image, to: png, ext: "png")
            switch ext {
            case "webp":
                if let cwebp = Engines.path(.cwebp) {
                    try await Shell.run(cwebp, ["-quiet", "-metadata", "icc", "-q", String(Int(q * 100)), png.path, "-o", url.path])
                } else {
                    try await MediaKit.ffmpeg(["-i", png.path, "-c:v", "libwebp", "-quality", String(Int(q * 100)), url.path])
                }
            case "avif":
                // Only reached on systems whose ImageIO can't write AVIF.
                try await MediaKit.ffmpeg(["-i", png.path, "-c:v", "libsvtav1", "-frames:v", "1", "-pix_fmt", "yuv420p",
                                           "-crf", String(Int((1 - q) * 40 + 20)), "-svtav1-params", "loglevel=0", url.path])
            default:
                throw FlipdialError("Can't write \(ext.uppercased()) images")
            }
        }
    }

    /// Builds a full iconset (16–1024 px) and packs it with Apple's iconutil.
    private static func icns(_ image: CGImage, to url: URL) async throws {
        try await Temp.with { dir in
            let set = dir.appendingPathComponent("icon.iconset")
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            for side in [16, 32, 128, 256, 512] {
                try await save(resized(image, scale: Double(side) / 1024), to: set.appendingPathComponent("icon_\(side)x\(side).png"), ext: "png")
                try await save(resized(image, scale: Double(side * 2) / 1024), to: set.appendingPathComponent("icon_\(side)x\(side)@2x.png"), ext: "png")
            }
            try await Shell.run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", url.path])
        }
    }

    // MARK: Conversions

    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let loaded = try load(src)
        let out = Output.url(for: src, ext: ext)
        try await save(loaded.image, to: out, ext: ext, properties: Prefs.keepMetadata ? loaded.properties : [:])
        return out
    }

    static func pdf(from urls: [URL], output: URL) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            let loaded = try load(url)
            let dpi = loaded.properties[kCGImagePropertyDPIWidth] as? Double ?? 72
            let scale = 72 / max(dpi, 72)
            let size = NSSize(width: Double(loaded.image.width) * scale, height: Double(loaded.image.height) * scale)
            guard let page = PDFPage(image: NSImage(cgImage: loaded.image, size: size)) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0, doc.write(to: output) else { throw FlipdialError("Couldn't build the PDF") }
        return output
    }

    static func toDocx(_ src: URL) throws -> URL {
        let image = flattened(try load(src).image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw FlipdialError("Couldn't encode the image")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        let out = Output.url(for: src, ext: "docx")
        try DOCXWriter.write([TextBlock(kind: .image, runs: [], image: (data as Data, image.width, image.height))], to: out)
        return out
    }

    // MARK: OCR

    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func ocr(_ src: URL) throws -> URL {
        let text = try recognizeText(in: load(src).image)
        guard !text.isEmpty else { throw FlipdialError("No text found in \(src.lastPathComponent)") }
        let out = Output.url(for: src, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    // MARK: Pixel operations

    static func context(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func flattened(_ image: CGImage) -> CGImage {
        guard let ctx = context(width: image.width, height: image.height, opaque: true) else { return image }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func squared(_ image: CGImage, side: Int) -> CGImage {
        guard let ctx = context(width: side, height: side) else { return image }
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage {
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = context(width: w, height: h) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func fitted(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        return longest <= maxSide ? image : resized(image, scale: Double(maxSide) / Double(longest))
    }

    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage {
        guard let ctx = context(width: image.height, height: image.width) else { return image }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(image.width))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(image.height), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func flipped(_ image: CGImage) -> CGImage {
        guard let ctx = context(width: image.width, height: image.height) else { return image }
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// `rect` is in pixels with the origin at the top-left, as the crop window reports it.
    static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage {
        image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) ?? image
    }

    static func croppedSquare(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return image.cropping(to: rect) ?? image
    }

    static func grayscale(_ image: CGImage) -> CGImage {
        let ci = CIImage(cgImage: image).applyingFilter("CIPhotoEffectMono")
        return CIContext().createCGImage(ci, from: ci.extent) ?? image
    }

    static func removingBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first else { throw FlipdialError("No subject found") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw FlipdialError("Couldn't render the cut-out") }
        return cg
    }

    /// Applies a pixel transform and saves next to the source, keeping its format when possible.
    static func transform(_ src: URL, suffix: String, forceExt: String? = nil, quality: Double? = nil,
                          keepProperties: Bool = true, _ body: (CGImage) throws -> CGImage) async throws -> URL {
        let loaded = try load(src)
        let ext = forceExt ?? (canWrite(src.ext) && src.ext != "svg" ? src.ext : "png")
        let out = Output.url(for: src, ext: ext, suffix: suffix)
        try await save(try body(loaded.image), to: out, ext: ext, quality: quality,
                       properties: keepProperties && Prefs.keepMetadata ? loaded.properties : [:])
        return out
    }

    static func stripMetadata(_ src: URL) async throws -> URL {
        let loaded = try load(src)
        let ext = canWrite(src.ext) ? src.ext : "png"
        let out = Output.url(for: src, ext: ext, suffix: " (clean)")
        try await save(loaded.image, to: out, ext: ext)
        return out
    }
}
