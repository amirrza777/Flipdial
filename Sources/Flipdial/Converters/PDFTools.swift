import AppKit
import PDFKit

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw FlipdialError("Can't open \(url.lastPathComponent)") }
        if doc.isLocked { throw FlipdialError("\(url.lastPathComponent) is password-protected. Use Remove Password first.") }
        return doc
    }

    // MARK: Rendering

    static func image(of page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        var size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: size)
        return thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Renders every page. One page → `destination`; several → a folder of numbered images beside it.
    @discardableResult
    static func renderPages(_ pdf: URL, ext: String, destination: URL) async throws -> URL {
        let doc = try open(pdf)
        let dpi = Prefs.pdfDPI
        if doc.pageCount == 1, let page = doc.page(at: 0), let cg = image(of: page, dpi: dpi) {
            try await ImageKit.save(cg, to: destination, ext: ext)
            return destination
        }
        let folder = try Output.folder(for: destination, suffix: " (pages)")
        let base = destination.deletingPathExtension().lastPathComponent
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let cg = image(of: page, dpi: dpi) else { continue }
            let number = String(format: "%0\(digits)d", i + 1)
            try await ImageKit.save(cg, to: folder.appendingPathComponent("\(base)-\(number).\(ext)"), ext: ext)
        }
        return folder
    }

    // MARK: Text

    /// Text with styling; falls back to OCR for scanned PDFs without a text layer.
    static func attributedText(_ url: URL) throws -> NSAttributedString {
        let doc = try open(url)
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.attributedString else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(text)
        }
        if result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSAttributedString(string: try ocrText(doc),
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        return result
    }

    static func ocrText(_ doc: PDFDocument) throws -> String {
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let cg = image(of: page, dpi: 200) else { continue }
            pages.append(try ImageKit.recognizeText(in: cg))
        }
        return pages.joined(separator: "\n\n")
    }

    // MARK: Conversions

    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let out = Output.url(for: src, ext: ext)
        switch ext {
        case "jpg", "png", "heic", "tiff":
            return try await renderPages(src, ext: ext, destination: out)
        case "txt":
            let doc = try open(src)
            var text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = try ocrText(doc) }
            try text.write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try Semantic.markdown(Semantic.blocks(from: try attributedText(src))).write(to: out, atomically: true, encoding: .utf8)
        case "pptx":
            try pptx(src, out: out)
        case "xlsx":
            try SheetKit.writeXLSX(try tables(src), to: out)
        case "csv":
            return try await SheetKit.write(try tables(src), to: out, ext: "csv", title: Output.baseName(src))
        default:
            return try await DocKit.write(try attributedText(src), to: out, ext: ext, title: Output.baseName(src))
        }
        return out
    }

    // MARK: Tables

    /// Rebuilds table rows and columns from where each character sits on the page: big horizontal
    /// gaps start a new cell, and cells are snapped to column positions shared across the page.
    static func tables(_ src: URL) throws -> [Sheet] {
        let doc = try open(src)
        var sheets: [Sheet] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p), page.numberOfCharacters > 0 else { continue }
            let rows = tableRows(on: page)
            if !rows.isEmpty { sheets.append(Sheet(name: "Page \(p + 1)", rows: rows)) }
        }
        guard !sheets.isEmpty else { throw FlipdialError("No text found — scanned PDFs need OCR (convert to Text first)") }
        if sheets.count == 1 { sheets[0].name = "Sheet1" }
        return sheets
    }

    private struct Glyph { let char: String; let rect: CGRect }
    private struct Cell {
        let minX: CGFloat
        var maxX: CGFloat
        var words: [(x: CGFloat, maxX: CGFloat, text: String)]
        var text: String { words.map(\.text).joined(separator: " ") }
    }

    private static func tableRows(on page: PDFPage) -> [[String]] {
        var glyphs: [Glyph] = []
        // page.string contains synthesized line breaks that have no character box, so walk the text
        // and only advance the box index for real characters.
        let text = (page.string ?? "") as NSString
        var boxIndex = 0
        for i in 0..<text.length {
            let char = text.substring(with: NSRange(location: i, length: 1))
            if char == "\n" || char == "\r" { continue }
            let rect = page.characterBounds(at: boxIndex)
            boxIndex += 1
            guard rect.width > 0, rect.height > 0, !char.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            glyphs.append(Glyph(char: char, rect: rect))
        }
        guard !glyphs.isEmpty else { return [] }

        // Group characters into visual lines (top of page first) by vertical overlap, so small
        // marks like commas that sit low in their box stay on their line.
        glyphs.sort { $0.rect.midY > $1.rect.midY }
        var lines: [[Glyph]] = []
        var lineMinY: CGFloat = 0, lineMaxY: CGFloat = 0
        for glyph in glyphs {
            if !lines.isEmpty, glyph.rect.maxY >= lineMinY, glyph.rect.minY <= lineMaxY {
                lines[lines.count - 1].append(glyph)
                lineMinY = min(lineMinY, glyph.rect.minY)
            } else {
                lines.append([glyph])
                lineMinY = glyph.rect.minY
                lineMaxY = glyph.rect.maxY
            }
        }

        // Words, then cells: a gap much wider than a space starts a new cell.
        var cellRows: [[Cell]] = []
        for line in lines {
            let sorted = line.sorted { $0.rect.minX < $1.rect.minX }
            let heights = sorted.map { $0.rect.height }.sorted()
            let h = max(heights[heights.count / 2], heights.last! * 0.8)
            var cells: [Cell] = []
            var previous: Glyph? = nil
            for glyph in sorted {
                let gap = previous.map { glyph.rect.minX - $0.rect.maxX } ?? .infinity
                if gap > max(h * 0.9, 5) {
                    cells.append(Cell(minX: glyph.rect.minX, maxX: glyph.rect.maxX, words: [(glyph.rect.minX, glyph.rect.maxX, glyph.char)]))
                } else {
                    if gap > h * 0.12 {
                        cells[cells.count - 1].words.append((glyph.rect.minX, glyph.rect.maxX, glyph.char))
                    } else {
                        let w = cells[cells.count - 1].words.count - 1
                        cells[cells.count - 1].words[w].text += glyph.char
                        cells[cells.count - 1].words[w].maxX = glyph.rect.maxX
                    }
                    cells[cells.count - 1].maxX = glyph.rect.maxX
                }
                previous = glyph
            }
            cellRows.append(cells)
        }

        // A right-aligned number can sit one normal space before the next column. Split a cell
        // where a word starts at an x where cells start in at least two other rows.
        var starts: [(x: CGFloat, row: Int)] = []
        for (r, cells) in cellRows.enumerated() { for cell in cells { starts.append((cell.minX, r)) } }
        func isColumnStart(_ x: CGFloat, excluding row: Int) -> Bool {
            Set(starts.filter { abs($0.x - x) <= 2 && $0.row != row }.map(\.row)).count >= 2
        }
        cellRows = cellRows.enumerated().map { r, cells in
            cells.flatMap { cell -> [Cell] in
                var parts: [Cell] = []
                for (k, word) in cell.words.enumerated() {
                    if k == 0 || isColumnStart(word.x, excluding: r) {
                        parts.append(Cell(minX: word.x, maxX: word.maxX, words: [word]))
                    } else {
                        parts[parts.count - 1].words.append(word)
                        parts[parts.count - 1].maxX = word.maxX
                    }
                }
                return parts
            }
        }

        // Columns: merge overlapping cell extents into bands (ignoring titles that span the page)…
        let pageWidth = page.bounds(for: .mediaBox).width
        var bands: [(minX: CGFloat, maxX: CGFloat, rows: Set<Int>)] = []
        var placed: [(row: Int, cell: Cell)] = []
        for (r, cells) in cellRows.enumerated() {
            for cell in cells where cell.maxX - cell.minX < pageWidth * 0.45 { placed.append((r, cell)) }
        }
        placed.sort { $0.cell.minX < $1.cell.minX }
        for item in placed {
            if let last = bands.last, item.cell.minX <= last.maxX + 2 {
                bands[bands.count - 1].maxX = max(last.maxX, item.cell.maxX)
                bands[bands.count - 1].rows.insert(item.row)
            } else {
                bands.append((item.cell.minX, item.cell.maxX, [item.row]))
            }
        }
        // …then join neighbouring bands that never share a row: a left-aligned header above
        // right-aligned numbers is one column even though their extents don't overlap.
        var merged: [(minX: CGFloat, maxX: CGFloat, rows: Set<Int>)] = []
        for band in bands {
            if let last = merged.last, last.rows.isDisjoint(with: band.rows) {
                merged[merged.count - 1] = (last.minX, band.maxX, last.rows.union(band.rows))
            } else {
                merged.append(band)
            }
        }
        if merged.isEmpty { merged = [(0, pageWidth, [])] }

        return cellRows.map { cells in
            var row = Array(repeating: "", count: merged.count)
            for cell in cells {
                let column = merged.firstIndex { cell.minX <= $0.maxX + 2 && cell.maxX >= $0.minX - 2 }
                    ?? nearestBand(to: (cell.minX + cell.maxX) / 2, in: merged.map { ($0.minX + $0.maxX) / 2 })
                row[column] += row[column].isEmpty ? cell.text : " " + cell.text
            }
            while row.last?.isEmpty == true { row.removeLast() }
            return row
        }
    }

    private static func nearestBand(to x: CGFloat, in centres: [CGFloat]) -> Int {
        var best = 0
        for (i, centre) in centres.enumerated() where abs(centre - x) < abs(centres[best] - x) { best = i }
        return best
    }

    /// One slide per page, each holding the page rendered as an image.
    private static func pptx(_ src: URL, out: URL) throws {
        let doc = try open(src)
        var slides: [(data: Data, width: Int, height: Int)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let cg = image(of: page, dpi: 200) else { continue }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, ImageKit.flattened(cg), nil)
            CGImageDestinationFinalize(dest)
            slides.append((data as Data, cg.width, cg.height))
        }
        try PPTX.write(slides: slides, to: out)
    }

    // MARK: Tools

    private static func save(_ doc: PDFDocument, next src: URL, suffix: String,
                             options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        let out = Output.url(for: src, ext: "pdf", suffix: suffix)
        guard doc.write(to: out, withOptions: options) else { throw FlipdialError("Couldn't save \(out.lastPathComponent)") }
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        let doc = try open(src)
        return try save(doc, next: src, suffix: " (compressed)",
                        options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            if FileKind.kinds(of: url).contains(.image) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                let imageDoc = try open(try ImageKit.pdf(from: [url], output: tmp))
                if let page = imageDoc.page(at: 0)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                continue
            }
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        return try save(merged, next: urls[0], suffix: " (merged)")
    }

    static func split(_ src: URL) throws -> URL {
        let doc = try open(src)
        let folder = try Output.folder(for: src, suffix: " (split)")
        let base = Output.baseName(src)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: folder.appendingPathComponent("\(base)-\(String(format: "%0\(digits)d", i + 1)).pdf"))
        }
        return folder
    }

    static func rotate(_ src: URL) throws -> URL {
        let doc = try open(src)
        for i in 0..<doc.pageCount { doc.page(at: i).map { $0.rotation = ($0.rotation + 90) % 360 } }
        return try save(doc, next: src, suffix: " (rotated)")
    }

    static func reverse(_ src: URL) throws -> URL {
        let doc = try open(src)
        let reversed = PDFDocument()
        for i in stride(from: doc.pageCount - 1, through: 0, by: -1) {
            if let page = doc.page(at: i)?.copy() as? PDFPage { reversed.insert(page, at: reversed.pageCount) }
        }
        return try save(reversed, next: src, suffix: " (reversed)")
    }

    /// Parses "1-3, 5, 8-" into zero-based page indexes.
    static func pages(in spec: String, count: Int) throws -> [Int] {
        var result: [Int] = []
        for part in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let lo = Int(bounds[0]) ?? 1
            let hi = bounds.count > 1 ? (Int(bounds[1]) ?? count) : lo
            guard lo >= 1, hi <= count, lo <= hi else { throw FlipdialError("“\(part)” isn't a valid page range (1–\(count))") }
            result += (lo...hi).map { $0 - 1 }
        }
        guard !result.isEmpty else { throw FlipdialError("No pages selected") }
        return result
    }

    static func extract(_ src: URL, spec: String) throws -> URL {
        let doc = try open(src)
        let picked = PDFDocument()
        for i in try pages(in: spec, count: doc.pageCount) {
            if let page = doc.page(at: i)?.copy() as? PDFPage { picked.insert(page, at: picked.pageCount) }
        }
        return try save(picked, next: src, suffix: " (pages \(spec))")
    }

    static func delete(_ src: URL, spec: String) throws -> URL {
        let doc = try open(src)
        let doomed = Set(try pages(in: spec, count: doc.pageCount))
        guard doomed.count < doc.pageCount else { throw FlipdialError("That would delete every page") }
        for i in doomed.sorted(by: >) { doc.removePage(at: i) }
        return try save(doc, next: src, suffix: " (edited)")
    }

    static func encrypt(_ src: URL, password: String) throws -> URL {
        guard !password.isEmpty else { throw FlipdialError("Password can't be empty") }
        let doc = try open(src)
        return try save(doc, next: src, suffix: " (protected)",
                        options: [.userPasswordOption: password, .ownerPasswordOption: password])
    }

    static func decrypt(_ src: URL, password: String) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw FlipdialError("Can't open \(src.lastPathComponent)") }
        if doc.isLocked && !doc.unlock(withPassword: password) { throw FlipdialError("Wrong password") }
        // Re-insert pages into a fresh document so no encryption carries over.
        let plain = PDFDocument()
        for i in 0..<doc.pageCount { if let page = doc.page(at: i)?.copy() as? PDFPage { plain.insert(page, at: plain.pageCount) } }
        return try save(plain, next: src, suffix: " (unlocked)")
    }

    static func info(_ src: URL) throws -> String {
        guard let doc = PDFDocument(url: src) else { throw FlipdialError("Can't open \(src.lastPathComponent)") }
        let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? "?"
        let words = (doc.string ?? "").split { $0.isWhitespace }.count
        return "\(doc.pageCount) pages · \(words.formatted()) words · \(size)\(doc.isEncrypted ? " · encrypted" : "")"
    }
}
