import Foundation

// MARK: - Slides

enum SlideKit {
    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let out = Output.url(for: src, ext: ext)
        switch ext {
        case "pdf":
            try await Office.convert(src, filter: "pdf", producedExt: "pdf", to: out)
        case "jpg", "png":
            return try await Temp.with { dir in
                let pdf = dir.appendingPathComponent(Output.baseName(src) + ".pdf")
                try await Office.convert(src, filter: "pdf", producedExt: "pdf", to: pdf)
                return try await PDFTools.renderPages(pdf, ext: ext, destination: out)
            }
        case "pptx", "odp":
            try await Office.convert(src, filter: ext, producedExt: ext, to: out)
        case "txt", "md":
            let slides = try await Temp.with { dir -> [String] in
                var pptx = src
                if src.ext != "pptx" {
                    pptx = dir.appendingPathComponent("deck.pptx")
                    try await Office.convert(src, filter: "pptx", producedExt: "pptx", to: pptx)
                }
                return try slideTexts(pptx)
            }
            let body = slides.enumerated().map { i, text in
                ext == "md"
                    ? "## Slide \(i + 1)\n\n" + text.split(separator: "\n").map { "- \($0)" }.joined(separator: "\n")
                    : "— Slide \(i + 1) —\n\(text)"
            }.joined(separator: "\n\n")
            try (body + "\n").write(to: out, atomically: true, encoding: .utf8)
        default:
            throw FlipdialError("Can't convert slides to .\(ext)")
        }
        return out
    }

    /// Reads the text runs (<a:t>) from each slide of a .pptx, in slide order.
    static func slideTexts(_ pptx: URL) throws -> [String] {
        let dir = try Temp.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Zip.extract(pptx, to: dir)
        let slidesDir = dir.appendingPathComponent("ppt/slides")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: slidesDir.path)) ?? [])
            .filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.map { name in
            let reader = TextRunReader()
            if let parser = XMLParser(contentsOf: slidesDir.appendingPathComponent(name)) {
                parser.delegate = reader
                parser.parse()
            }
            return reader.paragraphs.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private final class TextRunReader: NSObject, XMLParserDelegate {
        var paragraphs: [String] = [""]
        private var inText = false
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "a:t" { inText = true } else if name == "a:p" { paragraphs.append("") }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inText { paragraphs[paragraphs.count - 1] += s } }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "a:t" { inText = false }
        }
    }
}

// MARK: - Subtitles

enum SubtitleKit {
    struct Cue { var start: String; var end: String; var text: String }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let cues = parse(try String(contentsOf: src, encoding: .utf8))
        guard !cues.isEmpty else { throw FlipdialError("No subtitles found in \(src.lastPathComponent)") }
        let out = Output.url(for: src, ext: ext)
        let body: String
        switch ext {
        case "srt":
            body = cues.enumerated().map { i, c in
                "\(i + 1)\n\(timestamp(c.start, comma: true)) --> \(timestamp(c.end, comma: true))\n\(c.text)"
            }.joined(separator: "\n\n") + "\n"
        case "vtt":
            body = "WEBVTT\n\n" + cues.map { "\(timestamp($0.start, comma: false)) --> \(timestamp($0.end, comma: false))\n\($0.text)" }
                .joined(separator: "\n\n") + "\n"
        default:
            body = cues.map { $0.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .joined(separator: "\n") + "\n"
        }
        try body.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            // VTT cue settings may follow the end time.
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            return body.isEmpty ? nil : Cue(start: start, end: end, text: body)
        }
    }

    /// Normalises "1:02.5", "00:01:02.500" or "00:01:02,500" to HH:MM:SS,mmm / HH:MM:SS.mmm.
    static func timestamp(_ raw: String, comma: Bool) -> String {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        var parts = cleaned.split(separator: ":").map(String.init)
        while parts.count < 3 { parts.insert("00", at: 0) }
        let secParts = parts[2].split(separator: ".").map(String.init)
        let ms = secParts.count > 1 ? String((secParts[1] + "000").prefix(3)) : "000"
        let hh = String(format: "%02d", Int(parts[0]) ?? 0)
        let mm = String(format: "%02d", Int(parts[1]) ?? 0)
        let ss = String(format: "%02d", Int(secParts[0]) ?? 0)
        return "\(hh):\(mm):\(ss)\(comma ? "," : ".")\(ms)"
    }
}

