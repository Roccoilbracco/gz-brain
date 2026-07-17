import SwiftUI

// ─── Parsing estratto CSV ───
struct Movimento: Identifiable {
    let id = UUID()
    let txId: String          // ID transazione (per salvare gli abbinamenti)
    let data: String
    let amountC: Int          // cents, segno: <0 uscita, >0 entrata
    let desc: String
}

// Parser unico degli importi: vive in Money.parse (FattureModels.swift)
func parseAmountCents(_ raw: String) -> Int? { Money.parse(raw) }

private func csvSplit(_ line: String, _ delim: Character) -> [String] {
    var out: [String] = []; var cur = ""; var q = false
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if c == "\"" {
            let nxt = line.index(after: i)
            if q && nxt < line.endIndex && line[nxt] == "\"" { cur.append("\""); i = nxt }
            else { q.toggle() }
        } else if c == delim && !q { out.append(cur); cur = "" }
        else { cur.append(c) }
        i = line.index(after: i)
    }
    out.append(cur)
    return out
}

func parseBankCSV(_ text: String) -> [Movimento] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard lines.count > 1 else { return [] }
    let header = lines[0]
    let delim: Character = header.filter { $0 == ";" }.count > header.filter { $0 == "," }.count ? ";" : ","
    let cols = csvSplit(header, delim).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
    // itera le CHIAVI in ordine: la prima chiave che matcha vince (priorità reale —
    // con il loop sulle colonne "started date" batteva "completed date" perché viene prima nell'header)
    func findIdx(_ keys: [String], avoid: [String] = []) -> Int? {
        for k in keys {
            for (i, c) in cols.enumerated() where c.contains(k) && !avoid.contains(where: { c.contains($0) }) { return i }
        }
        return nil
    }
    let dateIdx = findIdx(["completed date", "date completed", "data contabile", "data valuta", "completed", "data", "date", "started"])
    let amtIdx = findIdx(["amount", "importo", "value"], avoid: ["fee", "balance", "saldo", "orig", "commission", "total"])
    let descIdx = findIdx(["description", "descrizione", "reference", "causale", "merchant", "beneficiary", "payee", "narrative"])
    let idIdx = cols.firstIndex(of: "id") ?? findIdx(["transaction id", "tx id", "trans id"])
    let stateIdx = findIdx(["state", "stato", "status"])
    // stati Revolut che NON sono movimenti reali (lista chiusa: altri istituti usano valori diversi)
    let skipStates: Set<String> = ["REVERTED", "PENDING", "DECLINED", "FAILED", "CANCELLED"]
    guard let ai = amtIdx else { return [] }
    var movs: [Movimento] = []
    for line in lines.dropFirst() {
        let cells = csvSplit(line, delim)
        guard cells.count > ai, let amt = parseAmountCents(cells[ai]), amt != 0 else { continue }
        if let si = stateIdx, cells.count > si,
           skipStates.contains(cells[si].trimmingCharacters(in: .whitespaces).uppercased()) { continue }
        let date = String((dateIdx.flatMap { cells.count > $0 ? cells[$0] : nil } ?? "").prefix(10))
        let desc = (descIdx.flatMap { cells.count > $0 ? cells[$0] : nil } ?? "").trimmingCharacters(in: .whitespaces)
        let tx = (idIdx.flatMap { cells.count > $0 ? cells[$0] : nil }).flatMap { $0.isEmpty ? nil : $0 } ?? "\(date)|\(amt)|\(desc)"
        movs.append(Movimento(txId: tx, data: date, amountC: amt, desc: desc))
    }
    return movs
}

// ─── Riconciliazione ───
struct Riconc {
    var totMov = 0, matched = 0, ignorati = 0
    var mancanti: [(mov: Movimento, nota: String)] = []
    var fattureNonPagate: [Fattura] = []
    var speseNonPagate: [Spesa] = []
    var speseLibere: [Spesa] = []      // candidati per abbinare un'uscita
    var fattureLibere: [Fattura] = []  // candidati per abbinare un'entrata
}

// "2026-02-06" → 20260206 (monotonico, per misurare la vicinanza tra date)
private func ymdOrd(_ s: String?) -> Int? {
    let p = (s ?? "").prefix(10).split(separator: "-")
    guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
    return y * 10000 + m * 100 + d
}
private func closestByDate<T>(_ items: [T], date: (T) -> String?, to ref: String) -> T? {
    guard let r = ymdOrd(ref) else { return items.first }
    return items.min(by: {
        abs((ymdOrd(date($0)) ?? 99_999_999) - r) < abs((ymdOrd(date($1)) ?? 99_999_999) - r)
    })
}

