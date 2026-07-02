import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ExportModel: ObservableObject {
    @Published var fatture: [Fattura] = []
    @Published var spese: [Spesa] = []
    @Published var clienti: [Cliente] = []
    @Published var estratti: [Estratto] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true; error = nil
        do {
            async let f = HubAPI.listFatture()
            async let s = HubAPI.listSpese()
            async let c = HubAPI.listClienti()
            async let e = HubAPI.listEstratti()
            (fatture, spese, clienti, estratti) = try await (f, s, c, e)
        } catch let e { error = e.localizedDescription }
        loading = false
    }
    func cliente(_ id: String) -> Cliente? { clienti.first { $0.id == id } }

    /// "yyyy-MM" presenti nei dati, raggruppati per anno (desc) con mesi (asc)
    var periodi: [(year: Int, months: [Int])] {
        var map: [Int: Set<Int>] = [:]
        let all = fatture.compactMap { $0.data } + spese.compactMap { $0.data }
        for d in all {
            let p = d.split(separator: "-")
            if p.count >= 2, let y = Int(p[0]), let m = Int(p[1]) { map[y, default: []].insert(m) }
        }
        return map.keys.sorted(by: >).map { (year: $0, months: map[$0]!.sorted()) }
    }
}

// "2026-03-15" → "2026-03"
private func ym(_ s: String?) -> String { String((s ?? "").prefix(7)) }
// cents → "1234,56" (per CSV, no separatore migliaia, virgola decimale)
private func centsPlain(_ c: Int) -> String {
    let neg = c < 0, v = abs(c)
    return (neg ? "-" : "") + "\(v/100)," + String(format: "%02d", v % 100)
}
private func csvCell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
private let mesiIT = ["Gen","Feb","Mar","Apr","Mag","Giu","Lug","Ago","Set","Ott","Nov","Dic"]

struct ExportView: View {
    @StateObject private var model = ExportModel()
    @State private var selected: Set<String> = []
    @State private var includeFatture = true
    @State private var includeSpese = true
    @State private var includeEstratti = true
    @State private var bankFiles: [URL] = []
    @State private var exporting = false
    @State private var msg: String?

