import SwiftUI

// ============================================================================
// Camere PSE — Storico contabile · MODIFICA
// L'archivio è contabilità chiusa, ma chiusa non vuol dire sbagliata per
// sempre: quando salta fuori una fattura o si scopre un doppione, la riga si
// deve poter correggere. Da qui si aggiunge, si modifica e si cancella.
//
// Resta comunque roba a parte: si scrive solo nelle tabelle `storico_*` e
// niente di quello che si tocca qui muove un saldo, una prenotazione o un
// «da incassare» della gestione viva.
// ============================================================================

extension HubAPI {
    static func creaStorico(_ tabella: String, _ f: [String: Any?]) async throws {
        try await sb.mutate(tabella, method: "POST", body: f)
    }
    static func aggiornaStorico(_ tabella: String, id: String, _ f: [String: Any?]) async throws {
        var b = f; b["updated_at"] = isoNowString()
        try await sb.mutate("\(tabella)?id=eq.\(id)", method: "PATCH", body: b)
    }
    static func cancellaStorico(_ tabella: String, id: String) async throws {
        try await sb.mutate("\(tabella)?id=eq.\(id)", method: "DELETE")
    }
}

/// Cosa si sta modificando: la tabella e, se non è nuova, la riga.
enum StoricoEditTarget: Identifiable {
    case movimento(StoricoMovimento?)
    case affitto(StoricoAffitto?)
    case spesa(StoricoSpesaAlloggio?)
    case apporto(StoricoApporto?)
    case pendente(StoricoPendente?)
    var id: String {
        switch self {
        case .movimento(let r): return "mov-" + (r?.id ?? "nuovo")
        case .affitto(let r): return "aff-" + (r?.id ?? "nuovo")
        case .spesa(let r): return "spe-" + (r?.id ?? "nuovo")
        case .apporto(let r): return "app-" + (r?.id ?? "nuovo")
        case .pendente(let r): return "pen-" + (r?.id ?? "nuovo")
        }
    }
}

// ── Campi comuni a tutte le schede ──────────────────────────────────────────
private let sTabYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

/// Da "12,50" o "12.50" ai centesimi. Accetta la virgola: qui si scrive come
/// si scrive su un foglio, non come vuole il computer.
func centesimiDa(_ testo: String) -> Int {
    let pulito = testo.replacingOccurrences(of: "€", with: "")
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: ",", with: ".")
    return Int(((Double(pulito) ?? 0) * 100).rounded())
}
func testoDa(_ cents: Int) -> String {
    String(format: "%.2f", Double(cents) / 100).replacingOccurrences(of: ".", with: ",")
}

struct StoricoEditSheet: View {
    let periodo: String
    let target: StoricoEditTarget
    let onClose: () -> Void

    @State private var data = ""
    @State private var struttura = "Via Po"
    @State private var tipo = "uscita"
    @State private var categoria = ""
    @State private var descrizione = ""
    @State private var importo = ""
    @State private var pagatoDa = ""
    @State private var fonte = ""
    @State private var verificato = false
    @State private var note = ""
    // affitti
    @State private var camera = ""
    @State private var notti = ""
    @State private var canale = "Diretto"
    @State private var commissione = ""
    @State private var stato = "Pagato"
    // soci
    @State private var socio = "Giorgio"
    @State private var conta = true
    // pendenti
    @State private var origine = ""

    @State private var salvando = false
    @State private var errore: String? = nil
    @State private var chiediCancella = false

