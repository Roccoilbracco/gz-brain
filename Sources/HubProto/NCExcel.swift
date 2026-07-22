import Foundation

// ============================================================================
// Scrittore .xlsx minimale.
// Un file Excel è uno zip di XML: qui si costruiscono le parti indispensabili
// (content types, relazioni, workbook, fogli, stili) e si zippa con /usr/bin/zip,
// come già fa ExportView per gli archivi delle fatture.
// Niente dipendenze esterne: il file si apre in Excel, Numbers e Google Fogli.
// ============================================================================

enum XLCell {
    case text(String)
    case number(Double)
    case money(Int)          // centesimi → numero con due decimali
    case head(String)        // intestazione in grassetto
    case empty
}

struct XLSheet {
    let name: String
    var rows: [[XLCell]]
    /// Larghezze delle colonne in caratteri; opzionale.
    var widths: [Double] = []
}

enum XLSXWriter {

    static func write(_ sheets: [XLSheet], to dest: URL) throws {
        let fm = FileManager.default
        let root = appTempDir().appendingPathComponent("xlsx-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        try contentTypes(count: sheets.count).write(to: root.appendingPathComponent("[Content_Types].xml"),
                                                    atomically: true, encoding: .utf8)
        try rootRels.write(to: root.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try workbook(sheets).write(to: root.appendingPathComponent("xl/workbook.xml"),
                                   atomically: true, encoding: .utf8)
        try workbookRels(count: sheets.count).write(to: root.appendingPathComponent("xl/_rels/workbook.xml.rels"),
                                                    atomically: true, encoding: .utf8)
        try styles.write(to: root.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        for (i, s) in sheets.enumerated() {
            try sheetXML(s).write(to: root.appendingPathComponent("xl/worksheets/sheet\(i + 1).xml"),
                                  atomically: true, encoding: .utf8)
        }

        try? fm.removeItem(at: dest)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-r", "-q", "-X", dest.path, "."]
        proc.currentDirectoryURL = root
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "XLSX", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Creazione dello zip fallita (zip exit \(proc.terminationStatus))"])
        }
    }

    // ── Parti del pacchetto ──

    private static func contentTypes(count: Int) -> String {
        let sheets = (1...max(count, 1)).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets)</Types>
        """
    }

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """

    private static func workbook(_ sheets: [XLSheet]) -> String {
        let list = sheets.enumerated().map { i, s in
            "<sheet name=\"\(esc(safeName(s.name)))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(list)</sheets></workbook>
        """
    }

    private static func workbookRels(count: Int) -> String {
        let sheets = (1...max(count, 1)).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheets)\
        <Relationship Id="rId900" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """
    }

    /// Tre stili: normale (0), grassetto (1), importo con due decimali (2).
    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>\
    <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>\
    <font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
    <fills count="2"><fill><patternFill patternType="none"/></fill>\
    <fill><patternFill patternType="gray125"/></fill></fills>\
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="3">\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    </cellXfs>\
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
    </styleSheet>
    """

    private static func sheetXML(_ sheet: XLSheet) -> String {
        var cols = ""
        if !sheet.widths.isEmpty {
            let items = sheet.widths.enumerated().map { i, w in
                "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(w)\" customWidth=\"1\"/>"
            }.joined()
            cols = "<cols>\(items)</cols>"
        }
        var body = ""
        for (r, row) in sheet.rows.enumerated() {
            var cells = ""
            for (c, cell) in row.enumerated() {
                let ref = "\(colName(c))\(r + 1)"
                switch cell {
                case .empty:
                    continue
                case .text(let s):
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(s))</t></is></c>"
                case .head(let s):
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\" s=\"1\"><is><t xml:space=\"preserve\">\(esc(s))</t></is></c>"
                case .number(let n):
                    cells += "<c r=\"\(ref)\"><v>\(trim(n))</v></c>"
                case .money(let cents):
                    cells += "<c r=\"\(ref)\" s=\"2\"><v>\(trim(Double(cents) / 100))</v></c>"
                }
            }
            body += "<row r=\"\(r + 1)\">\(cells)</row>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        \(cols)<sheetData>\(body)</sheetData></worksheet>
        """
    }

    // ── Utilità ──

    /// A, B … Z, AA, AB… (oltre le 26 colonne serve la doppia lettera)
    private static func colName(_ i: Int) -> String {
        var n = i, s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    private static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Excel rifiuta i nomi foglio oltre 31 caratteri o con : \ / ? * [ ]
    private static func safeName(_ s: String) -> String {
        let clean = s.components(separatedBy: CharacterSet(charactersIn: ":\\/?*[]")).joined(separator: "-")
        return String(clean.prefix(31))
    }
}