// MARK: - Archives

enum ArchiveKit {
    static let packFormats = ["zip", "tar", "tgz"]

    static func outputExt(_ format: String) -> String { format == "tgz" ? "tar.gz" : format }

    /// Packs one or more items into a single archive next to the first item.
    static func pack(_ urls: [URL], format: String, into destination: URL? = nil) async throws -> URL {
        guard let first = urls.first else { throw FlipdialError("Nothing to compress") }
        let parent = first.deletingLastPathComponent()
        let name = urls.count == 1 ? Output.baseName(first) : "Archive"
        let out = Output.unique((destination ?? Prefs.customOutputFolder ?? parent)
            .appendingPathComponent("\(name).\(outputExt(format))"))

        if urls.allSatisfy({ $0.deletingLastPathComponent() == parent }) {
            try await pack(names: urls.map(\.lastPathComponent), in: parent, format: format, out: out)
        } else {
            try await Temp.with { dir in
                for url in urls { try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent)) }
                try await pack(names: urls.map(\.lastPathComponent), in: dir, format: format, out: out)
            }
        }
        return out
    }

    private static func pack(names: [String], in dir: URL, format: String, out: URL) async throws {
        switch format {
        case "zip":
            if names.count == 1 {
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                                       dir.appendingPathComponent(names[0]).path, out.path])
            } else {
                try await Shell.run("/usr/bin/zip", ["-q", "-r", "-y", out.path] + names, cwd: dir)
            }
        case "tar": try await Shell.run("/usr/bin/tar", ["-cf", out.path, "-C", dir.path] + names)
        case "tgz": try await Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", dir.path] + names)
        default: throw FlipdialError("Unknown archive format \(format)")
        }
    }

    private static func isPlainGzip(_ url: URL) -> Bool {
        url.ext == "gz" && !url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(".tar")
    }

    /// "photos.tar.gz" → "photos".
    static func archiveBaseName(_ url: URL) -> String {
        var base = url.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        return base.lastPathComponent
    }

    static func extract(_ src: URL, into destination: URL? = nil) async throws -> URL {
        let parent = destination ?? Prefs.customOutputFolder ?? src.deletingLastPathComponent()

        if isPlainGzip(src) {
            let out = Output.unique(parent.appendingPathComponent(src.deletingPathExtension().lastPathComponent))
            try await Temp.with { dir in
                let copy = dir.appendingPathComponent(src.lastPathComponent)
                try FileManager.default.copyItem(at: src, to: copy)
                try await Shell.run("/usr/bin/gunzip", [copy.path])
                try Output.place(copy.deletingPathExtension(), at: out)
            }
            return out
        }

        let folder = Output.unique(parent.appendingPathComponent(archiveBaseName(src), isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            if src.ext == "zip" {
                try await Shell.run("/usr/bin/ditto", ["-x", "-k", src.path, folder.path])
            } else {
                // bsdtar (libarchive) also reads RAR, 7z, xz and bzip2 archives.
                try await Shell.run("/usr/bin/tar", ["-xf", src.path, "-C", folder.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // Unwrap a lone top-level folder so "Foo.zip" doesn't become "Foo/Foo/…".
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        if items.count == 1, items[0].isDirectory, items[0].lastPathComponent == folder.lastPathComponent {
            let tmp = parent.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: items[0], to: tmp)
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: tmp, to: folder)
        }
        return folder
    }

    /// Re-packs an archive in another format.
    static func repack(_ src: URL, format: String) async throws -> URL {
        try await Temp.with { dir in
            let extracted = try await extract(src, into: dir)
            let packed = try await pack([extracted], format: format, into: dir)
            let out = Output.unique((Prefs.customOutputFolder ?? src.deletingLastPathComponent())
                .appendingPathComponent("\(archiveBaseName(src)).\(outputExt(format))"))
            return try Output.place(packed, at: out)
        }
    }
}
