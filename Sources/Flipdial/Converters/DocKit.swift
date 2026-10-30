import AppKit
import PDFKit

/// Rich-text documents. Uses Cocoa's text system natively and Pandoc for Markdown/EPUB fidelity.
enum DocKit {
    static let nativeTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "rtfd": .rtfd,
        "html": .html, "htm": .html, "txt": .plain, "text": .plain, "webarchive": .webArchive,
    ]

    private static let pandocReaders: [String: String] = [
        "docx": "docx", "odt": "odt", "html": "html", "htm": "html", "md": "markdown",
        "markdown": "markdown", "epub": "epub", "rtf": "rtf", "txt": "markdown",
    ]
    private static let pandocWriters: [String: String] = [
        "docx": "docx", "odt": "odt", "html": "html", "md": "gfm", "epub": "epub", "rtf": "rtf", "txt": "plain",
    ]

    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let out = Output.url(for: src, ext: ext)

        // Pandoc is optional; when installed it gives the most faithful Markdown/EPUB conversions.
        let usesPandocFormat = ["md", "markdown", "epub"].contains(src.ext) || ["md", "epub"].contains(ext)
        if usesPandocFormat, let pandoc = Engines.path(.pandoc),
           let reader = pandocReaders[src.ext], let writer = pandocWriters[ext] {
            var args = [src.path, "-f", reader, "-t", writer, "-o", out.path, "--resource-path", src.deletingLastPathComponent().path]
            if ["html", "epub"].contains(ext) { args += ["-s", "--metadata", "title=\(Output.baseName(src))"] }
            if ext == "html" { args.append("--embed-resources") }
            try await Shell.run(pandoc, args, cwd: src.deletingLastPathComponent())
            return out
        }

        // Markdown → EPUB keeps images by going straight from the Markdown HTML.
        if ext == "epub" && ["md", "markdown"].contains(src.ext) {
            let markdown = try String(contentsOf: src, encoding: .utf8)
            try EPUB.write(title: Output.baseName(src), body: Markdown.html(markdown, base: src.deletingLastPathComponent()), to: out)
            return out
        }
        let text = try await load(src)
        // Cocoa's DOCX writer drops tables and images, which Markdown, HTML and EPUB rely on.
        if ext == "docx" && ["md", "markdown", "html", "htm", "epub"].contains(src.ext) {
            try DOCXWriter.write(Semantic.blocks(from: text), to: out)
            return out
        }
        return try await write(text, to: out, ext: ext, title: Output.baseName(src))
    }

    // MARK: Loading

    static func load(_ src: URL) async throws -> NSAttributedString {
        switch src.ext {
        case "md", "markdown":
            let markdown = try String(contentsOf: src, encoding: .utf8)
            return try await Temp.with { dir in
                let html = dir.appendingPathComponent("doc.html")
                let body = inlineImages(Markdown.html(markdown, base: src.deletingLastPathComponent()))
                try Markdown.page(body).write(to: html, atomically: true, encoding: .utf8)
                return try await loadNative(html, type: .html)
            }
        case "epub":
            return try await Temp.with { dir in
                let page = try EPUB.readHTML(src, into: dir)
                try inlineImages(try String(contentsOf: page, encoding: .utf8)).write(to: page, atomically: true, encoding: .utf8)
                return try await loadNative(page, type: .html)
            }
        case "html", "htm":
            // Neutralise dark-mode stylesheets (they'd make the text white) and add a <base> so
            // relative images still resolve from the temp copy.
            return try await Temp.with { dir in
                var source = try String(contentsOf: src, encoding: .utf8)
                    .replacingOccurrences(of: #"prefers-color-scheme:\s*dark"#, with: "prefers-color-scheme: never",
                                          options: .regularExpression)
                let base = "<base href=\"\(src.deletingLastPathComponent().absoluteString)\">"
                if let head = source.range(of: #"<head[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                    source.insert(contentsOf: base, at: head.upperBound)
                } else {
                    source = base + source
                }
                let copy = dir.appendingPathComponent("doc.html")
                try source.write(to: copy, atomically: true, encoding: .utf8)
                return try await loadNative(copy, type: .html)
            }
        case "pdf":
            return try PDFTools.attributedText(src)
        default:
            guard let type = nativeTypes[src.ext] else { throw FlipdialError("Can't read .\(src.ext) documents") }
            if (type == .docFormat || type == .openDocument), let soffice = Engines.path(.soffice) {
                // Cocoa's .doc reader is lossy; LibreOffice gives a much better DOCX to start from.
                return try await Temp.with { dir in
                    let docx = dir.appendingPathComponent(Output.baseName(src) + ".docx")
                    if (try? await Office.convert(src, filter: "docx", producedExt: "docx", to: docx, soffice: soffice)) != nil {
                        return try await loadNative(docx, type: .officeOpenXML)
                    }
                    return try await loadNative(src, type: type)
                }
            }
            return try await loadNative(src, type: type)
        }
    }

    /// The HTML importer won't read local images from other folders, so embed them as data URIs.
    static func inlineImages(_ html: String) -> String {
        var html = html
        for src in Set(EPUB.matches(#"src="(file://[^"]+)""#, in: html, group: 1)) {
            guard let url = URL(string: src), let data = try? Data(contentsOf: url), data.count < 25_000_000 else { continue }
            let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
                        "webp": "image/webp"][url.pathExtension.lowercased()] ?? "image/png"
            html = html.replacingOccurrences(of: "\"\(src)\"", with: "\"data:\(mime);base64,\(data.base64EncodedString())\"")
        }
        return html
    }

    @MainActor
    static func loadNative(_ url: URL, type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .plain || type == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        var loaded: Result<NSAttributedString, Error> = .failure(FlipdialError("Couldn't read \(url.lastPathComponent)"))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            loaded = Result { try NSAttributedString(url: url, options: options, documentAttributes: nil) }
        }
        let text = try loaded.get()
        if type == .plain {
            let styled = NSMutableAttributedString(attributedString: text)
            styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: styled.length))
            return styled
        }
        return text
    }

    // MARK: Writing

    /// Returns where the result landed — a folder when an image export spans several pages.
    @discardableResult
    static func write(_ text: NSAttributedString, to out: URL, ext: String, title: String) async throws -> URL {
        switch ext {
        case "pdf":
            try await renderPDF(text, to: out)
        case "jpg", "png":
            return try await Temp.with { dir in
                let pdf = dir.appendingPathComponent(out.deletingPathExtension().lastPathComponent + ".pdf")
                try await renderPDF(text, to: pdf)
                return try await PDFTools.renderPages(pdf, ext: ext, destination: out)
            }
        case "md":
            if let pandoc = Engines.path(.pandoc) {
                try await Temp.with { dir in
                    let html = dir.appendingPathComponent("doc.html")
                    try await writeNative(text, to: html, type: .html)
                    try await Shell.run(pandoc, [html.path, "-f", "html", "-t", "gfm", "-o", out.path], cwd: dir)
                }
            } else {
                let assets = out.deletingPathExtension().appendingPathExtension("assets")
                try Semantic.markdown(Semantic.blocks(from: text), assets: Output.unique(assets))
                    .write(to: out, atomically: true, encoding: .utf8)
            }
        case "epub":
            try EPUB.write(title: title, body: Semantic.xhtml(Semantic.blocks(from: text)), to: out)
        default:
            guard let type = nativeTypes[ext] else { throw FlipdialError("Can't write .\(ext) documents") }
            try await writeNative(text, to: out, type: type)
        }
        return out
    }

    @MainActor
    static func writeNative(_ text: NSAttributedString, to url: URL, type: NSAttributedString.DocumentType) throws {
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .plain || type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        let range = NSRange(location: 0, length: text.length)
        if type == .rtfd {
            try text.fileWrapper(from: range, documentAttributes: attrs).write(to: url, options: .atomic, originalContentsURL: nil)
        } else {
            try text.data(from: range, documentAttributes: attrs).write(to: url, options: .atomic)
        }
    }

    /// Lays text out on Letter/A4 pages (per the system default) and prints it to a PDF file.
    @MainActor
    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let margin: CGFloat = 54
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - 2 * margin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.minSize = .zero
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        // Print in light mode: uncoloured text would otherwise inherit dark mode's white.
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = .white
        view.drawsBackground = true
        view.textStorage?.setAttributedString(printable(text))
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw FlipdialError("Couldn't create the PDF")
        }
    }

    /// Gives text without an explicit colour solid black, and swaps dynamic colours for fixed ones.
    private static func printable(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor else {
                copy.addAttribute(.foregroundColor, value: NSColor.black, range: range)
                return
            }
            if color.type == .catalog {
                var fixed: NSColor = .black
                NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                    fixed = color.usingColorSpace(.sRGB) ?? .black
                }
                copy.addAttribute(.foregroundColor, value: fixed, range: range)
            }
        }
        return copy
    }

    static func wordCount(_ src: URL) async throws -> String {
        let text = try await load(src).string
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        return "\(words.formatted()) words · \(text.count.formatted()) characters · \(lines.formatted()) lines"
    }
}
