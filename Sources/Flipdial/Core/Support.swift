import AppKit
import Foundation

struct FlipdialError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - External engines

/// Command-line engines. FFmpeg ships inside the app; the others are optional extras.
enum Engine: String, CaseIterable, Identifiable {
    case ffmpeg, soffice, pandoc, cwebp

    /// Engines listed in Settings; cwebp is an internal helper bundled with the app.
    static let visible: [Engine] = [.ffmpeg, .soffice, .pandoc]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .soffice: return "LibreOffice"
        case .pandoc: return "Pandoc"
        case .cwebp: return "WebP encoder"
        }
    }

    var purpose: String {
        switch self {
        case .ffmpeg: return "Video, audio, GIF, WebP and AVIF"
        case .soffice: return "PowerPoint slides and old .xls/.doc files"
        case .pandoc: return "Optional: higher-fidelity Markdown and EPUB"
        case .cwebp: return "WebP images"
        }
    }

    var downloadURL: URL {
        switch self {
        case .ffmpeg: return URL(string: "https://ffmpeg.org/download.html")!
        case .soffice: return URL(string: "https://www.libreoffice.org/download/download/")!
        case .pandoc: return URL(string: "https://pandoc.org/installing.html")!
        case .cwebp: return URL(string: "https://developers.google.com/speed/webp/download")!
        }
    }
}

enum Engines {
    /// The app bundle's own copies come first, then common install locations.
    private static var searchPaths: [String] {
        var paths: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path { paths.append(bundled) }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/LibreOffice.app/Contents/MacOS",
                  NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS"]
        return paths
    }

    private static let lock = NSLock()
    private static var cache: [Engine: URL?] = [:]

    static func path(_ engine: Engine) -> URL? {
        // Lets tests exercise the built-in fallbacks, e.g. FLIPDIAL_DISABLE=pandoc
        if ProcessInfo.processInfo.environment["FLIPDIAL_DISABLE"]?.split(separator: ",").contains(Substring(engine.rawValue)) == true {
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[engine] { return cached }
        let found = searchPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(engine.rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        cache[engine] = found
        return found
    }

    static func has(_ engine: Engine) -> Bool { path(engine) != nil }

    static func require(_ engine: Engine) throws -> URL {
        guard let url = path(engine) else {
            throw FlipdialError("Needs \(engine.displayName) (free) — see Settings → Formats")
        }
        return url
    }

    static func refresh() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }
}

// MARK: - Shell

enum Shell {
    private final class Box: @unchecked Sendable { var out = Data(); var err = Data() }

    struct Output { let status: Int32; let stdout: String; let stderr: String }

    /// Runs a process to completion without treating a non-zero exit as an error.
    static func execute(_ executable: URL, _ arguments: [String], cwd: URL? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let box = Box()
            let group = DispatchGroup()
            process.terminationHandler = { proc in
                group.wait()
                continuation.resume(returning: Output(status: proc.terminationStatus,
                                                      stdout: String(decoding: box.out, as: UTF8.self),
                                                      stderr: String(decoding: box.err, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            group.enter()
            DispatchQueue.global().async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        }
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], cwd: URL? = nil) async throws -> String {
        let result = try await execute(executable, arguments, cwd: cwd)
        guard result.status == 0 else {
            let tail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").suffix(3).joined(separator: "\n")
            throw FlipdialError("\(executable.lastPathComponent) failed: \(tail.isEmpty ? "exit \(result.status)" : tail)")
        }
        return result.stdout
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String], cwd: URL? = nil) async throws -> String {
        try await run(URL(fileURLWithPath: path), arguments, cwd: cwd)
    }
}

// MARK: - Temp directories

enum Temp {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Flipdial", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs `body` with a fresh temp directory and deletes it afterwards.
    static func with<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }
}

// MARK: - Output naming

enum Output {
    static func directory(for source: URL) -> URL {
        if let custom = Prefs.customOutputFolder { return custom }
        return source.deletingLastPathComponent()
    }

    static func baseName(_ source: URL) -> String {
        source.hasDirectoryPath && source.pathExtension.isEmpty
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent
    }

    /// A non-clashing output URL next to `source`, e.g. "photo.png" or "photo (compressed).jpg".
    static func url(for source: URL, ext: String, suffix: String = "") -> URL {
        let name = baseName(source) + suffix
        return unique(directory(for: source).appendingPathComponent(name).appendingPathExtension(ext))
    }

    /// Creates and returns a fresh folder next to `source` for multi-file outputs.
    static func folder(for source: URL, suffix: String) throws -> URL {
        let url = unique(directory(for: source).appendingPathComponent(baseName(source) + suffix, isDirectory: true))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Moves a file produced in a temp directory to its final location.
    @discardableResult
    static func place(_ produced: URL, at destination: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: produced, to: destination)
        return destination
    }
}

// MARK: - File kinds

enum FileKind: String, CaseIterable {
    case image, video, audio, document, pdf, slides, sheet, subtitle, archive, folder, other

    static let extensions: [FileKind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "avif", "bmp", "gif", "svg", "ico", "icns", "jp2"],
        .video: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v", "flv", "mpg", "mpeg", "3gp", "ts", "gif"],
        .audio: ["mp3", "m4a", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "wma", "aac", "caf", "m4r"],
        .document: ["docx", "doc", "odt", "rtf", "rtfd", "html", "htm", "txt", "text", "md", "markdown", "epub", "webarchive"],
        .pdf: ["pdf"],
        .slides: ["pptx", "ppt", "odp"],
        .sheet: ["xlsx", "xls", "ods", "csv", "tsv"],
        .subtitle: ["srt", "vtt"],
        .archive: ["zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz", "tbz", "txz"],
    ]

    static func kinds(of url: URL) -> Set<FileKind> {
        let ext = url.ext
        var result = Set(extensions.filter { $0.value.contains(ext) }.map(\.key))
        // .rtfd bundles are directories but still documents.
        if result.isEmpty && url.isDirectory { result.insert(.folder) }
        if result.isEmpty { result.insert(.other) }
        return result
    }

    /// The single kind shared by every file, preferring the most specific one.
    static func common(_ urls: [URL]) -> FileKind? {
        guard let first = urls.first else { return nil }
        var shared = kinds(of: first)
        for url in urls.dropFirst() { shared.formIntersection(kinds(of: url)) }
        let order: [FileKind] = [.image, .pdf, .document, .slides, .sheet, .subtitle, .audio, .video, .archive, .folder, .other]
        return order.first { shared.contains($0) }
    }
}

extension URL {
    var ext: String { pathExtension.lowercased() }
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
}