func reconcile(_ movs: [Movimento], fatture: [Fattura], spese: [Spesa],
               matches: [String: MovMatch], anno: Int, mese: Int) -> Riconc {
    var r = Riconc(); r.totMov = movs.count
    var usedF = Set<String>(), usedS = Set<String>()
    // pass 0 — TUTTI i match salvati bloccano i loro riferimenti: una spesa abbinata
    // sull'estratto di gennaio non deve tornare "libera" per l'auto-match di febbraio
    for mm in matches.values {
        if mm.kind == "spesa", let rid = mm.ref_id { usedS.insert(rid) }
        if mm.kind == "fattura", let rid = mm.ref_id { usedF.insert(rid) }
    }
    // pass 1 — abbinamenti manuali dei movimenti di QUESTO estratto (contatori)
    for m in movs {
        guard let mm = matches[m.txId] else { continue }
        switch mm.kind {
        case "ignora": r.ignorati += 1
        case "spesa", "fattura": if mm.ref_id != nil { r.matched += 1 }
        default: break
        }
    }
    // pass 2 — auto per i movimenti senza abbinamento manuale.
    // A parità di importo scelgo il candidato con la DATA più vicina al movimento
    // (così un movimento di febbraio prende la spesa di febbraio, non quella di gennaio
    //  con lo stesso importo: Spurio €3.300, commissione €35 si ripetono ogni mese).
    for m in movs where matches[m.txId] == nil {
        let t = abs(m.amountC)
        if m.amountC < 0 {
            let cands = spese.filter { !usedS.contains($0.id) && ($0.importo_cents + $0.iva_cents == t || $0.importo_cents == t) }
            if let s = closestByDate(cands, date: { $0.data }, to: m.data) {
                usedS.insert(s.id); r.matched += 1
            } else { r.mancanti.append((m, "Uscita senza spesa registrata")) }
        } else {
            let cands = fatture.filter { !usedF.contains($0.id) && $0.totale_cents == t }
            if let f = closestByDate(cands, date: { $0.data }, to: m.data) {
                usedF.insert(f.id); r.matched += 1
            } else { r.mancanti.append((m, "Entrata senza fattura registrata")) }
        }
    }
    r.speseLibere = spese.filter { !usedS.contains($0.id) }
    r.fattureLibere = fatture.filter { !usedF.contains($0.id) }
    let mm = String(format: "%04d-%02d", anno, mese)
    r.fattureNonPagate = r.fattureLibere.filter { ($0.data ?? "").hasPrefix(mm) }
    r.speseNonPagate = r.speseLibere.filter { ($0.data ?? "").hasPrefix(mm) }
    return r
}

