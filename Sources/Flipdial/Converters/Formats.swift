import AppKit

// MARK: - Zip

enum Zip {
    /// Writes entries into a new zip archive. `storedFirst` (EPUB's mimetype) is added first, uncompressed.
    static func create(_ entries: [String: Data], at out: URL, storedFirst: String? = nil) throws {
        let dir = try Temp.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (path, data) in entries {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try? FileManager.default.removeItem(at: out)
        var rest = entries.keys.sorted()
        if let first = storedFirst {
            try runSync("/usr/bin/zip", ["-q", "-X", "-0", out.path, first], cwd: dir)
            rest.removeAll { $0 == first }
        }
        try runSync("/usr/bin/zip", ["-q", "-X", "-9", out.path] + rest, cwd: dir)
    }

    static func create(text entries: [String: String], at out: URL, storedFirst: String? = nil) throws {
        try create(entries.mapValues { Data($0.utf8) }, at: out, storedFirst: storedFirst)
    }

    static func extract(_ zip: URL, to dir: URL) throws {
        try runSync("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", dir.path], cwd: nil)
    }

    private static func runSync(_ path: String, _ args: [String], cwd: URL?) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FlipdialError("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(p.terminationStatus))")
        }
    }
}

enum XML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
}

// MARK: - Structured text

/// Rich text reduced to the structure Markdown and EPUB can express.
struct TextBlock {
    enum Kind: Equatable { case heading(Int), paragraph, bullet(Int), numbered(Int), quote, code, table, image }

    struct Run {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var link: String? = nil

        func sameStyle(_ other: Run) -> Bool {
            bold == other.bold && italic == other.italic && code == other.code && link == other.link
        }
    }

    var kind: Kind
    var runs: [Run]
    /// Cell text for `.table` blocks.
    var rows: [[String]] = []
    /// PNG data and pixel size for `.image` blocks.
    var image: (png: Data, width: Int, height: Int)? = nil
    var plainText: String { runs.map(\.text).joined() }
}

enum Semantic {
    /// Infers headings from font size relative to the body text, lists from list styles or bullet
    /// characters, and code from monospaced fonts.
    static func blocks(from text: NSAttributedString) -> [TextBlock] {
        let string = text.string as NSString
        let full = NSRange(location: 0, length: string.length)
        guard full.length > 0 else { return [] }

        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            sizes[((value as? NSFont)?.pointSize ?? 12).rounded(), default: 0] += range.length
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        // "• item", "1. item", or Cocoa's tab-separated list markers ("\t1\titem").
        let markerPattern = try! NSRegularExpression(pattern: #"^\s*(?:([•◦▪●○■\-–*])\s+|(\d+)[.)]\s+|(\d+)\t)"#)

        var blocks: [TextBlock] = []
        var tableIndex: [ObjectIdentifier: Int] = [:]
        var location = 0
        while location < full.length {
            let paraRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paraRange)
            var content = paraRange
            while content.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content.length -= 1
            }
            let raw = string.substring(with: content)
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            var maxSize: CGFloat = 0
            var allBold = true, allMono = true
            var runs: [TextBlock.Run] = []
            var images: [TextBlock] = []
            text.enumerateAttributes(in: content) { attrs, range, _ in
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    if let image = pngImage(from: attachment) { images.append(TextBlock(kind: .image, runs: [], image: image)) }
                    return
                }
                let font = attrs[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let piece = string.substring(with: range)
                let visible = !piece.trimmingCharacters(in: .whitespaces).isEmpty
                maxSize = max(maxSize, font?.pointSize ?? body)
                if visible && !traits.contains(.bold) { allBold = false }
                if visible && !traits.contains(.monoSpace) { allMono = false }
                var link: String? = nil
                if let url = attrs[.link] as? URL { link = url.absoluteString }
                else if let s = attrs[.link] as? String { link = s }
                let run = TextBlock.Run(text: piece, bold: traits.contains(.bold), italic: traits.contains(.italic),
                                        code: traits.contains(.monoSpace), link: link)
                if let last = runs.last, last.sameStyle(run) { runs[runs.count - 1].text += piece } else { runs.append(run) }
            }

            if runs.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                blocks += images
                continue
            }
            defer { blocks += images }
            let style = text.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle

