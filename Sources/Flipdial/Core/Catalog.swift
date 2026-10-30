import AppKit
import CryptoKit

enum WheelMode: String {
    case convert = "Convert", tools = "Tools", actions = "Actions"

    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .actions: return "bolt"
        }
    }

    var shortcut: String {
        switch self {
        case .convert: return "⇧"
        case .tools: return "⌘"
        case .actions: return "⌃"
        }
    }
}

struct OperationResult {
    var outputs: [URL] = []
    var message: String? = nil
    /// Also put `message` on the clipboard.
    var copiedText: Bool = false
}

struct FileOperation: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Why the operation can't run right now (missing engine, wrong file count); nil when ready.
    var unavailableReason: String? = nil
    let perform: ([URL]) async throws -> OperationResult

    var isAvailable: Bool { unavailableReason == nil }
}

enum Catalog {
    static func operations(for urls: [URL], mode: WheelMode) -> [FileOperation] {
        guard !urls.isEmpty else { return [] }
        switch mode {
        case .convert: return conversions(urls)
        case .tools: return tools(urls)
        case .actions: return Actions.all(urls)
        }
    }

    // MARK: Helpers

    /// Runs `body` on each file in turn and collects the outputs.
    static func each(_ body: @escaping (URL) async throws -> URL) -> ([URL]) async throws -> OperationResult {
        { urls in
            var outputs: [URL] = []
            for url in urls { outputs.append(try await body(url)) }
            return OperationResult(outputs: outputs)
        }
    }

    static func symbol(forExt ext: String) -> String {
        switch ext {
        case "jpg", "png", "heic", "webp", "avif", "tiff", "bmp", "icns": return "photo"
        case "gif": return "photo.stack"
        case "mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v": return "film"
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac": return "waveform"
        case "pdf": return "doc.richtext"
        case "docx", "doc", "odt", "rtf": return "doc.text"
        case "txt": return "text.alignleft"
        case "md": return "number"
        case "html": return "chevron.left.forwardslash.chevron.right"
        case "epub": return "book"
        case "pptx", "odp": return "rectangle.on.rectangle"
        case "xlsx", "ods": return "tablecells"
        case "csv", "tsv": return "list.bullet.rectangle"
        case "json": return "curlybraces"
        case "srt", "vtt": return "captions.bubble"
        case "zip", "tar", "tgz": return "archivebox"
        default: return "doc"
        }
    }

    static func label(_ ext: String) -> String {
        switch ext {
        case "tgz": return "TAR.GZ"
        case "txt": return "Text"
        case "md": return "Markdown"
        default: return ext.uppercased()
        }
    }

    private static func need(_ engine: Engine) -> String? {
        Engines.has(engine) ? nil : "Needs \(engine.displayName)"
    }

    private static func target(_ ext: String, reason: String? = nil,
                               _ body: @escaping (URL) async throws -> URL) -> FileOperation {
        FileOperation(id: "convert.\(ext)", title: label(ext), symbol: symbol(forExt: ext),
                      unavailableReason: reason, perform: each(body))
    }

    // MARK: Conversions

