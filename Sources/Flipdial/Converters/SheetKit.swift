import Foundation

/// LibreOffice in headless mode, isolated from any running instance via its own profile.
enum Office {
    static func convert(_ src: URL, filter: String, producedExt: String, to out: URL, soffice: URL? = nil) async throws {
        let soffice = try soffice ?? Engines.require(.soffice)
        try await Temp.with { dir in
            try await Shell.run(soffice, ["-env:UserInstallation=file://\(dir.path)/profile", "--headless",
                                          "--convert-to", filter, "--outdir", dir.path, src.path])
            let produced = dir.appendingPathComponent(Output.baseName(src)).appendingPathExtension(producedExt)
            guard FileManager.default.fileExists(atPath: produced.path) else {
                throw FlipdialError("LibreOffice couldn't convert \(src.lastPathComponent)")
            }
            try Output.place(produced, at: out)
        }
    }
}

struct Sheet {
    var name: String
    var rows: [[String]]
}

enum SheetKit {
    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let out = Output.url(for: src, ext: ext)
        // LibreOffice keeps cell formatting, column widths and print areas when making PDFs.
        if ext == "pdf", ["xlsx", "xls", "ods"].contains(src.ext), Engines.has(.soffice) {
            try await Office.convert(src, filter: "pdf", producedExt: "pdf", to: out)
            return out
        }
        let sheets = try await read(src)
        guard sheets.contains(where: { !$0.rows.isEmpty }) else { throw FlipdialError("\(src.lastPathComponent) has no data") }
        return try await write(sheets, to: out, ext: ext, title: Output.baseName(src))
    }

    // MARK: Reading

    static func read(_ src: URL) async throws -> [Sheet] {
        let name = Output.baseName(src)
        switch src.ext {
        case "csv": return [Sheet(name: name, rows: parseDelimited(try readText(src), separator: ","))]
        case "tsv": return [Sheet(name: name, rows: parseDelimited(try readText(src), separator: "\t"))]
        case "xlsx": return try readXLSX(src)
        case "ods": return try readODS(src)
        default:
            return try await Temp.with { dir in
                let xlsx = dir.appendingPathComponent(name + ".xlsx")
                try await Office.convert(src, filter: "xlsx", producedExt: "xlsx", to: xlsx)
                return try readXLSX(xlsx)
            }
        }
    }

    private static func readText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return try String(contentsOf: url, encoding: .windowsCP1252)
    }

    /// RFC 4180-style parser: quoted fields, escaped quotes and embedded newlines.
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else if c != "\u{FEFF}" {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Writing

    /// Returns the output, which is a folder of CSV/TSV files when a workbook has several sheets.
    static func write(_ sheets: [Sheet], to out: URL, ext: String, title: String) async throws -> URL {
        let sheets = sheets.filter { !$0.rows.isEmpty }
        let single = sheets.count == 1
        switch ext {
        case "csv", "tsv":
            let separator = ext == "csv" ? "," : "\t"
            if single {
                try delimited(sheets[0].rows, separator: separator).write(to: out, atomically: true, encoding: .utf8)
                return out
            }
            let folder = try Output.folder(for: out, suffix: " (sheets)")
            for sheet in sheets {
                try delimited(sheet.rows, separator: separator)
                    .write(to: folder.appendingPathComponent(safeFileName(sheet.name) + "." + ext), atomically: true, encoding: .utf8)
            }
            return folder
        case "xlsx": try writeXLSX(sheets, to: out)
        case "ods": try writeODS(sheets, to: out)
        case "json":
            let value: Any = single ? objects(sheets[0].rows)
                : Dictionary(sheets.map { ($0.name, objects($0.rows)) }, uniquingKeysWith: { a, _ in a })
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out)
        case "md":
            let body = sheets.map { (single ? "" : "## \($0.name)\n\n") + markdownTable($0.rows) }.joined(separator: "\n")
            try body.write(to: out, atomically: true, encoding: .utf8)
        case "html":
            try html(sheets, title: title).write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            try await Temp.with { dir in
                let page = dir.appendingPathComponent("sheet.html")
                try html(sheets, title: title).write(to: page, atomically: true, encoding: .utf8)
                let text = try await DocKit.loadNative(page, type: .html)
                try await DocKit.renderPDF(text, to: out)
            }
        default:
            throw FlipdialError("Can't write .\(ext) spreadsheets")
        }
        return out
    }

    private static func safeFileName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Sheet" : cleaned
    }

    static func delimited(_ rows: [[String]], separator: String) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(separator) || cell.contains("\"") || cell.contains("\n")
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: separator)
        }.joined(separator: "\n") + "\n"
    }

    private static func objects(_ rows: [[String]]) -> [[String: String]] {
        guard let header = rows.first else { return [] }
        return rows.dropFirst().filter { $0.contains { !$0.isEmpty } }.map { row in
            var obj: [String: String] = [:]
            for (i, key) in header.enumerated() { obj[key.isEmpty ? "column\(i + 1)" : key] = i < row.count ? row[i] : "" }
            return obj
        }
    }

    static func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        let width = rows.map(\.count).max() ?? header.count
        func line(_ r: [String]) -> String {
            "| " + (0..<width).map { $0 < r.count ? r[$0].replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") : "" }
                .joined(separator: " | ") + " |"
        }
        return ([line(header), "|" + String(repeating: " --- |", count: width)] + rows.dropFirst().map(line)).joined(separator: "\n") + "\n"
    }

    static func html(_ sheets: [Sheet], title: String) -> String {
        var body = ""
        for sheet in sheets {
            if sheets.count > 1 { body += "<h2>\(XML.escape(sheet.name))</h2>\n" }
            body += "<table>\n"
            for (i, row) in sheet.rows.enumerated() {
                let tag = i == 0 ? "th" : "td"
                body += "<tr>" + row.map { "<\(tag)>\(XML.escape($0))</\(tag)>" }.joined() + "</tr>\n"
            }
            body += "</table>\n"
        }
        return Markdown.page(body, title: title)
    }

    private static func isNumber(_ value: String) -> Bool {
        guard Double(value) != nil, !value.isEmpty, !value.hasPrefix("+") else { return false }
        // Keep things like ZIP codes and phone numbers ("02139", "0044") as text.
        return !(value.hasPrefix("0") && value.count > 1 && !value.hasPrefix("0."))
    }

    // MARK: XLSX

    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
        return name
    }

    private static func xlsxSheetName(_ name: String, used: inout Set<String>) -> String {
        var clean = String(name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
        if clean.isEmpty { clean = "Sheet" }
        var candidate = clean, n = 2
        while used.contains(candidate.lowercased()) { candidate = String(clean.prefix(28)) + " \(n)"; n += 1 }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// A workbook with one worksheet per sheet and inline strings; Excel, Numbers and LibreOffice open it.
    static func writeXLSX(_ sheets: [Sheet], to out: URL) throws {
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var files: [String: String] = [:]
        var overrides = "", entries = "", rels = ""
        var used = Set<String>()
        for (i, sheet) in sheets.enumerated() {
            let n = i + 1
            var xml = XML.header + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = "\(columnName(c))\(r + 1)"
                    xml += isNumber(value)
                        ? "<c r=\"\(ref)\"><v>\(value)</v></c>"
                        : "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XML.escape(value))</t></is></c>"
                }
                xml += "</row>"
            }
            files["xl/worksheets/sheet\(n).xml"] = xml + "</sheetData></worksheet>"
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            entries += "<sheet name=\"\(XML.escape(xlsxSheetName(sheet.name, used: &used)))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            rels += "<Relationship Id=\"rId\(n)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
        }
        files["[Content_Types].xml"] = XML.header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        \(overrides)</Types>
        """
        files["_rels/.rels"] = XML.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        files["xl/workbook.xml"] = XML.header + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(rel)"><sheets>\(entries)</sheets></workbook>
        """
        files["xl/_rels/workbook.xml.rels"] = XML.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
        try Zip.create(text: files, at: out)
    }

    static func readXLSX(_ src: URL) throws -> [Sheet] {
        let dir = try Temp.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Zip.extract(src, to: dir)

        var shared: [String] = []
        if let parser = XMLParser(contentsOf: dir.appendingPathComponent("xl/sharedStrings.xml")) {
            let reader = SharedStringsReader()
            parser.delegate = reader
            parser.parse()
            shared = reader.strings
        }

        // Sheet order and names come from workbook.xml; file paths from its relationships.
        let workbook = (try? String(contentsOf: dir.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)) ?? ""
        let relsText = (try? String(contentsOf: dir.appendingPathComponent("xl/_rels/workbook.xml.rels"), encoding: .utf8)) ?? ""
        var targets: [String: String] = [:]
        for rel in EPUB.matches(#"<Relationship\b[^>]*>"#, in: relsText) {
            if let id = EPUB.firstMatch(#"\bId="([^"]+)""#, in: rel), let target = EPUB.firstMatch(#"\bTarget="([^"]+)""#, in: rel) {
                targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        var sheets: [Sheet] = []
        for entry in EPUB.matches(#"<sheet\b[^>]*>"#, in: workbook) {
            guard let name = EPUB.firstMatch(#"\bname="([^"]*)""#, in: entry),
                  let id = EPUB.firstMatch(#"\br:id="([^"]+)""#, in: entry), let path = targets[id],
                  let parser = XMLParser(contentsOf: dir.appendingPathComponent(path)) else { continue }
            let reader = SheetReader(shared: shared)
            parser.delegate = reader
            parser.parse()
            sheets.append(Sheet(name: unescape(name), rows: trimmed(reader.rows)))
        }
        guard !sheets.isEmpty else { throw FlipdialError("No worksheets found in \(src.lastPathComponent)") }
        return sheets
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Drops trailing empty cells and rows.
    private static func trimmed(_ rows: [[String]]) -> [[String]] {
        var rows = rows.map { row -> [String] in
            var row = row
            while row.last?.isEmpty == true { row.removeLast() }
            return row
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }

    private final class SharedStringsReader: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = "", inText = false
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { current = "" } else if name == "t" { inText = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inText { current += s } }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false } else if name == "si" { strings.append(current) }
        }
    }

    private final class SheetReader: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [String] = [], col = 0, type = "", value = "", capturing = false
        init(shared: [String]) { self.shared = shared }

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                row = []
                if let r = attributes["r"].flatMap(Int.init) { while rows.count < r - 1 { rows.append([]) } }
            case "c":
                type = attributes["t"] ?? ""; value = ""
                col = attributes["r"].map { SheetReader.column(of: $0) } ?? row.count
            case "v", "t": capturing = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if capturing { value += s } }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": capturing = false
            case "c":
                var text = value
                if type == "s", let i = Int(value), i < shared.count { text = shared[i] }
                if type == "b" { text = value == "1" ? "TRUE" : "FALSE" }
                while row.count < col { row.append("") }
                row.append(text)
            case "row": rows.append(row)
            default: break
            }
        }
        static func column(of ref: String) -> Int {
            ref.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
        }
    }

    // MARK: ODS

    static func writeODS(_ sheets: [Sheet], to out: URL) throws {
        var tables = ""
        for sheet in sheets {
            tables += "<table:table table:name=\"\(XML.escape(sheet.name))\">"
            let width = sheet.rows.map(\.count).max() ?? 0
            for row in sheet.rows {
                tables += "<table:table-row>"
                for c in 0..<width {
                    let value = c < row.count ? row[c] : ""
                    if value.isEmpty {
                        tables += "<table:table-cell/>"
                    } else if isNumber(value) {
                        tables += "<table:table-cell office:value-type=\"float\" office:value=\"\(value)\"><text:p>\(value)</text:p></table:table-cell>"
                    } else {
                        let paragraphs = value.components(separatedBy: "\n").map { "<text:p>\(XML.escape($0))</text:p>" }.joined()
                        tables += "<table:table-cell office:value-type=\"string\">\(paragraphs)</table:table-cell>"
                    }
                }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }
        let files: [String: String] = [
            "mimetype": "application/vnd.oasis.opendocument.spreadsheet",
            "META-INF/manifest.xml": XML.header + """
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
            <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>\
            <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
            """,
            "content.xml": XML.header + """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2">\
            <office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
            """,
        ]
        try Zip.create(text: files, at: out, storedFirst: "mimetype")
    }

    static func readODS(_ src: URL) throws -> [Sheet] {
        let dir = try Temp.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Zip.extract(src, to: dir)
        guard let parser = XMLParser(contentsOf: dir.appendingPathComponent("content.xml")) else {
            throw FlipdialError("Not a valid ODS file")
        }
        let reader = ODSReader()
        parser.delegate = reader
        parser.parse()
        return reader.sheets.map { Sheet(name: $0.name, rows: trimmed($0.rows)) }
    }

    private final class ODSReader: NSObject, XMLParserDelegate {
        var sheets: [Sheet] = []
        private var rows: [[String]] = [], row: [String] = []
        private var rowRepeat = 1, cellRepeat = 1
        private var cellValue: String? = nil, text = "", paragraphs: [String] = []
        private var inParagraph = false, inCell = false

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "table:table":
                rows = []
                sheets.append(Sheet(name: attributes["table:name"] ?? "Sheet\(sheets.count + 1)", rows: []))
            case "table:table-row":
                row = []
                rowRepeat = min(Int(attributes["table:number-rows-repeated"] ?? "1") ?? 1, 10_000)
            case "table:table-cell", "table:covered-table-cell":
                inCell = true
                paragraphs = []
                cellRepeat = min(Int(attributes["table:number-columns-repeated"] ?? "1") ?? 1, 1_000)
                switch attributes["office:value-type"] {
                case "float", "percentage", "currency": cellValue = attributes["office:value"]
                case "date": cellValue = attributes["office:date-value"]
                case "boolean": cellValue = attributes["office:boolean-value"]?.uppercased()
                default: cellValue = nil
                }
            case "text:p", "text:h":
                inParagraph = true; text = ""
            case "text:s":
                text += String(repeating: " ", count: Int(attributes["text:c"] ?? "1") ?? 1)
            case "text:tab": text += "\t"
            case "text:line-break": text += "\n"
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { if inParagraph { text += s } }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "text:p", "text:h":
                inParagraph = false
                if inCell { paragraphs.append(text) }
            case "table:table-cell", "table:covered-table-cell":
                inCell = false
                let value = cellValue ?? paragraphs.joined(separator: "\n")
                // Huge repeat counts pad the sheet to its full width; only expand cells that hold data.
                row += Array(repeating: value, count: value.isEmpty ? min(cellRepeat, 64) : cellRepeat)
            case "table:table-row":
                while row.last?.isEmpty == true { row.removeLast() }
                rows += Array(repeating: row, count: row.isEmpty ? min(rowRepeat, 64) : rowRepeat)
            case "table:table":
                if !sheets.isEmpty { sheets[sheets.count - 1].rows = rows }
            default: break
            }
        }
    }
}