            // Table cells become rows of one table block.
            if let cell = style?.textBlocks.last as? NSTextTableBlock {
                let id = ObjectIdentifier(cell.table)
                let index = tableIndex[id] ?? {
                    blocks.append(TextBlock(kind: .table, runs: []))
                    tableIndex[id] = blocks.count - 1
                    return blocks.count - 1
                }()
                var rows = blocks[index].rows
                while rows.count <= cell.startingRow { rows.append([]) }
                while rows[cell.startingRow].count <= cell.startingColumn { rows[cell.startingRow].append("") }
                let value = raw.trimmingCharacters(in: .whitespaces)
                let existing = rows[cell.startingRow][cell.startingColumn]
                rows[cell.startingRow][cell.startingColumn] = existing.isEmpty ? value : existing + " " + value
                blocks[index].rows = rows
                continue
            }

            let lists = style?.textLists ?? []
            let marker = markerPattern.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length))
            // Nesting comes from the list styles, or failing that from the indent (0.5" per level).
            let level = lists.isEmpty ? max(1, Int(((style?.headIndent ?? 0) / 36).rounded())) : lists.count
            var kind: TextBlock.Kind = .paragraph

            if let marker {
                let numbered = marker.range(at: 1).location == NSNotFound
                    || lists.last.map { $0.markerFormat.rawValue.contains("decimal") } == true
                kind = numbered ? .numbered(level) : .bullet(level)
                runs = strip(prefixLength: marker.range.length, from: runs)
            } else if !lists.isEmpty {
                kind = lists.last!.markerFormat.rawValue.contains("decimal") ? .numbered(level) : .bullet(level)
            } else if allMono && sizes.count > 1 {
                kind = .code
            } else if maxSize >= body * 1.45 {
                kind = .heading(1)
            } else if maxSize >= body * 1.22 {
                kind = .heading(2)
            } else if maxSize >= body * 1.12 || (allBold && raw.count < 70 && !raw.hasSuffix(".") && !raw.hasSuffix(":")) {
                kind = .heading(3)
            } else if (style?.headIndent ?? 0) > 20 && (style?.firstLineHeadIndent ?? 0) > 20 {
                kind = .quote
            } else if let block = style?.textBlocks.last, !(block is NSTextTableBlock),
                      block.width(for: .margin, edge: .minX) > 10 {
                kind = .quote
            }
            if case .heading = kind {
                runs = runs.map { var r = $0; r.bold = false; return r }
            }
            blocks.append(TextBlock(kind: kind, runs: runs))
        }
        return blocks
    }

    private static func pngImage(from attachment: NSTextAttachment) -> (png: Data, width: Int, height: Int)? {
        // Prefer the attachment's real file data; `image` can be a generic placeholder icon.
        var image: NSImage? = nil
        if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents { image = NSImage(data: data) }
        if image == nil { image = attachment.image }
        guard let image, var rect = Optional(CGRect(origin: .zero, size: image.size)),
              let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, cg.width, cg.height)
    }

    private static func strip(prefixLength: Int, from runs: [TextBlock.Run]) -> [TextBlock.Run] {
        var remaining = prefixLength
        var result: [TextBlock.Run] = []
        for var run in runs {
            let length = (run.text as NSString).length
            if remaining >= length { remaining -= length; continue }
            if remaining > 0 { run.text = (run.text as NSString).substring(from: remaining); remaining = 0 }
            result.append(run)
        }
        return result
    }

    // MARK: Markdown

    /// Images are saved into `assets` (created on demand) and linked by relative path.
    static func markdown(_ blocks: [TextBlock], assets: URL? = nil) -> String {
        var imageCount = 0
        var out = ""
        var previous: TextBlock.Kind? = nil
        for block in blocks {
            if previous == .code && block.kind != .code { out += "\n```" }
            if !out.isEmpty {
                let sameList: Bool = {
                    switch (block.kind, previous) {
                    case (.bullet, .bullet?), (.numbered, .numbered?): return true
                    case (.bullet(let a), .numbered(let b)?), (.numbered(let a), .bullet(let b)?): return a > 1 || b > 1
                    default: return false
                    }
                }()
                let tight = sameList || (block.kind == .code && previous == .code)
                out += tight ? "\n" : "\n\n"
            }
            switch block.kind {
            case .heading(let level): out += String(repeating: "#", count: level) + " " + inlineMarkdown(block.runs)
            case .paragraph: out += inlineMarkdown(block.runs)
            case .bullet(let level): out += String(repeating: "  ", count: level - 1) + "- " + inlineMarkdown(block.runs)
            case .numbered(let level): out += String(repeating: "   ", count: level - 1) + "1. " + inlineMarkdown(block.runs)
            case .quote: out += "> " + inlineMarkdown(block.runs)
            case .code:
                if previous != .code { out += "```\n" }
                out += block.plainText
            case .table:
                out += SheetKit.markdownTable(block.rows).trimmingCharacters(in: .newlines)
            case .image:
                guard let image = block.image, let assets else { continue }
                imageCount += 1
                let name = "image\(imageCount).png"
                try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                if (try? image.png.write(to: assets.appendingPathComponent(name))) != nil {
                    let folder = assets.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assets.lastPathComponent
                    out += "![](\(folder)/\(name))"
                }
            }
            previous = block.kind
        }
        if previous == .code { out += "\n```" }
        return out + "\n"
    }

    private static func inlineMarkdown(_ runs: [TextBlock.Run]) -> String {
        runs.map { run -> String in
            let text = run.text
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            let lead = String(text.prefix { $0 == " " }), trail = String(text.reversed().prefix { $0 == " " })
            var piece = run.code ? "`\(core)`" : escapeMarkdown(core)
            if run.italic && !run.code { piece = "*\(piece)*" }
            if run.bold && !run.code { piece = "**\(piece)**" }
            if let link = run.link { piece = "[\(piece)](\(link))" }
            return lead + piece + trail
        }.joined()
    }

    private static func escapeMarkdown(_ s: String) -> String {
        var out = ""
        for c in s {
            if "*_`[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    // MARK: XHTML

    static func xhtml(_ blocks: [TextBlock]) -> String {
        var out = ""
        var openList: String? = nil
        var codeOpen = false
        func closeList() { if let tag = openList { out += "</\(tag)>\n"; openList = nil } }
        for block in blocks {
            if block.kind != .code && codeOpen { out += "</code></pre>\n"; codeOpen = false }
            switch block.kind {
            case .bullet, .numbered:
                let tag = { if case .numbered = block.kind { return "ol" } else { return "ul" } }()
                if openList != tag { closeList(); out += "<\(tag)>\n"; openList = tag }
                out += "<li>\(inlineXHTML(block.runs))</li>\n"
                continue
            default: closeList()
            }
            switch block.kind {
            case .heading(let level): out += "<h\(level)>\(inlineXHTML(block.runs))</h\(level)>\n"
            case .quote: out += "<blockquote><p>\(inlineXHTML(block.runs))</p></blockquote>\n"
            case .code:
                if !codeOpen { out += "<pre><code>"; codeOpen = true } else { out += "\n" }
                out += XML.escape(block.plainText)
            case .image:
                if let image = block.image {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("flipdial-\(UUID().uuidString).png")
                    if (try? image.png.write(to: file)) != nil { out += "<p><img alt=\"\" src=\"\(file.absoluteString)\"/></p>\n" }
                }
            case .table:
                out += "<table>\n" + block.rows.enumerated().map { i, row in
                    let tag = i == 0 ? "th" : "td"
                    return "<tr>" + row.map { "<\(tag)>\(XML.escape($0))</\(tag)>" }.joined() + "</tr>"
                }.joined(separator: "\n") + "\n</table>\n"
            default: out += "<p>\(inlineXHTML(block.runs))</p>\n"
            }
        }
        if codeOpen { out += "</code></pre>\n" }
        closeList()
        return out
    }

    private static func inlineXHTML(_ runs: [TextBlock.Run]) -> String {
        runs.map { run in
            var piece = XML.escape(run.text)
            if run.code { piece = "<code>\(piece)</code>" }
            if run.italic { piece = "<em>\(piece)</em>" }
            if run.bold { piece = "<strong>\(piece)</strong>" }
            if let link = run.link { piece = "<a href=\"\(XML.escape(link))\">\(piece)</a>" }
            return piece
        }.joined()
    }
}

// MARK: - Markdown → HTML

/// Markdown → XHTML: headings, emphasis, links, images, nested lists, quotes, code and pipe tables.
enum Markdown {
    /// Wraps an HTML fragment in a light-only page with readable defaults.
    static func page(_ body: String, title: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/>\
        <meta name="color-scheme" content="light"/><title>\(XML.escape(title))</title><style>
        body{font-family:-apple-system,Helvetica,sans-serif;font-size:12pt;color:#111;line-height:1.4}
        pre,code{font-family:Menlo,monospace;font-size:10pt}pre{background:#f4f4f4;padding:6px}
        table{border-collapse:collapse}td,th{border:1px solid #bbb;padding:3px 6px}th{background:#eee}
        blockquote{color:#444;margin-left:1.5em}img{max-width:100%}
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    /// `base` resolves relative image paths so images survive into PDF/DOCX/EPUB.
    static func html(_ source: String, base: URL?) -> String {
        var html = ""
        var listStack: [(tag: String, indent: Int)] = []
        var inCode = false
        var paragraph: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func flush() {
            if !paragraph.isEmpty { html += "<p>\(inline(paragraph.joined(separator: " "), base: base))</p>\n"; paragraph = [] }
        }
        func closeLists(to indent: Int = -1) {
            while let top = listStack.last, top.indent > indent { html += "</li></\(top.tag)>\n"; listStack.removeLast() }
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush(); closeLists()
                html += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle()
                continue
            }
            if inCode { html += XML.escape(raw) + "\n"; continue }
            if line.isEmpty { flush(); continue }

            // Pipe table: a header row followed by a |---| separator row.
            if line.hasPrefix("|"), i < lines.count,
               lines[i].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flush(); closeLists()
                func cells(_ row: String) -> [String] {
                    var r = row.trimmingCharacters(in: .whitespaces)
                    if r.hasPrefix("|") { r.removeFirst() }
                    if r.hasSuffix("|") { r.removeLast() }
                    return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                html += "<table><tr>" + cells(line).map { "<th>\(inline($0, base: base))</th>" }.joined() + "</tr>\n"
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    html += "<tr>" + cells(lines[i]).map { "<td>\(inline($0, base: base))</td>" }.joined() + "</tr>\n"
                    i += 1
                }
                html += "</table>\n"
                continue
            }

            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let match = line.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) {
                flush(); closeLists()
                let level = line[match].filter { $0 == "#" }.count
                let text = String(line[match.upperBound...]).replacingOccurrences(of: #"\s#+$"#, with: "", options: .regularExpression)
                html += "<h\(level)>\(inline(text, base: base))</h\(level)>\n"
            } else if let match = line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                flush()
                let tag = line[match].first!.isNumber ? "ol" : "ul"
                if let top = listStack.last, top.indent == indent, top.tag == tag {
                    html += "</li>\n"
                } else if let top = listStack.last, indent > top.indent {
                    html += "\n<\(tag)>\n"
                    listStack.append((tag, indent))
                } else {
                    closeLists(to: indent)
                    if let top = listStack.last, top.indent == indent {
                        html += "</li></\(top.tag)>\n"
                        listStack.removeLast()
                    }
                    html += "<\(tag)>\n"
                    listStack.append((tag, indent))
                }
                var item = String(line[match.upperBound...])
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) }
                if item.lowercased().hasPrefix("[x] ") { item = "☑ " + item.dropFirst(4) }
                html += "<li>\(inline(item, base: base))"
            } else if line.hasPrefix(">") {
                flush(); closeLists()
                html += "<blockquote><p>\(inline(String(line.drop { $0 == ">" || $0 == " " }), base: base))</p></blockquote>\n"
            } else if line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil {
                flush(); closeLists(); html += "<hr/>\n"
            } else if !listStack.isEmpty && indent > 0 {
                html += " " + inline(line, base: base)
            } else {
                closeLists(); paragraph.append(line)
            }
        }
        flush(); closeLists()
        if inCode { html += "</code></pre>\n" }
        return html
    }

    private static func inline(_ s: String, base: URL?) -> String {
        // Protect code spans first so their contents aren't formatted.
        var codes: [String] = []
        var t = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "\u{1}$1\u{2}", options: .regularExpression)
        while let start = t.firstIndex(of: "\u{1}"), let end = t[start...].firstIndex(of: "\u{2}") {
            codes.append(String(t[t.index(after: start)..<end]))
            t.replaceSubrange(start...end, with: "\u{3}\(codes.count - 1)\u{3}")
        }
        t = XML.escape(t)
        t = t.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)\s]+)(\s+&quot;[^)]*&quot;)?\)"#, with: "\u{4}$1\u{5}$2\u{6}", options: .regularExpression)
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#, "<a href=\"$2\">$1</a>"),
            (#"&lt;(https?://[^&\s]+)&gt;"#, "<a href=\"$1\">$1</a>"),
            (#"\*\*\*([^*]+)\*\*\*"#, "<strong><em>$1</em></strong>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"(?<![\w*])\*([^*\s][^*]*)\*"#, "<em>$1</em>"),
            (#"(?<![\w_])_([^_\s][^_]*)_(?!\w)"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>"),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Images: resolve relative paths against the Markdown file's folder.
        while let start = t.firstIndex(of: "\u{4}"), let mid = t[start...].firstIndex(of: "\u{5}"),
              let end = t[mid...].firstIndex(of: "\u{6}") {
            let alt = String(t[t.index(after: start)..<mid])
            var src = String(t[t.index(after: mid)..<end])
            if let base, !src.contains("://"), !src.hasPrefix("data:") {
                src = URL(fileURLWithPath: src.removingPercentEncoding ?? src, relativeTo: base).standardizedFileURL.absoluteString
            }
            t.replaceSubrange(start...end, with: "<img alt=\"\(alt)\" src=\"\(src)\"/>")
        }
        for (i, code) in codes.enumerated() {
            t = t.replacingOccurrences(of: "\u{3}\(i)\u{3}", with: "<code>\(XML.escape(code))</code>")
        }
        return t
    }
}

// MARK: - EPUB

enum EPUB {
    /// Unpacks an EPUB and joins its chapters (in reading order) into one HTML file inside `dir`.
    static func readHTML(_ src: URL, into dir: URL) throws -> URL {
        let root = dir.appendingPathComponent("book", isDirectory: true)
        try Zip.extract(src, to: root)
        let container = try String(contentsOf: root.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = firstMatch(#"full-path="([^"]+)""#, in: container) else { throw FlipdialError("Not a valid EPUB") }
        let opfURL = root.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)

        var manifest: [String: String] = [:]
        for item in matches(#"<item\b[^>]*>"#, in: opf) {
            if let id = firstMatch(#"\bid="([^"]+)""#, in: item), let href = firstMatch(#"\bhref="([^"]+)""#, in: item) {
                manifest[id] = href.removingPercentEncoding ?? href
            }
        }
        let spine = matches(#"<itemref\b[^>]*>"#, in: opf).compactMap { firstMatch(#"idref="([^"]+)""#, in: $0) }
        let title = firstMatch(#"<dc:title[^>]*>([^<]+)</dc:title>"#, in: opf) ?? ""

        var body = ""
        for id in spine {
            guard let href = manifest[id] else { continue }
            let chapter = opfURL.deletingLastPathComponent().appendingPathComponent(href)
            guard var xhtml = try? String(contentsOf: chapter, encoding: .utf8) else { continue }
            if let start = xhtml.range(of: #"<body[^>]*>"#, options: .regularExpression),
               let end = xhtml.range(of: "</body>", options: .backwards) {
                xhtml = String(xhtml[start.upperBound..<end.lowerBound])
            }
            // Point images at the extracted files.
            let folder = chapter.deletingLastPathComponent()
            for src in Set(matches(#"(?:src|xlink:href)="([^"]+)""#, in: xhtml, group: 1)) where !src.contains("://") {
                let absolute = URL(fileURLWithPath: src.removingPercentEncoding ?? src, relativeTo: folder).standardizedFileURL.absoluteString
                xhtml = xhtml.replacingOccurrences(of: "\"\(src)\"", with: "\"\(absolute)\"")
            }
            body += xhtml + "\n"
        }
        let out = dir.appendingPathComponent("book.html")
        try Markdown.page(body, title: title).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Writes an EPUB 3 book from an XHTML body fragment. Local images referenced by file URL are embedded.
    static func write(title: String, body: String, to out: URL) throws {
        var body = body
        var files: [String: Data] = [:]
        var manifestImages = ""
        var n = 0
        for src in Set(matches(#"src="(file://[^"]+)""#, in: body, group: 1)) {
            guard let url = URL(string: src), let data = try? Data(contentsOf: url) else { continue }
            n += 1
            let ext = url.pathExtension.lowercased().isEmpty ? "png" : url.pathExtension.lowercased()
            let name = "images/img\(n).\(ext)"
            files["OEBPS/\(name)"] = data
            let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp"][ext] ?? "image/png"
            manifestImages += "<item id=\"img\(n)\" href=\"\(name)\" media-type=\"\(mime)\"/>\n"
            body = body.replacingOccurrences(of: "\"\(src)\"", with: "\"\(name)\"")
        }
        let headings = matches(#"<h[12][^>]*>(.*?)</h[12]>"#, in: body, group: 1)
            .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
        let toc = (headings.isEmpty ? [title] : headings).map { "<li><a href=\"chapter.xhtml\">\($0)</a></li>" }.joined()
        let date = ISO8601DateFormatter().string(from: Date()).prefix(19) + "Z"

        let text: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": XML.header + """
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """,
            "OEBPS/content.opf": XML.header + """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(XML.escape(title))</dc:title><dc:language>en</dc:language>
            <meta property="dcterms:modified">\(date)</meta>
            </metadata>
            <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            \(manifestImages)</manifest>
            <spine><itemref idref="chapter"/></spine>
            </package>
            """,
            "OEBPS/nav.xhtml": XML.header + """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(XML.escape(title))</title></head>
            <body><nav epub:type="toc"><h1>Contents</h1><ol>\(toc)</ol></nav></body></html>
            """,
            "OEBPS/chapter.xhtml": XML.header + """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(XML.escape(title))</title>
            <style>body{font-family:serif;line-height:1.5}pre{white-space:pre-wrap}img{max-width:100%}</style></head>
            <body>
            \(body)
            </body></html>
            """,
        ]
        files.merge(text.mapValues { Data($0.utf8) }) { $1 }
        try Zip.create(files, at: out, storedFirst: "mimetype")
    }

    static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.range(at: group).location == NSNotFound ? nil : ns.substring(with: $0.range(at: group))
        }
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text, group: 1).first
    }
}

// MARK: - PPTX

/// Writes a deck with one full-slide picture per image — used for PDF → PowerPoint.
enum PPTX {
    static func write(slides pngs: [(data: Data, width: Int, height: Int)], to out: URL) throws {
        guard let first = pngs.first else { throw FlipdialError("No pages to put on slides") }
        let slideW = 12_192_000
        let slideH = Int(Double(slideW) * Double(first.height) / Double(first.width))
        let ns = """
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        """
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let emptyTree = """
        <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>
        """
        var files: [String: Data] = [:]
        var text: [String: String] = [:]
        var slideOverrides = "", slideIds = "", slideRels = ""

        for (i, png) in pngs.enumerated() {
            let n = i + 1
            files["ppt/media/image\(n).png"] = png.data
            // Fit the picture inside the slide, centred.
            let scale = min(Double(slideW) / Double(png.width), Double(slideH) / Double(png.height))
            let cx = Int(Double(png.width) * scale), cy = Int(Double(png.height) * scale)
            text["ppt/slides/slide\(n).xml"] = XML.header + """
            <p:sld \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\
            <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr><a:xfrm><a:off x="\((slideW - cx) / 2)" y="\((slideH - cy) / 2)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
            text["ppt/slides/_rels/slide\(n).xml.rels"] = XML.header + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
            <Relationship Id="rId2" Type="\(rel)/image" Target="../media/image\(n).png"/></Relationships>
            """
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            slideIds += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 2)\"/>"
            slideRels += "<Relationship Id=\"rId\(n + 2)\" Type=\"\(rel)/slide\" Target=\"slides/slide\(n).xml\"/>"
        }

        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let colors = [("accent1", "4472C4"), ("accent2", "ED7D31"), ("accent3", "A5A5A5"), ("accent4", "FFC000"),
                      ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")]
            .map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()

        text["[Content_Types].xml"] = XML.header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
        \(slideOverrides)</Types>
        """
        text["_rels/.rels"] = XML.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """
        text["ppt/presentation.xml"] = XML.header + """
        <p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(slideIds)</p:sldIdLst><p:sldSz cx="\(slideW)" cy="\(slideH)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
        text["ppt/_rels/presentation.xml.rels"] = XML.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
        <Relationship Id="rId2" Type="\(rel)/theme" Target="theme/theme1.xml"/>\(slideRels)</Relationships>
        """
        text["ppt/slideMasters/slideMaster1.xml"] = XML.header + """
        <p:sldMaster \(ns)><p:cSld>\(emptyTree)</p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
        accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """
        text["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = XML.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="\(rel)/theme" Target="../theme/theme1.xml"/></Relationships>
        """
        text["ppt/slideLayouts/slideLayout1.xml"] = XML.header + """
        <p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank">\(emptyTree)</p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
        text["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = XML.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """
        text["ppt/theme/theme1.xml"] = XML.header + """
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Flipdial"><a:themeElements>\
        <a:clrScheme name="Flipdial"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
        <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2>\
        <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>\(colors)</a:clrScheme>\
        <a:fontScheme name="Flipdial"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="Flipdial"><a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst>\
        <a:lnStyleLst><a:ln w="6350">\(solid)</a:ln><a:ln w="12700">\(solid)</a:ln><a:ln w="19050">\(solid)</a:ln></a:lnStyleLst>\
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
        <a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
        files.merge(text.mapValues { Data($0.utf8) }) { $1 }
        try Zip.create(files, at: out)
    }
}

// MARK: - DOCX

/// Writes Word documents from structured text: styled headings, lists, links, quotes, code,
/// tables and images. (Cocoa's own DOCX writer silently drops tables and images.)
enum DOCXWriter {
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func write(_ blocks: [TextBlock], to out: URL) throws {
        var body = ""
        var rels = ""
        var media: [String: Data] = [:]
        var relCount = 3            // rId1 styles, rId2 numbering, rId3 settings
        var drawingId = 0
        var numberedLists = 0
        var previous: TextBlock.Kind? = nil

        func nextRel(_ type: String, _ target: String, external: Bool = false) -> String {
            relCount += 1
            rels += "<Relationship Id=\"rId\(relCount)\" Type=\"\(rel)/\(type)\" Target=\"\(XML.escape(target))\"\(external ? " TargetMode=\"External\"" : "")/>"
            return "rId\(relCount)"
        }

        /// Heading sizes are repeated on the runs as well as in the style, because some readers
        /// (including Cocoa's) ignore paragraph styles.
        func runs(_ runs: [TextBlock.Run], bold: Bool = false, size: Int? = nil) -> String {
            runs.map { run in
                var props = ""
                if run.bold || bold { props += "<w:b/>" }
                if let size { props += "<w:sz w:val=\"\(size)\"/>" }
                if run.italic { props += "<w:i/>" }
                if run.code { props += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/><w:sz w:val=\"19\"/>" }
                if run.link != nil { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
                let r = "<w:r>\(props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>")<w:t xml:space=\"preserve\">\(XML.escape(run.text))</w:t></w:r>"
                if let link = run.link, link.contains(":") {
                    return "<w:hyperlink r:id=\"\(nextRel("hyperlink", link, external: true))\">\(r)</w:hyperlink>"
                }
                return r
            }.joined()
        }

        func paragraph(_ content: String, style: String? = nil, extra: String = "") -> String {
            let props = (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "") + extra
            return "<w:p>\(props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>")\(content)</w:p>"
        }

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                body += paragraph(runs(block.runs, bold: true, size: [36, 30, 26][min(level, 3) - 1]), style: "Heading\(min(level, 3))")
            case .paragraph:
                body += paragraph(runs(block.runs))
            case .quote:
                body += paragraph(runs(block.runs), style: "Quote")
            case .code:
                for line in block.plainText.components(separatedBy: "\n") {
                    body += paragraph(runs([TextBlock.Run(text: line, code: true)]), style: "Code")
                }
            case .bullet(let level):
                body += paragraph(runs(block.runs), style: "ListParagraph",
                                  extra: "<w:numPr><w:ilvl w:val=\"\(min(level, 3) - 1)\"/><w:numId w:val=\"1\"/></w:numPr>")
            case .numbered(let level):
                // Each separate numbered list restarts at 1.
                if case .numbered = previous {} else { numberedLists += 1 }
                body += paragraph(runs(block.runs), style: "ListParagraph",
                                  extra: "<w:numPr><w:ilvl w:val=\"\(min(level, 3) - 1)\"/><w:numId w:val=\"\(numberedLists + 1)\"/></w:numPr>")
            case .table:
                let width = block.rows.map(\.count).max() ?? 0
                guard width > 0 else { break }
                let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"AAAAAA\""
                body += "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
                    + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) \(border)/>" }.joined()
                    + "</w:tblBorders><w:tblCellMar><w:left w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"80\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
                    + String(repeating: "<w:gridCol/>", count: width) + "</w:tblGrid>"
                for (r, row) in block.rows.enumerated() {
                    body += "<w:tr>"
                    for c in 0..<width {
                        let value = c < row.count ? row[c] : ""
                        body += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>"
                            + paragraph(runs([TextBlock.Run(text: value)], bold: r == 0)) + "</w:tc>"
                    }
                    body += "</w:tr>"
                }
                body += "</w:tbl>" + paragraph("")
            case .image:
                guard let image = block.image else { break }
                drawingId += 1
                let name = "image\(drawingId).png"
                media["word/media/\(name)"] = image.png
                let id = nextRel("image", "media/\(name)")
                let maxW = 5_943_600.0 // 6.5" in EMU
                let scale = min(maxW / (Double(image.width) * 9525), 1)
                let cx = Int(Double(image.width) * 9525 * scale), cy = Int(Double(image.height) * 9525 * scale)
                body += paragraph("""
                <w:r><w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(drawingId)" name="Picture \(drawingId)"/>\
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
                <pic:pic><pic:nvPicPr><pic:cNvPr id="\(drawingId)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
                """)
            }
            previous = block.kind
        }

        var files: [String: Data] = media
        let text: [String: String] = [
            "[Content_Types].xml": XML.header + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
            <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/></Types>
            """,
            "_rels/.rels": XML.header + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/_rels/document.xml.rels": XML.header + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(rel)/styles" Target="styles.xml"/>\
            <Relationship Id="rId2" Type="\(rel)/numbering" Target="numbering.xml"/>\
            <Relationship Id="rId3" Type="\(rel)/settings" Target="settings.xml"/>\(rels)</Relationships>
            """,
            "word/settings.xml": XML.header + """
            <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/></w:settings>
            """,
            "word/document.xml": XML.header + """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="\(rel)" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
            w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
            """,
            "word/styles.xml": styles,
            "word/numbering.xml": numbering(numberedLists: numberedLists),
        ]
        files.merge(text.mapValues { Data($0.utf8) }) { $1 }
        try Zip.create(files, at: out)
    }

    private static var styles: String {
        func heading(_ n: Int, _ size: Int) -> String {
            """
            <w:style w:type="paragraph" w:styleId="Heading\(n)"><w:name w:val="heading \(n)"/><w:basedOn w:val="Normal"/>\
            <w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="\(360 - n * 60)" w:after="120"/>\
            <w:outlineLvl w:val="\(n - 1)"/></w:pPr><w:rPr><w:b/><w:sz w:val="\(size)"/></w:rPr></w:style>
            """
        }
        return XML.header + """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>\
        <w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/>\
        </w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        \(heading(1, 36))\(heading(2, 30))\(heading(3, 26))\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="60"/><w:contextualSpacing/></w:pPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/><w:sz w:val="19"/></w:rPr></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        </w:styles>
        """
    }

    /// numId 1 is the bullet list; numbered lists get numIds 2… each with its own definition so
    /// every list restarts at 1.
    private static func numbering(numberedLists: Int) -> String {
        func levels(_ format: String) -> String {
            (0..<3).map { l in
                let text = format == "bullet" ? ["•", "◦", "▪"][l] : "%\(l + 1)."
                return "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format == "bullet" ? "bullet" : ["decimal", "lowerLetter", "lowerRoman"][l])\"/>"
                    + "<w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (l + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        var abstracts = "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels("bullet"))</w:abstractNum>"
        var nums = "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for n in 0..<numberedLists {
            abstracts += "<w:abstractNum w:abstractNumId=\"\(n + 1)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels("decimal"))</w:abstractNum>"
            nums += "<w:num w:numId=\"\(n + 2)\"><w:abstractNumId w:val=\"\(n + 1)\"/></w:num>"
        }
        return XML.header + """
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(abstracts)\(nums)</w:numbering>
        """
    }
}