// ─── Vista riconciliazione ───
struct RiconciliazioneView: View {
    let estratto: Estratto
    let fatture: [Fattura]
    let spese: [Spesa]
    @Environment(\.dismiss) private var dismiss
    @State private var movs: [Movimento] = []
    @State private var matches: [String: MovMatch] = [:]
    @State private var result: Riconc?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RICONCILIAZIONE").font(.system(size: 14, weight: .heavy)).tracking(1.5).foregroundStyle(Holo.titleText)
                if result != nil && !matches.isEmpty {
                    Button { Task { await azzera() } } label: {
                        Text("Azzera abbinamenti").font(.system(size: 10.5)).foregroundStyle(Holo.subDim)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }.buttonStyle(.plain).padding(.leading, 10)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Holo.subDim) }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 14, trailing: 22))
            Divider().overlay(Color.white.opacity(0.08))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if loading {
                        Text("Leggo l'estratto…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                    } else if let error {
                        Text(error).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xffb3ad))
                    } else if let r = result {
                        summary(r)
                        if r.mancanti.isEmpty {
                            okCard("Tutti i movimenti dell'estratto sono a posto 🎉")
                        } else {
                            sezione("⚠️ Sull'estratto ma NON registrati — abbinali a mano o ignorali", color: 0xffb46b) {
                                ForEach(r.mancanti.indices, id: \.self) { i in
                                    movRow(r.mancanti[i].mov, nota: r.mancanti[i].nota, r: r)
                                }
                            }
                        }
                        if !r.fattureNonPagate.isEmpty || !r.speseNonPagate.isEmpty {
                            sezione("Registrate ma non risultano sull'estratto di questo mese", color: 0x8fb3ff) {
                                ForEach(r.fattureNonPagate) { f in
                                    infoRow("Fattura \(f.numeroCompleto)", Money.eur(f.totale_cents), "in entrata")
                                }
                                ForEach(r.speseNonPagate) { s in
                                    infoRow("Spesa \(s.fornitore ?? "")", Money.eur(s.importo_cents + s.iva_cents), "in uscita")
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 660, height: 640)
        .background(LinearGradient(colors: [Color(red: 15/255, green: 22/255, blue: 44/255), Color(red: 8/255, green: 12/255, blue: 26/255)], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .task { await run() }
    }

    // ── dati ──
    private func run() async {
        loading = true; error = nil
        guard let path = estratto.file_path else { error = "File non disponibile."; loading = false; return }
        guard path.lowercased().hasSuffix(".csv") else {
            error = "La riconciliazione automatica funziona solo con estratti in CSV. Scarica l'estratto dalla banca in formato CSV e ricaricalo."
            loading = false; return
        }
        do {
            let data = try await HubAPI.downloadEstrattoFile(path: path)
            // UTF-8 con fallback Latin-1 (CSV di banche italiane): decodifica lossy
            // cambierebbe le descrizioni e quindi i txId derivati, perdendo gli abbinamenti
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            movs = parseBankCSV(text)
            let all = try await HubAPI.listMatches()
            matches = Dictionary(uniqueKeysWithValues: all.map { ($0.tx_id, $0) })
            if movs.isEmpty {
                error = "Non riesco a leggere i movimenti dal CSV (colonne non riconosciute)."
            } else { recompute() }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func recompute() {
        result = reconcile(movs, fatture: fatture, spese: spese, matches: matches, anno: estratto.anno, mese: estratto.mese)
    }
    private func setMatch(_ tx: String, kind: String, refId: String?) {
        matches[tx] = MovMatch(tx_id: tx, kind: kind, ref_id: refId)
        recompute()
        Task { try? await HubAPI.upsertMatch(txId: tx, kind: kind, refId: refId) }
    }
    private func azzera() async {
        // rimuove SOLO gli abbinamenti dei movimenti di questo estratto:
        // matches contiene anche quelli degli altri mesi, che restano validi
        let ids = movs.map { $0.txId }.filter { matches[$0] != nil }
        for id in ids { matches.removeValue(forKey: id) }
        recompute()
        for id in ids { try? await HubAPI.deleteMatch(txId: id) }
    }

    // ── righe ──
    private func summary(_ r: Riconc) -> some View {
        HStack(spacing: 22) {
            stat("\(r.totMov)", "MOVIMENTI", Holo.hsl(217, 80, 72))
            stat("\(r.matched)", "ABBINATI", Holo.hsl(152, 80, 64))
            stat("\(r.ignorati)", "IGNORATI", Holo.hsl(217, 20, 70))
            stat("\(r.mancanti.count)", "DA CONTROLLARE", Holo.hsl(r.mancanti.isEmpty ? 152 : 30, 85, 66))
        }
    }
    private func stat(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 23, weight: .black)).foregroundStyle(c)
            Text(l).font(.system(size: 8, weight: .heavy)).tracking(0.8).foregroundStyle(Holo.labelDim)
        }
    }
    private func sezione<C: View>(_ title: String, color: UInt32, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .heavy)).tracking(0.3).foregroundStyle(Color(hex: color))
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
    private func movRow(_ m: Movimento, nota: String, r: Riconc) -> some View {
        HStack(spacing: 12) {
            Text(m.data.isEmpty ? "—" : m.data).font(.system(size: 11)).foregroundStyle(Holo.subDim).frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.desc.isEmpty ? "(senza descrizione)" : m.desc).font(.system(size: 12)).foregroundStyle(Holo.text).lineLimit(1)
                Text(nota).font(.system(size: 9.5)).foregroundStyle(Color(hex: 0xffb46b))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(Money.eur(m.amountC)).font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(m.amountC < 0 ? Holo.hsl(2, 80, 70) : Holo.hsl(152, 80, 66))
                .frame(width: 92, alignment: .trailing)
            abbinaMenu(m, r: r)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.05)) }
    }
    private func abbinaMenu(_ m: Movimento, r: Riconc) -> some View {
        Menu {
            if m.amountC < 0 {
                if r.speseLibere.isEmpty { Text("Nessuna spesa libera") }
                ForEach(r.speseLibere) { s in
                    Button("\(s.fornitore ?? "—") — \(Money.eur(s.importo_cents + s.iva_cents))") {
                        setMatch(m.txId, kind: "spesa", refId: s.id)
                    }
                }
            } else {
                if r.fattureLibere.isEmpty { Text("Nessuna fattura libera") }
                ForEach(r.fattureLibere) { f in
                    Button("Fattura \(f.numeroCompleto) — \(Money.eur(f.totale_cents))") {
                        setMatch(m.txId, kind: "fattura", refId: f.id)
                    }
                }
            }
            Divider()
            Button("Ignora (non è una fattura/spesa)") { setMatch(m.txId, kind: "ignora", refId: nil) }
        } label: {
            HStack(spacing: 4) { Text("Abbina").font(.system(size: 10.5, weight: .semibold)); Image(systemName: "chevron.down").font(.system(size: 8)) }
                .foregroundStyle(Csb.itemFgOn).padding(.horizontal, 11).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabOn))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
    private func infoRow(_ title: String, _ amount: String, _ verso: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(Holo.text).frame(maxWidth: .infinity, alignment: .leading)
            Text(verso).font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
            Text(amount).font(.system(size: 12, weight: .semibold)).foregroundStyle(Holo.subDim)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.05)) }
    }
    private func okCard(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(Holo.hsl(152, 75, 72))
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Holo.hsl(152, 60, 40).opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Holo.hsl(152, 70, 55).opacity(0.3), lineWidth: 1))
    }
}