    private var filteredFatture: [Fattura] {
        includeFatture ? model.fatture.filter { selected.contains(ym($0.data)) } : []
    }
    private var filteredSpese: [Spesa] {
        includeSpese ? model.spese.filter { selected.contains(ym($0.data)) } : []
    }
    private var filteredEstratti: [Estratto] {
        includeEstratti ? model.estratti.filter { selected.contains(String(format: "%04d-%02d", $0.anno, $0.mese)) } : []
    }
    private var totFatture: Int { filteredFatture.reduce(0) { $0 + $1.totale_cents } }
    private var totSpese: Int { filteredSpese.reduce(0) { $0 + $1.importo_cents } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("EXPORT COMMERCIALISTA").font(.system(size: 15, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.titleText)
                Text("Seleziona i mesi e cosa includere, poi esporta tutto in un unico ZIP (PDF + registri CSV).")
                    .font(.system(size: 12)).foregroundStyle(Holo.subDim)

                if model.loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if let e = model.error {
                    Text("Errore: \(e)").font(.system(size: 12)).foregroundStyle(Color(hex: 0xffb3ad))
                } else {
                    periodoCard
                    includiCard
                    bancaCard
                    anteprimaCard
                }
                if let m = msg { Text(m).font(.system(size: 11.5)).foregroundStyle(Holo.hsl(152, 75, 72)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task { await model.load() }
    }

    // ── Periodo: griglia mesi ──
    private var periodoCard: some View {
        card {
            HStack {
                cardLabel("PERIODO")
                Spacer()
                preset("Mese scorso") { selectRelative(months: -1, count: 1) }
                preset("Trimestre") { selectQuarter() }
                preset("Anno") { selectYear() }
                preset("Nessuno") { selected.removeAll() }
            }
            if model.periodi.isEmpty {
                Text("Nessuna fattura/spesa ancora.").font(.system(size: 12)).foregroundStyle(Holo.labelDim)
            }
            ForEach(model.periodi, id: \.year) { p in
                HStack(alignment: .center, spacing: 12) {
                    Text(String(p.year)).font(.system(size: 13, weight: .heavy)).foregroundStyle(Holo.hsl(217, 80, 74))
                        .frame(width: 46, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                        ForEach(p.months, id: \.self) { m in monthChip(p.year, m) }
                    }
                }
            }
        }
    }
    private func monthChip(_ year: Int, _ month: Int) -> some View {
        let key = "\(year)-" + String(format: "%02d", month)
        let on = selected.contains(key)
        return Button { if on { selected.remove(key) } else { selected.insert(key) } } label: {
            Text(mesiIT[month - 1]).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : Holo.subDim)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Holo.hsl(217, 70, 48) : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                    on ? Holo.hsl(217, 80, 62) : Color.white.opacity(0.1), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // ── Includi ──
    private var includiCard: some View {
        card {
            cardLabel("INCLUDI")
            checkRow("Fatture emesse (attive)", count: model.fatture.filter { selected.contains(ym($0.data)) }.count, on: $includeFatture)
            checkRow("Spese (fatture ricevute)", count: model.spese.filter { selected.contains(ym($0.data)) }.count, on: $includeSpese)
            checkRow("Estratti conto (banca)", count: model.estratti.filter { selected.contains(String(format: "%04d-%02d", $0.anno, $0.mese)) }.count, on: $includeEstratti)
        }
    }
    private func checkRow(_ label: String, count: Int, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: on.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(on.wrappedValue ? Holo.hsl(152, 80, 60) : Holo.labelDim)
                Text(label).font(.system(size: 13)).foregroundStyle(Holo.text)
                Spacer()
                Text("\(count) nel periodo").font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
        }.buttonStyle(.plain)
    }

    // ── Estratto conto (opzionale) ──
    private var bancaCard: some View {
        card {
            HStack {
                cardLabel("FILE EXTRA (OPZIONALE)")
                Spacer()
                MenuPillButton(label: "Allega", icon: "plus") { pickBank() }
            }
            if bankFiles.isEmpty {
                Text("Gli estratti conto archiviati dei mesi scelti sono già inclusi in automatico. Qui allega solo file extra (es. un documento aggiuntivo per il commercialista).")
                    .font(.system(size: 11.5)).foregroundStyle(Holo.labelDim)
            } else {
                ForEach(bankFiles, id: \.self) { u in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill").font(.system(size: 11)).foregroundStyle(Holo.hsl(217, 80, 72))
                        Text(u.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(Holo.text).lineLimit(1)
                        Spacer()
                        Button { bankFiles.removeAll { $0 == u } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Holo.labelDim)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // ── Anteprima + esporta ──
    private var anteprimaCard: some View {
        card {
            cardLabel("ANTEPRIMA")
            HStack(spacing: 22) {
                stat("\(filteredFatture.count)", "FATTURE", Money.eur(totFatture), Holo.hsl(217, 85, 70))
                stat("\(filteredSpese.count)", "SPESE", Money.eur(totSpese), Holo.hsl(38, 85, 68))
                Spacer()
                MenuPillButton(label: exporting ? "Creo ZIP…" : "Esporta ZIP",
                               icon: exporting ? "hourglass" : "square.and.arrow.up",
                               disabled: exporting || selected.isEmpty || (filteredFatture.isEmpty && filteredSpese.isEmpty)) {
                    startExport()
                }
            }
        }
    }
    private func stat(_ v: String, _ label: String, _ tot: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 22, weight: .black)).foregroundStyle(color)
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2).foregroundStyle(Holo.labelDim)
            Text(tot).font(.system(size: 11, weight: .semibold)).foregroundStyle(Holo.subDim)
        }
    }

    // ── helper UI ──
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
    }
    private func cardLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Holo.hsl(217, 85, 70))
    }
    private func preset(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Holo.subDim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // ── preset logica ──
    private func selectRelative(months offset: Int, count: Int) {
        let cal = Calendar.current
        guard let base = cal.date(byAdding: .month, value: offset, to: Date()) else { return }
        selected.removeAll()
        for i in 0..<count {
            if let d = cal.date(byAdding: .month, value: -i, to: base) {
                selected.insert("\(cal.component(.year, from: d))-" + String(format: "%02d", cal.component(.month, from: d)))
            }
        }
    }
    private func selectQuarter() {
        let cal = Calendar.current; let now = Date()
        let m = cal.component(.month, from: now), y = cal.component(.year, from: now)
        let startM = ((m - 1) / 3) * 3 + 1
        selected = Set((startM..<startM + 3).map { "\(y)-" + String(format: "%02d", $0) })
    }
    private func selectYear() {
        let y = Calendar.current.component(.year, from: Date())
        if let p = model.periodi.first(where: { $0.year == y }) {
            selected = Set(p.months.map { "\(y)-" + String(format: "%02d", $0) })
        }
    }

    private func pickBank() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .commaSeparatedText, .plainText, .spreadsheet, .data]
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { for u in p.urls where !bankFiles.contains(u) { bankFiles.append(u) } }
    }