    private var esistente: Bool {
        switch target {
        case .movimento(let r): return r != nil
        case .affitto(let r): return r != nil
        case .spesa(let r): return r != nil
        case .apporto(let r): return r != nil
        case .pendente(let r): return r != nil
        }
    }
    private var titolo: String {
        let cosa: String
        switch target {
        case .movimento: cosa = "movimento"
        case .affitto: cosa = "soggiorno"
        case .spesa: cosa = "spesa di alloggio"
        case .apporto: cosa = "apporto socio"
        case .pendente: cosa = "credito da incassare"
        }
        return (esistente ? "Modifica " : "Nuovo ") + cosa
    }
    private var tabella: String {
        switch target {
        case .movimento: return "storico_movimenti"
        case .affitto: return "storico_affitti"
        case .spesa: return "storico_spese_alloggio"
        case .apporto: return "storico_apporti_soci"
        case .pendente: return "storico_pendenti"
        }
    }
    private var idRiga: String? {
        switch target {
        case .movimento(let r): return r?.id
        case .affitto(let r): return r?.id
        case .spesa(let r): return r?.id
        case .apporto(let r): return r?.id
        case .pendente(let r): return r?.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            intestazione
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    switch target {
                    case .movimento: campiMovimento
                    case .affitto: campiAffitto
                    case .spesa: campiSpesa
                    case .apporto: campiApporto
                    case .pendente: campiPendente
                    }
                    campo("Note", $note, alta: true)
                }
                .padding(20)
            }
            piede
        }
        .frame(width: 640, height: 620)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
        .onAppear(perform: carica)
        .confirmationDialog("Cancellare questa riga?", isPresented: $chiediCancella, titleVisibility: .visible) {
            Button("Cancella", role: .destructive) { Task { await cancella() } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Sparisce dall'archivio e dai totali del periodo. Non si recupera.")
        }
    }

    private var intestazione: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(titolo.uppercased()).font(.system(size: 13, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            Text("La stagione la decide la data. La modifica resta dentro lo storico e non tocca la gestione corrente.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 12, trailing: 16))
    }

    private var piede: some View {
        HStack(spacing: 10) {
            if esistente {
                Button(role: .destructive) { chiediCancella = true } label: {
                    Label("Cancella", systemImage: "trash").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(PSE.neg)
            }
            if let errore {
                Text(errore).font(.system(size: 11)).foregroundStyle(PSE.neg).lineLimit(2)
            }
            Spacer()
            Button("Annulla") { onClose() }.buttonStyle(.plain).foregroundStyle(PSE.dim)
            Button { Task { await salva() } } label: {
                Text(salvando ? "Salvo…" : "Salva").font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(PSE.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain).disabled(salvando)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
    }

    // ── Campi per tabella ──────────────────────────────────────────────────
    private var campiMovimento: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) { campo("Data (gg/mm/aaaa)", $data); scelta("Casa", $struttura, ["Via Po", "Via Romagna", "Mixto"]) }
            HStack(spacing: 12) { scelta("Tipo", $tipo, ["uscita", "entrata"]); campo("Importo €", $importo) }
            HStack(spacing: 12) { campo("Categoria", $categoria); campo("Pagato da / origine", $pagatoDa) }
            campo("Descrizione", $descrizione)
            HStack(spacing: 12) {
                campo("Fonte", $fonte)
                Toggle("Verificato con estratto o fattura", isOn: $verificato)
                    .font(.system(size: 11.5)).foregroundStyle(PSE.text).toggleStyle(.checkbox)
            }
            Text("La categoria decide in che gruppo finisce (Utenze, Opera e arredo, Mutuo…). Usa gli stessi nomi che già ci sono: Luce, Gas, Internet, Tecnici casa, Materiali, Aredo casa, Mutuo — rata, Tase…")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var campiAffitto: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) { campo("Data (gg/mm/aaaa)", $data); scelta("Casa", $struttura, ["Via Po", "Via Romagna"]) }
            HStack(spacing: 12) { campo("Camera", $camera); campo("Notti", $notti) }
            HStack(spacing: 12) { scelta("Canale", $canale, ["Diretto", "Booking", "Airbnb", "Mixto"]); scelta("Stato", $stato, ["Pagato", "Da incassare"]) }
            HStack(spacing: 12) { campo("Lordo €", $importo); campo("Commissione €", $commissione) }
            campo("Fonte", $fonte)
            Text("Il netto si calcola da solo: lordo meno commissione.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }

    private var campiSpesa: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) { campo("Data (gg/mm/aaaa)", $data); scelta("Casa", $struttura, ["Via Po", "Via Romagna"]) }
            HStack(spacing: 12) { scelta("Categoria", $categoria, ["Pulizie", "Lavanderia", "Colazione", "Altri"]); campo("Importo €", $importo) }
            campo("Descrizione", $descrizione)
            campo("Fonte", $fonte)
        }
    }

    private var campiApporto: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) { campo("Data (gg/mm/aaaa)", $data); scelta("Socio", $socio, ["Giorgio", "Giacomo"]) }
            HStack(spacing: 12) { scelta("Casa", $struttura, ["Via Po", "Via Romagna", "Mixto"]); campo("Importo €", $importo) }
            campo("Descrizione", $descrizione)
            HStack(spacing: 12) {
                campo("Categoria", $categoria)
                Toggle("Conta nel conguaglio", isOn: $conta)
                    .font(.system(size: 11.5)).foregroundStyle(PSE.text).toggleStyle(.checkbox)
            }
            campo("Fonte", $fonte)
            Text("Importo negativo per le restituzioni (es. −28000). Togli la spunta per le righe registrate ma che non devono pesare sul conguaglio.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var campiPendente: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) { campo("Data avviso (gg/mm/aaaa)", $data); campo("Importo €", $importo) }
            campo("Concetto / debitore", $descrizione)
            HStack(spacing: 12) { campo("Origine", $origine); campo("Stato", $stato) }
        }
    }

    // ── Pezzi di modulo ────────────────────────────────────────────────────
    private func campo(_ etichetta: String, _ v: Binding<String>, alta: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(etichetta.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
            if alta {
                TextEditor(text: v).font(.system(size: 12)).frame(height: 64)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(PSE.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PSE.line, lineWidth: 1))
            } else {
                TextField("", text: v).textFieldStyle(.plain).font(.system(size: 12.5))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(PSE.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PSE.line, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scelta(_ etichetta: String, _ v: Binding<String>, _ opzioni: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(etichetta.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
            Picker("", selection: v) { ForEach(opzioni, id: \.self) { Text($0).tag($0) } }
                .labelsHidden().pickerStyle(.menu).font(.system(size: 12.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Carica / salva ─────────────────────────────────────────────────────
    private func giorno(_ iso: String?) -> String {
        guard let iso, let d = sTabYmd.date(from: String(iso.prefix(10))) else { return "" }
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; return f.string(from: d)
    }
    private func iso(_ giorno: String) -> String? {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
        guard let d = f.date(from: giorno.trimmingCharacters(in: .whitespaces)) else { return nil }
        return sTabYmd.string(from: d)
    }

    private func carica() {
        switch target {
        case .movimento(let r):
            guard let r else { data = giorno(nil); return }
            data = giorno(r.data); struttura = r.struttura ?? "Via Po"; tipo = r.tipo
            categoria = r.categoria ?? ""; descrizione = r.descrizione ?? ""
            importo = testoDa(r.importo_cents); pagatoDa = r.pagato_da ?? ""
            fonte = r.fonte ?? ""; verificato = r.verificato; note = r.note ?? ""
        case .affitto(let r):
            guard let r else { return }
            data = giorno(r.data); struttura = r.struttura ?? "Via Po"; camera = r.camera ?? ""
            notti = r.notti.map(String.init) ?? ""; canale = r.canale ?? "Diretto"
            importo = testoDa(r.lordo_cents); commissione = testoDa(r.commissione_cents)
            stato = r.stato ?? "Pagato"; fonte = r.fonte ?? ""; note = r.note ?? ""
        case .spesa(let r):
            guard let r else { categoria = "Pulizie"; return }
            data = giorno(r.data); struttura = r.struttura ?? "Via Po"; categoria = r.categoria ?? "Pulizie"
            descrizione = r.descrizione ?? ""; importo = testoDa(r.importo_cents)
            fonte = r.fonte ?? ""; note = r.note ?? ""
        case .apporto(let r):
            guard let r else { return }
            data = giorno(r.data); socio = r.socio; struttura = r.struttura ?? "Via Po"
            descrizione = r.descrizione ?? ""; categoria = r.categoria ?? ""
            importo = testoDa(r.importo_cents); conta = r.conta
            fonte = r.fonte ?? ""; note = r.note ?? ""
        case .pendente(let r):
            guard let r else { return }
            data = giorno(r.data_avviso); descrizione = r.concetto ?? ""
            importo = testoDa(r.importo_cents); origine = r.origine ?? ""
            stato = r.stato ?? "Por verificar"; note = r.note ?? ""
        }
    }

    /// A quale stagione appartiene una data. Sempre calcolato, mai preso dalla
    /// scheda che si aveva aperto: dal riassunto si scriverebbe «tutto».
    private func periodoDi(_ iso: String?) -> String {
        guard let iso, let d = sTabYmd.date(from: iso) else { return periodo == "tutto" ? "2025-2026" : periodo }
        return d < sTabYmd.date(from: "2025-10-01")! ? "2024-2025" : "2025-2026"
    }

    private func corpo() -> [String: Any?]? {
        let cents = centesimiDa(importo)
        switch target {
        case .movimento:
            guard let d = iso(data) else { return nil }
            return ["periodo": periodoDi(d), "data": d, "struttura": struttura, "tipo": tipo,
                    "categoria": categoria.isEmpty ? nil : categoria,
                    "descrizione": descrizione, "importo_cents": abs(cents),
                    "pagato_da": pagatoDa.isEmpty ? nil : pagatoDa,
                    "fonte": fonte.isEmpty ? "Inserito a mano" : fonte,
                    "verificato": verificato, "note": note.isEmpty ? nil : note]
        case .affitto:
            guard let d = iso(data) else { return nil }
            let comm = centesimiDa(commissione)
            return ["periodo": periodoDi(d), "data": d, "struttura": struttura,
                    "camera": camera.isEmpty ? nil : camera, "notti": Int(notti),
                    "canale": canale, "lordo_cents": abs(cents), "commissione_cents": abs(comm),
                    "netto_cents": abs(cents) - abs(comm), "stato": stato,
                    "fonte": fonte.isEmpty ? "Inserito a mano" : fonte,
                    "note": note.isEmpty ? nil : note]
        case .spesa:
            guard let d = iso(data) else { return nil }
            return ["periodo": periodoDi(d), "data": d, "struttura": struttura, "categoria": categoria,
                    "descrizione": descrizione, "importo_cents": abs(cents),
                    "fonte": fonte.isEmpty ? "Inserito a mano" : fonte,
                    "note": note.isEmpty ? nil : note]
        case .apporto:
            guard let d = iso(data) else { return nil }
            return ["periodo": periodoDi(d), "data": d, "socio": socio, "struttura": struttura,
                    "descrizione": descrizione, "categoria": categoria.isEmpty ? nil : categoria,
                    "importo_cents": cents, "conta": conta,
                    "fonte": fonte.isEmpty ? "Inserito a mano" : fonte,
                    "note": note.isEmpty ? nil : note]
        case .pendente:
            return ["periodo": periodoDi(iso(data)), "data_avviso": iso(data), "concetto": descrizione,
                    "importo_cents": abs(cents), "origine": origine.isEmpty ? nil : origine,
                    "stato": stato.isEmpty ? "Por verificar" : stato,
                    "note": note.isEmpty ? nil : note]
        }
    }

    private func salva() async {
        guard let body = corpo() else { errore = "Data non valida: scrivila come 05/03/2025."; return }
        salvando = true; errore = nil
        do {
            if let id = idRiga { try await HubAPI.aggiornaStorico(tabella, id: id, body) }
            else { try await HubAPI.creaStorico(tabella, body) }
            NotificationCenter.default.post(name: .datiCambiati, object: nil)
            onClose()
        } catch {
            errore = "Non salvato: \(error.localizedDescription)"
        }
        salvando = false
    }

    private func cancella() async {
        guard let id = idRiga else { return }
        salvando = true
        do {
            try await HubAPI.cancellaStorico(tabella, id: id)
            NotificationCenter.default.post(name: .datiCambiati, object: nil)
            onClose()
        }
        catch { errore = "Non cancellato: \(error.localizedDescription)" }
        salvando = false
    }
}