    static func conversions(_ urls: [URL]) -> [FileOperation] {
        let kind = FileKind.common(urls) ?? .other
        let sourceExts = Set(urls.map(\.ext))
        let notSelf: (FileOperation) -> Bool = { op in
            let ext = String(op.id.dropFirst("convert.".count))
            return !(sourceExts.count == 1 && (sourceExts.contains(ext) || (ext == "jpg" && sourceExts.contains("jpeg"))
                                               || (ext == "tiff" && sourceExts.contains("tif"))))
        }

        switch kind {
        case .image:
            var ops = ["jpg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "icns"]
                .filter { ImageKit.utTypes[$0] != nil }
                .map { ext in
                    target(ext, reason: ImageKit.canWrite(ext) ? nil : need(.ffmpeg)) { try await ImageKit.convert($0, to: ext) }
                }
            if sourceExts == ["gif"] {
                ops = ["mp4", "webm", "mov"].map { ext in
                    target(ext, reason: need(.ffmpeg)) { try await MediaKit.convert($0, to: ext) }
                } + ops
            }
            ops.append(FileOperation(id: "convert.pdf", title: "PDF", symbol: symbol(forExt: "pdf"),
                                     perform: { urls in
                                         let out = Output.url(for: urls[0], ext: "pdf")
                                         return OperationResult(outputs: [try ImageKit.pdf(from: urls, output: out)])
                                     }))
            ops.append(target("docx") { try ImageKit.toDocx($0) })
            ops.append(FileOperation(id: "convert.ocr", title: "Text (OCR)", symbol: "text.viewfinder",
                                     perform: each { try ImageKit.ocr($0) }))
            return ops.filter(notSelf)

        case .video:
            return ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3", "m4a", "wav"].map { ext in
                let ok = Engines.has(.ffmpeg) || urls.allSatisfy { MediaKit.canConvertWithoutFFmpeg($0, to: ext) }
                return target(ext, reason: ok ? nil : need(.ffmpeg)) { try await MediaKit.convert($0, to: ext) }
            }.filter(notSelf)

        case .audio:
            return ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac"].map { ext in
                let ok = Engines.has(.ffmpeg) || urls.allSatisfy { MediaKit.canConvertWithoutFFmpeg($0, to: ext) }
                return target(ext, reason: ok ? nil : need(.ffmpeg)) { try await MediaKit.convert($0, to: ext) }
            }.filter(notSelf)

        case .document:
            return ["docx", "pdf", "txt", "md", "rtf", "html", "odt", "epub", "png", "jpg"].map { ext in
                target(ext) { try await DocKit.convert($0, to: ext) }
            }.filter(notSelf)

        case .pdf:
            return ["docx", "pptx", "xlsx", "csv", "jpg", "png", "epub", "txt", "md", "rtf", "html"].map { ext in
                target(ext) { try await PDFTools.convert($0, to: ext) }
            }

        case .slides:
            let onlyPPTX = sourceExts == ["pptx"]
            return ["pdf", "jpg", "png", "pptx", "odp", "txt", "md"].map { ext in
                let reason = (["txt", "md"].contains(ext) && onlyPPTX) ? nil : need(.soffice)
                return target(ext, reason: reason) { try await SlideKit.convert($0, to: ext) }
            }.filter(notSelf)

        case .sheet:
            let inputReason: String? = sourceExts.contains("xls") ? need(.soffice) : nil
            return ["xlsx", "csv", "tsv", "ods", "pdf", "html", "json", "md"].map { ext in
                target(ext, reason: inputReason) { try await SheetKit.convert($0, to: ext) }
            }.filter(notSelf)

        case .subtitle:
            return ["srt", "vtt", "txt"].map { ext in target(ext) { try SubtitleKit.convert($0, to: ext) } }.filter(notSelf)

        case .archive:
            let extract = FileOperation(id: "convert.extract", title: "Extract", symbol: "archivebox.fill",
                                        perform: each { try await ArchiveKit.extract($0) })
            return [extract] + ArchiveKit.packFormats.map { format in
                target(format) { try await ArchiveKit.repack($0, format: format) }
            }.filter { op in !(sourceExts == ["zip"] && op.id == "convert.zip") && !(sourceExts == ["tar"] && op.id == "convert.tar") }

        case .folder, .other:
            return packOperations(urls)
        }
    }

    static func packOperations(_ urls: [URL]) -> [FileOperation] {
        ArchiveKit.packFormats.map { format in
            FileOperation(id: "convert.\(format)", title: label(format), symbol: "archivebox",
                          perform: { urls in OperationResult(outputs: [try await ArchiveKit.pack(urls, format: format)]) })
        }
    }

    // MARK: Tools

    private static func tool(_ id: String, _ title: String, _ symbol: String, reason: String? = nil,
                             _ perform: @escaping ([URL]) async throws -> OperationResult) -> FileOperation {
        FileOperation(id: "tool.\(id)", title: title, symbol: symbol, unavailableReason: reason, perform: perform)
    }

    private static func multi(_ urls: [URL], _ op: FileOperation) -> FileOperation {
        var op = op
        if urls.count < 2 && op.unavailableReason == nil { op.unavailableReason = "Drag two or more files to merge" }
        return op
    }

    static func tools(_ urls: [URL]) -> [FileOperation] {
        let kinds = urls.map(FileKind.kinds(of:))
        let kind = FileKind.common(urls) ?? .other
        let ff = need(.ffmpeg)
        var ops: [FileOperation] = []

        switch kind {
        case .image:
            ops = [
                tool("crop", "Crop…", "crop", cropImages),
                tool("compress", "Compress", "arrow.down.right.and.arrow.up.left", each { src in
                    let lossy = ["jpg", "jpeg", "heic", "webp", "avif"].contains(src.ext)
                    return try await ImageKit.transform(src, suffix: " (compressed)", forceExt: lossy ? nil : "jpg",
                                                        quality: 0.6, keepProperties: false) { $0 }
                }),
                tool("half", "Half Size", "arrow.down.forward.and.arrow.up.backward", each {
                    try await ImageKit.transform($0, suffix: " (50%)") { ImageKit.resized($0, scale: 0.5) }
                }),
                tool("fit1920", "Fit 1920px", "aspectratio", each {
                    try await ImageKit.transform($0, suffix: " (1920px)") { ImageKit.fitted($0, maxSide: 1920) }
                }),
                tool("rotate.right", "Rotate Right", "rotate.right", each {
                    try await ImageKit.transform($0, suffix: " (rotated)") { ImageKit.rotated($0, clockwise: true) }
                }),
                tool("rotate.left", "Rotate Left", "rotate.left", each {
                    try await ImageKit.transform($0, suffix: " (rotated)") { ImageKit.rotated($0, clockwise: false) }
                }),
                tool("flip", "Flip", "arrow.left.and.right.righttriangle.left.righttriangle.right", each {
                    try await ImageKit.transform($0, suffix: " (flipped)") { ImageKit.flipped($0) }
                }),
                tool("square", "Square", "square", each {
                    try await ImageKit.transform($0, suffix: " (square)") { ImageKit.croppedSquare($0) }
                }),
                tool("mono", "Black & White", "circle.lefthalf.filled", each {
                    try await ImageKit.transform($0, suffix: " (b&w)") { ImageKit.grayscale($0) }
                }),
                tool("cutout", "Remove Background", "person.crop.rectangle", each {
                    try await ImageKit.transform($0, suffix: " (cutout)", forceExt: "png") { try ImageKit.removingBackground($0) }
                }),
                tool("strip", "Strip Metadata", "eye.slash", each { try await ImageKit.stripMetadata($0) }),
            ]

        case .video:
            ops = [
                tool("compress", "Compress", "arrow.down.right.and.arrow.up.left", reason: ff, each { try await MediaKit.compressVideo($0) }),
                tool("720p", "720p", "rectangle.compress.vertical", reason: ff, each { try await MediaKit.scaleVideo($0, height: 720) }),
                tool("1080p", "1080p", "rectangle.expand.vertical", reason: ff, each { try await MediaKit.scaleVideo($0, height: 1080) }),
                tool("trim", "Trim…", "scissors", reason: ff, trimmer),
                tool("crop", "Crop…", "crop", reason: ff, cropVideos),
                tool("mute", "Mute", "speaker.slash", reason: ff, each { try await MediaKit.mute($0) }),
                tool("rotate", "Rotate", "rotate.right", reason: ff, each { try await MediaKit.rotateVideo($0) }),
                tool("speed", "2× Speed", "hare", reason: ff, each { try await MediaKit.speedVideo($0, factor: 2) }),
                tool("frame", "Grab Frame", "camera", reason: ff, each { try await MediaKit.snapshot($0) }),
                multi(urls, tool("merge", "Merge", "rectangle.stack.badge.plus", reason: ff) {
                    OperationResult(outputs: [try await MediaKit.merge($0)])
                }),
            ]

        case .audio:
            ops = [
                tool("compress", "Compress", "arrow.down.right.and.arrow.up.left", reason: ff, each { try await MediaKit.compressAudio($0) }),
                tool("trim", "Trim…", "scissors", reason: ff, trimmer),
                tool("normalize", "Normalize", "slider.horizontal.3", reason: ff, each { try await MediaKit.normalize($0) }),
                tool("fade", "Fade In/Out", "waveform.path.ecg", reason: ff, each { try await MediaKit.fade($0) }),
                tool("mono", "Mono", "speaker.wave.1", reason: ff, each { try await MediaKit.mono($0) }),
                tool("speed", "1.5× Speed", "hare", reason: ff, each { try await MediaKit.speedAudio($0, factor: 1.5) }),
                tool("silence", "Remove Silence", "waveform.badge.minus", reason: ff, each { try await MediaKit.removeSilence($0) }),
                multi(urls, tool("merge", "Merge", "rectangle.stack.badge.plus", reason: ff) {
                    OperationResult(outputs: [try await MediaKit.merge($0)])
                }),
            ]

        case .pdf:
            ops = [
                tool("compress", "Compress", "arrow.down.right.and.arrow.up.left", each { try PDFTools.compress($0) }),
                multi(urls, tool("merge", "Merge", "rectangle.stack.badge.plus") { OperationResult(outputs: [try PDFTools.merge($0)]) }),
                tool("split", "Split Pages", "square.split.2x1", each { try PDFTools.split($0) }),
                tool("rotate", "Rotate", "rotate.right", each { try PDFTools.rotate($0) }),
                tool("reverse", "Reverse Order", "arrow.up.arrow.down", each { try PDFTools.reverse($0) }),
                tool("extract", "Extract Pages…", "doc.on.doc", pageRange("Extract Pages", PDFTools.extract)),
                tool("delete", "Delete Pages…", "trash", pageRange("Delete Pages", PDFTools.delete)),
                tool("lock", "Add Password…", "lock", password("Add Password", PDFTools.encrypt)),
                tool("unlock", "Remove Password…", "lock.open", password("Remove Password", PDFTools.decrypt)),
                tool("info", "Info", "info.circle") { urls in
                    OperationResult(message: try urls.map { "\($0.lastPathComponent): \(try PDFTools.info($0))" }.joined(separator: "\n"))
                },
            ]

        case .document:
            ops = [tool("count", "Word Count", "textformat.123") { urls in
                var lines: [String] = []
                for url in urls { lines.append("\(url.lastPathComponent): \(try await DocKit.wordCount(url))") }
                return OperationResult(message: lines.joined(separator: "\n"))
            }]

        case .archive:
            ops = [tool("extract", "Extract", "archivebox.fill", each { try await ArchiveKit.extract($0) })]

        default:
            break
        }

        // PDFs and images dragged together can be combined into one PDF.
        if urls.count > 1, kind != .pdf,
           kinds.allSatisfy({ !$0.isDisjoint(with: [.pdf, .image]) }) {
            ops.append(tool("combine", "Combine to PDF", "doc.on.doc.fill") { urls in
                OperationResult(outputs: [try PDFTools.merge(urls)])
            })
        }

        ops.append(tool("zip", urls.count > 1 ? "Zip All" : "Zip", "archivebox") { urls in
            OperationResult(outputs: [try await ArchiveKit.pack(urls, format: "zip")])
        })
        if urls.allSatisfy({ !$0.isDirectory }) {
            ops.append(tool("sha256", "Checksum", "number.square") { urls in
                OperationResult(message: try urls.map { "\(try sha256($0))  \($0.lastPathComponent)" }.joined(separator: "\n"),
                                copiedText: true)
            })
        }
        return ops
    }

    /// Pick the area once on the first image; the same relative area is applied to every file.
    private static let cropImages: ([URL]) async throws -> OperationResult = { urls in
        let preview = try ImageKit.load(urls[0]).image
        guard let area = await CropWindow.ask(image: preview, title: urls[0].lastPathComponent) else { throw CancellationError() }
        var outputs: [URL] = []
        for url in urls {
            outputs.append(try await ImageKit.transform(url, suffix: " (cropped)") { image in
                ImageKit.cropped(image, to: CGRect(x: area.minX * CGFloat(image.width), y: area.minY * CGFloat(image.height),
                                                   width: area.width * CGFloat(image.width), height: area.height * CGFloat(image.height)))
            })
        }
        return OperationResult(outputs: outputs)
    }

    private static let cropVideos: ([URL]) async throws -> OperationResult = { urls in
        let preview = try await MediaKit.frame(of: urls[0])
        guard let area = await CropWindow.ask(image: preview, title: urls[0].lastPathComponent) else { throw CancellationError() }
        var outputs: [URL] = []
        for url in urls {
            // Frame size after FFmpeg's auto-rotation, which is what the crop filter sees.
            let frame = url == urls[0] ? preview : try await MediaKit.frame(of: url)
            let w = CGFloat(frame.width), h = CGFloat(frame.height)
            outputs.append(try await MediaKit.cropVideo(url, rect: CGRect(x: area.minX * w, y: area.minY * h,
                                                                           width: area.width * w, height: area.height * h)))
        }
        return OperationResult(outputs: outputs)
    }

    private static let trimmer: ([URL]) async throws -> OperationResult = { urls in
        guard let values = await Prompt.ask(
            title: "Trim \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")",
            message: "Times as seconds or mm:ss. Leave End empty to keep everything after Start.",
            fields: [.init(label: "Start", placeholder: "0:05"), .init(label: "End", placeholder: "1:30")]
        ) else { throw CancellationError() }
        guard let start = parseTime(values[0].isEmpty ? "0" : values[0]) else { throw FlipdialError("“\(values[0])” isn't a time") }
        let end = values[1].isEmpty ? nil : parseTime(values[1])
        if !values[1].isEmpty && end == nil { throw FlipdialError("“\(values[1])” isn't a time") }
        var outputs: [URL] = []
        for url in urls { outputs.append(try await MediaKit.trim(url, start: start, end: end)) }
        return OperationResult(outputs: outputs)
    }

    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }), parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    private static func pageRange(_ title: String, _ body: @escaping (URL, String) throws -> URL) -> ([URL]) async throws -> OperationResult {
        { urls in
            guard let values = await Prompt.ask(title: title, message: "Pages like 1-3, 5, 8-",
                                                fields: [.init(label: "Pages", placeholder: "1-3, 5")]) else { throw CancellationError() }
            return OperationResult(outputs: try urls.map { try body($0, values[0]) })
        }
    }

    private static func password(_ title: String, _ body: @escaping (URL, String) throws -> URL) -> ([URL]) async throws -> OperationResult {
        { urls in
            guard let values = await Prompt.ask(title: title, message: urls.map(\.lastPathComponent).joined(separator: ", "),
                                                fields: [.init(label: "Password", placeholder: "", secure: true)]) else { throw CancellationError() }
            return OperationResult(outputs: try urls.map { try body($0, values[0]) })
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