    // ── export ──
    private var folderName: String {
        let s = selected.sorted()
        let suffix = (s.first == s.last) ? (s.first ?? "") : "\(s.first ?? "")_\(s.last ?? "")"
        return "Export_\(suffix)"
    }
    private func startExport() {
        let sp = NSSavePanel()
        sp.nameFieldStringValue = "\(folderName).zip"
        sp.allowedContentTypes = [.zip]
        if sp.runModal() == .OK, let url = sp.url { Task { await runExport(to: url) } }
    }
    /// Nome file sicuro per lo ZIP: sempre un singolo componente, mai traversal, mai vuoto.
    private func safeName(_ s: String) -> String {
        var n = (s as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "file" : n
    }
    private func runExport(to dest: URL) async {
        exporting = true; defer { exporting = false }
        msg = nil
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString.prefix(6))")
        let root = tmp.appendingPathComponent(folderName)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if includeFatture {
                let dir = root.appendingPathComponent("fatture")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in filteredFatture {
                    if let p = f.pdf_path, let d = try? await HubAPI.downloadFatturaPDF(path: p) {
                        try? d.write(to: dir.appendingPathComponent("\(f.numeroCompleto).pdf"))
                    }
                }
                try csvFatture().data(using: .utf8)?.write(to: root.appendingPathComponent("registro_fatture.csv"))
            }
            if includeSpese {
                let dir = root.appendingPathComponent("spese")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for s in filteredSpese {
                    if let p = s.file_path, let d = try? await HubAPI.downloadSpesaFile(path: p) {
                        let ext = (p as NSString).pathExtension
                        let nm = safeName("\((s.fornitore ?? "spesa"))-\(s.id.prefix(6)).\(ext.isEmpty ? "pdf" : ext)")
                        try? d.write(to: dir.appendingPathComponent(nm))
                    }
                }
                try csvSpese().data(using: .utf8)?.write(to: root.appendingPathComponent("registro_spese.csv"))
            }
            if !filteredEstratti.isEmpty || !bankFiles.isEmpty {
                let dir = root.appendingPathComponent("estratto_conto")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for e in filteredEstratti {
                    if let p = e.file_path, let d = try? await HubAPI.downloadEstrattoFile(path: p) {
                        let ext = (p as NSString).pathExtension
                        let nm = safeName("estratto-\(e.anno)-\(String(format: "%02d", e.mese))" + (ext.isEmpty ? "" : ".\(ext)"))
                        try? d.write(to: dir.appendingPathComponent(nm))
                    }
                }
                for u in bankFiles { try? fm.copyItem(at: u, to: dir.appendingPathComponent(safeName(u.lastPathComponent))) }
            }
            try? fm.removeItem(at: dest)   // zip non sovrascrive bene
            let folder = folderName
            let status: Int32 = await Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                proc.currentDirectoryURL = tmp
                proc.arguments = ["-r", "-q", dest.path, folder]
                do { try proc.run() } catch { return -1 }
                proc.waitUntilExit()
                return proc.terminationStatus
            }.value
            try? fm.removeItem(at: tmp)
            if status == 0 {
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                msg = "✓ Export creato: \(dest.lastPathComponent)"
            } else { msg = "Errore nella creazione dello ZIP (zip exit \(status))." }
        } catch { msg = "Errore export: \(error.localizedDescription)" }
    }

    private func csvFatture() -> String {
        var rows = ["Numero;Data;Cliente;P.IVA;Imponibile;IVA;Totale;Stato"]
        for f in filteredFatture.sorted(by: { ($0.data ?? "") < ($1.data ?? "") }) {
            let c = model.cliente(f.cliente_id)
            rows.append([
                f.numeroCompleto,
                dataIT(f.data),
                csvCell(c?.ragione_sociale ?? ""),
                csvCell(c?.piva ?? ""),
                centsPlain(f.imponibile_cents),
                centsPlain(f.iva_cents),
                centsPlain(f.totale_cents),
                f.stato,
            ].joined(separator: ";"))
        }
        return rows.joined(separator: "\n")
    }
    private func csvSpese() -> String {
        var rows = ["Data;Fornitore;Descrizione;Importo;IVA;Categoria"]
        for s in filteredSpese.sorted(by: { ($0.data ?? "") < ($1.data ?? "") }) {
            rows.append([
                dataIT(s.data),
                csvCell(s.fornitore ?? ""),
                csvCell(s.descrizione ?? ""),
                centsPlain(s.importo_cents),
                centsPlain(s.iva_cents),
                csvCell(s.categoria ?? ""),
            ].joined(separator: ";"))
        }
        return rows.joined(separator: "\n")
    }
}
