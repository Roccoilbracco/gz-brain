import SwiftUI

// ============================================================================
// Camere PSE — Servizi: Pulizie · Colazioni · Utenze (come i fogli dell'Excel)
// Pulizia 20 €/check-out · Colazioni 3,50 €/pers·notte (Booking) · Utenze Educamp.
// Sorgente: public.pulizie + public.colazioni + public.educamp_righe.
// ============================================================================

struct Pulizia: Identifiable, Decodable, Equatable {
    let id: String
    var data: String?
    var casa: String?
    var descrizione: String?
    var stato: String?
    var costo_cents: Int
    var sort_order: Int?
}
/// Bolletta pagata da noi (luce, gas, acqua, internet, immondizia, IMU, varie).
/// Sta in una tabella a parte e non nei movimenti perché si paga da un conto
/// che non è né Cassa né Massimo né Beeper: metterla lì sfalserebbe i saldi.
struct Bolletta: Identifiable, Decodable, Equatable {
    let id: String
    var casa: String
    var tipo: String
    var fornitore: String?
    var scadenza: String?
    var periodo: String?
    var importo_cents: Int
    var pagata: Bool
    var note: String?
}

struct Colazione: Identifiable, Decodable, Equatable {
    let id: String
    var ospite: String?
    var camera: String?
    var arrivo: String?
    var partenza: String?
    var notti: Int?
    var persone: Int?
    var costo_totale_cents: Int
    var notti_servite: Int?
    var costo_servito_cents: Int
    var stato: String?
    var casa: String?
    var sort_order: Int?
}

extension HubAPI {
    static func listPulizie() async throws -> [Pulizia] {
        try await sb.fetch("pulizie?select=*&order=sort_order.asc")
    }
    static func listColazioni() async throws -> [Colazione] {
        try await sb.fetch("colazioni?select=*&order=sort_order.asc")
    }
    static func listBollette() async throws -> [Bolletta] {
        try await sb.fetch("bollette?select=*&order=scadenza.desc")
    }
    /// Le bollette inserite a mano non hanno `ext_key`: quella è la chiave
    /// d'import del foglio del maestro e deve restare libera, altrimenti un
    /// giorno un re-import si scontrerebbe con una riga scritta qui.
    @discardableResult
    static func createBolletta(_ f: [String: Any?]) async throws -> Bolletta {
        try await sb.insertReturning("bollette", body: f)
    }
    static func updateBolletta(id: String, fields: [String: Any?]) async throws {
        var b = fields; b["updated_at"] = isoNowString()
        try await sb.mutate("bollette?id=eq.\(id)", method: "PATCH", body: b)
    }
    static func deleteBolletta(id: String) async throws {
        await deleteAllegatiDi(.bolletta, id: id)
        try await sb.mutate("bollette?id=eq.\(id)", method: "DELETE")
    }
}

/// Le voci di spesa delle utenze, nell'ordine in cui vanno mostrate. Immondizia
/// e IMU non sono utenze in senso stretto ma stanno qui perché è dove l'utente
/// va a cercarle.
let TIPI_BOLLETTA: [(String, String, String)] = [
    ("luce",       "Luce",       "bolt.fill"),
    ("gas",        "Gas",        "flame.fill"),
    ("acqua",      "Acqua",      "drop.fill"),
    ("internet",   "Internet",   "wifi"),
    ("immondizia", "Immondizia", "trash.fill"),
    ("imu",        "IMU",        "building.columns.fill"),
    ("varie",      "Varie",      "ellipsis.circle.fill"),
]

private let svYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let svDay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "dd/MM"; return f }()
private func svDayStr(_ s: String?) -> String {
    guard let s, let d = svYmd.date(from: String(s.prefix(10))) else { return "—" }
    return svDay.string(from: d)
}
private func casaLbl(_ s: String?) -> String { s == "via-po" ? "Via Po" : s == "via-romagna" ? "Via Romagna" : s == "comune" ? "Comune" : "—" }
// Le bollette coprono più anni: qui l'anno serve, a differenza delle pulizie.
private let svDayY: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "dd/MM/yy"; return f }()
private func svDayYStr(_ s: String?) -> String {
    guard let s, let d = svYmd.date(from: String(s.prefix(10))) else { return "—" }
    return svDayY.string(from: d)
}

enum ServizioTab: String, CaseIterable, Identifiable {
    case pulizie = "Pulizie", colazioni = "Colazioni", utenze = "Utenze"
    // Le due nuove non hanno una tabella propria: si leggono dalle uscite
    // registrate in Tesoreria. Manutenzione è quello che si ripara, spese varie
    // è tutto il resto che non è pulizia, colazione, utenza, OTA o debito.
    case manutenzione = "Manutenzione", speseVarie = "Spese varie"
    var id: String { rawValue }
}

/// Le due strutture, nell'ordine in cui vanno mostrate come sotto-finestre.
let CASE_PSE: [(String, String)] = [("via-po", "Via Po"), ("via-romagna", "Via Romagna")]

@MainActor final class ServiziModel: ObservableObject {
    @Published var pulizie: [Pulizia] = []
    @Published var colazioni: [Colazione] = []
    @Published var utenze: [EducampRiga] = []
    @Published var bollette: [Bolletta] = []
    /// Uscite di cassa: da qui escono manutenzione e spese varie, che non hanno
    /// una tabella dedicata ma vivono nei movimenti.
    @Published var movimenti: [TesMovimento] = []
    /// Quante fatture in PDF ha ciascuna bolletta: una query sola per tutta la
    /// tabella, così la graffetta non costa una chiamata per riga.
    @Published var allegatiPerBolletta: [String: Int] = [:]
    @Published var loading = true
    func load() async {
        loading = true
        pulizie = (try? await HubAPI.listPulizie()) ?? []
        colazioni = (try? await HubAPI.listColazioni()) ?? []
        utenze = (try? await HubAPI.listEducampRighe()) ?? []
        bollette = (try? await HubAPI.listBollette()) ?? []
        movimenti = (try? await HubAPI.listMovimenti()) ?? []
        allegatiPerBolletta = (try? await HubAPI.contaAllegati(.bolletta)) ?? [:]
        loading = false
    }
    func ricontaAllegati() async {
        allegatiPerBolletta = (try? await HubAPI.contaAllegati(.bolletta)) ?? [:]
    }
}

// Sheet che apre le transazioni di un servizio (pulizie/colazioni) dal Riepilogo:
// riusa la stessa vista della pagina dedicata, così i dati non possono discordare.
struct ServizioDettaglioSheet: View {
    let tab: ServizioTab
    let onClose: () -> Void
    @State private var t: ServizioTab

    init(tab: ServizioTab, onClose: @escaping () -> Void) {
        self.tab = tab; self.onClose = onClose; _t = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t.rawValue.uppercased()).font(.system(size: 14, weight: .heavy)).tracking(1.5).foregroundStyle(PSE.ink)
                Spacer()
                // Passare tra pulizie e colazioni senza chiudere la finestra
                PSESegmented(items: [ServizioTab.pulizie, .colazioni, .utenze].map { ($0, $0.rawValue) }, selection: $t)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain).padding(.leading, 6)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 12, trailing: 16))
            ServiziView(tab: $t).padding(.horizontal, 20)
        }
        .frame(width: 900, height: 640)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
    }
}

struct ServiziView: View {
    @Binding var tab: ServizioTab
    @StateObject private var model = ServiziModel()
    @State private var bollettaSheet: Bolletta?
    @State private var nuovaBolletta = false

    var body: some View {
        Group {
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .pulizie: pulizieView
                        case .colazioni: colazioniView
                        case .utenze: utenzeView
                        case .manutenzione: usciteView(.manutenzione)
                        case .speseVarie: usciteView(.speseVarie)
                        }
                    }.padding(.bottom, 20)
                }
            }
        }
        .task { await model.load() }
        // Stessa scheda per la bolletta esistente e per quella nuova: cambia
        // solo se parte da una riga o da zero.
        // Alla chiusura si ricontano gli allegati: chi apre la scheda solo per
        // attaccare il PDF non passa dal salvataggio, e la graffetta in tabella
        // resterebbe indietro.
        .sheet(item: $bollettaSheet, onDismiss: { Task { await model.ricontaAllegati() } }) { b in
            BollettaForm(existing: b) { await model.load() }
        }
        .sheet(isPresented: $nuovaBolletta) {
            BollettaForm(existing: nil) { await model.load() }
        }
    }

    // ── MANUTENZIONE E SPESE VARIE ───────────────────────────────────────────
    // Non hanno una tabella propria: sono le uscite già registrate in Tesoreria,
    // lette per categoria. «Manutenzione» è quello che si ripara; «spese varie»
    // è il resto che non è pulizia, colazione, utenza, commissione OTA o debito
    // — cioè le spese che altrimenti non si guardavano mai perché sparse.
    private func categoriaUscita(_ m: TesMovimento) -> ServizioTab? {
        guard m.tipo == "uscita" else { return nil }
        let c = (m.categoria ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if c.contains("manutenzion") || c.contains("riparaz") { return .manutenzione }
        let escluse = ["pulizia", "pulizie", "colazion", "utenz", "bolletta", "luce", "gas", "acqua",
                       "commission", "airbnb", "booking", "debito", "debiti", "prestito", "mutuo",
                       "rata", "finanziam", "deposito", "banca"]
        if escluse.contains(where: { c.contains($0) }) { return nil }
        return .speseVarie
    }
    private func usciteView(_ t: ServizioTab) -> some View {
        let righe = model.movimenti.filter { categoriaUscita($0) == t }.sorted { $0.data > $1.data }
        let tot = righe.reduce(0) { $0 + $1.importo_cents }
        return VStack(alignment: .leading, spacing: 14) {
            Text(t == .manutenzione
                 ? "MANUTENZIONE E RIPARAZIONI — dalle uscite registrate in Tesoreria"
                 : "SPESE VARIE — le uscite che non sono pulizie, colazioni, utenze, commissioni o debiti")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
            HStack(spacing: 12) {
                card("TOTALE", eurc(tot), PSE.neg)
                ForEach(CASE_PSE, id: \.0) { slug, nome in
                    let t2 = righe.filter { $0.struttura == slug }.reduce(0) { $0 + $1.importo_cents }
                    card(nome.uppercased(), eurc(t2), PSE.ink)
                }
                card("N. USCITE", "\(righe.count)", PSE.accent)
            }
            if righe.isEmpty {
                EmptyStateCard(icon: t == .manutenzione ? "wrench.and.screwdriver" : "cart",
                               text: t == .manutenzione
                                 ? "Nessuna manutenzione registrata. Le uscite con categoria «manutenzione» finiscono qui."
                                 : "Nessuna spesa varia registrata.")
            } else {
                ForEach(CASE_PSE, id: \.0) { slug, nome in
                    let r = righe.filter { $0.struttura == slug }
                    if !r.isEmpty { usciteCasaTable(nome, r) }
                }
                let senza = righe.filter { ($0.struttura ?? "").isEmpty }
                if !senza.isEmpty { usciteCasaTable("Senza casa", senza) }
            }
            Text(t == .manutenzione
                 ? "Per far comparire una spesa qui: registrala in Tesoreria come uscita con categoria «manutenzione»."
                 : "Per far comparire una spesa qui basta che sia un'uscita con una categoria diversa da pulizia, colazione, utenza, commissione, banca o debito.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }
    private func usciteCasaTable(_ nome: String, _ righe: [TesMovimento]) -> some View {
        let tot = righe.reduce(0) { $0 + $1.importo_cents }
        return VStack(alignment: .leading, spacing: 0) {
            intestazioneCasa(nome, "\(righe.count) uscite · \(eurc(tot))")
            HStack(spacing: 10) {
                Text("DATA").frame(width: 66, alignment: .leading)
                Text("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
                Text("CATEGORIA").frame(width: 120, alignment: .leading)
                Text("IMPORTO").frame(width: 92, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .heavy)).tracking(0.7).foregroundStyle(PSE.faint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(Array(righe.enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 10) {
                    Text(svDayYStr(m.data)).font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(PSE.dim).frame(width: 66, alignment: .leading)
                    Text(m.descrizione ?? "—").font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PSE.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text((m.categoria ?? "—").capitalized.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 11)).foregroundStyle(PSE.faint)
                        .frame(width: 120, alignment: .leading).lineLimit(1)
                    Text("−" + eurc(m.importo_cents)).font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(PSE.neg).monospacedDigit().frame(width: 92, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 14) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── PULIZIE ──
    // Una finestra per casa: i conti delle due strutture non si mescolano mai,
    // e in cima resta il totale complessivo per non perdere il quadro d'insieme.
    private var pulizieView: some View {
        let totF = model.pulizie.filter { $0.stato == "fatta" }.reduce(0) { $0 + $1.costo_cents }
        let totP = model.pulizie.filter { $0.stato != "fatta" }.reduce(0) { $0 + $1.costo_cents }
        return VStack(alignment: .leading, spacing: 14) {
            Text("PULIZIA E LAVANDERIA — 20 € per ogni check-out (per camera)")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
            HStack(spacing: 12) {
                card("FATTE — TOTALE (uscita in cassa)", eurc(totF), PSE.pos)
                card("PREVISTE — TOTALE (future)", eurc(totP), PSE.warn)
                card("TOTALE", eurc(totF + totP), PSE.ink)
                card("N. CHECK-OUT", "\(model.pulizie.count)", PSE.accent)
            }
            ForEach(CASE_PSE, id: \.0) { slug, nome in
                pulizieCasa(slug, nome)
            }
            Text("Solo le pulizie «Fatte» sono conteggiate come uscita in cassa; le «Previste» sono costi futuri.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }
    private func pulizieCasa(_ slug: String, _ nome: String) -> some View {
        let righe = model.pulizie.filter { $0.casa == slug }
            .sorted { ($0.data ?? "") > ($1.data ?? "") }
        let fatte = righe.filter { $0.stato == "fatta" }.reduce(0) { $0 + $1.costo_cents }
        let previste = righe.filter { $0.stato != "fatta" }.reduce(0) { $0 + $1.costo_cents }
        return VStack(alignment: .leading, spacing: 0) {
            intestazioneCasa(nome, "\(righe.count) check-out")
            HStack(spacing: 12) {
                card("FATTE", eurc(fatte), PSE.pos)
                card("PREVISTE", eurc(previste), PSE.warn)
                card("TOTALE", eurc(fatte + previste), PSE.ink)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            if righe.isEmpty {
                Text("Nessuna pulizia registrata.").font(.system(size: 11)).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                tableCard {
                    pulHeader
                    ForEach(Array(righe.enumerated()), id: \.element.id) { i, p in
                        HStack(spacing: 10) {
                            num(svDayStr(p.data), PSE.dim).frame(width: 54, alignment: .leading)
                            Text(p.descrizione ?? "—").font(.system(size: 12)).foregroundStyle(PSE.ink)
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            statoPill(p.stato)
                            num(eurc(p.costo_cents), PSE.text).frame(width: 74, alignment: .trailing)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private var pulHeader: some View {
        HStack(spacing: 10) {
            th("DATA").frame(width: 54, alignment: .leading)
            th("CAMERA / OSPITE").frame(maxWidth: .infinity, alignment: .leading)
            th("STATO").frame(width: 78, alignment: .leading)
            th("COSTO").frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    // intestazione della sotto-finestra di una casa
    private func intestazioneCasa(_ nome: String, _ dettaglio: String) -> some View {
        HStack {
            Text(nome.uppercased()).font(.system(size: 11.5, weight: .heavy)).tracking(1)
                .foregroundStyle(PSE.ink).lineLimit(1)
            Spacer()
            Text(dettaglio).font(.system(size: 10.5)).foregroundStyle(PSE.faint).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(PSE.accent.opacity(0.16))
    }

    // ── COLAZIONI ──
    private var colazioniView: some View {
        let serv = model.colazioni.reduce(0) { $0 + $1.costo_servito_cents }
        let tot = model.colazioni.reduce(0) { $0 + $1.costo_totale_cents }
        return VStack(alignment: .leading, spacing: 14) {
            Text("COLAZIONI — 3,50 € per persona / giorno (solo prenotazioni Booking)")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
            HStack(spacing: 12) {
                card("GIÀ SERVITE — TOTALE (uscita)", eurc(serv), PSE.pos)
                card("PREVISTE — TOTALE (future)", eurc(tot - serv), PSE.warn)
                card("TOTALE", eurc(tot), PSE.ink)
                card("N. PRENOTAZIONI", "\(model.colazioni.count)", PSE.accent)
            }
            ForEach(CASE_PSE, id: \.0) { slug, nome in
                colazioniCasa(slug, nome)
            }
            Text("Solo le colazioni «già servite» sono conteggiate come spesa. Le prenotazioni dirette e Airbnb non hanno colazione, quindi Via Romagna — che non ha canali OTA — resta a zero.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }
    private func colazioniCasa(_ slug: String, _ nome: String) -> some View {
        let righe = model.colazioni.filter { $0.casa == slug }
            .sorted { ($0.arrivo ?? "") > ($1.arrivo ?? "") }
        let serv = righe.reduce(0) { $0 + $1.costo_servito_cents }
        let tot = righe.reduce(0) { $0 + $1.costo_totale_cents }
        return VStack(alignment: .leading, spacing: 0) {
            intestazioneCasa(nome, "\(righe.count) prenotazioni")
            HStack(spacing: 12) {
                card("GIÀ SERVITE", eurc(serv), PSE.pos)
                card("PREVISTE", eurc(tot - serv), PSE.warn)
                card("TOTALE", eurc(tot), PSE.ink)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            if righe.isEmpty {
                Text("Nessuna colazione: qui non ci sono prenotazioni Booking.")
                    .font(.system(size: 11)).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                tableCard {
                    colHeader
                    ForEach(Array(righe.enumerated()), id: \.element.id) { i, cz in
                        HStack(spacing: 10) {
                            Text(cz.ospite ?? "—").font(.system(size: 12, weight: .medium)).foregroundStyle(PSE.ink)
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            td(cz.camera ?? "—").frame(width: 120, alignment: .leading)
                            num("\(svDayStr(cz.arrivo))–\(svDayStr(cz.partenza))", PSE.dim).frame(width: 96, alignment: .leading)
                            num("\(cz.notti ?? 0)", PSE.dim).frame(width: 44, alignment: .trailing)
                            num("\(cz.persone ?? 0)", PSE.dim).frame(width: 54, alignment: .trailing)
                            num(eurc(cz.costo_totale_cents), PSE.text).frame(width: 74, alignment: .trailing)
                            num(eurc(cz.costo_servito_cents), PSE.pos).frame(width: 78, alignment: .trailing)
                            statoPill(cz.stato)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private var colHeader: some View {
        HStack(spacing: 10) {
            th("OSPITE").frame(maxWidth: .infinity, alignment: .leading)
            th("CAMERA").frame(width: 120, alignment: .leading)
            th("PERIODO").frame(width: 96, alignment: .leading)
            th("NOTTI").frame(width: 44, alignment: .trailing)
            th("PERS.").frame(width: 54, alignment: .trailing)
            th("TOTALE").frame(width: 74, alignment: .trailing)
            th("SERVITO").frame(width: 78, alignment: .trailing)
            th("STATO").frame(width: 78, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }

    // ── UTENZE — quello che PAGHIAMO di bollette ──
    // Le utenze Educamp sono un'altra cosa (soldi da riprendere dagli inquilini
    // di Via Romagna) e stanno in una scheda a parte: qui non si sommano e non
    // si nettano, perché confonderebbero due conti diversi.
    /// Il conteggio parte da luglio 2026: le bollette precedenti restano
    /// archiviate ma vanno sistemate a parte.
    private static let INIZIO_CONTEGGIO = "2026-07-01"
    private var bolletteCorrenti: [Bolletta] {
        model.bollette.filter { ($0.scadenza ?? "") >= Self.INIZIO_CONTEGGIO }
    }
    private var bolletteStorico: [Bolletta] {
        model.bollette.filter { ($0.scadenza ?? "") < Self.INIZIO_CONTEGGIO }
    }
    private var bolletteTot: Int { bolletteCorrenti.reduce(0) { $0 + $1.importo_cents } }
    private func bolletteTipo(_ t: String) -> Int {
        bolletteCorrenti.filter { $0.tipo == t }.reduce(0) { $0 + $1.importo_cents }
    }
    private func bolletteCasa(_ c: String) -> Int {
        bolletteCorrenti.filter { $0.casa == c }.reduce(0) { $0 + $1.importo_cents }
    }
    /// Una tabella per casa invece di una sola mescolata: le due strutture hanno
    /// fornitori e contratti diversi, e leggerle insieme costringe a ricontare a
    /// occhio quale bolletta appartiene a quale casa. L'ordine è sempre Via Po,
    /// Via Romagna, Comune; le case senza bollette non fanno una tabella vuota.
    private func perCasa(_ righe: [Bolletta]) -> [(casa: String, righe: [Bolletta])] {
        (CASE_PSE.map { $0.0 } + ["comune"]).compactMap { c in
            let r = righe.filter { $0.casa == c }
            return r.isEmpty ? nil : (c, r)
        }
    }

    private var utenzeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UTENZE CHE PAGHIAMO NOI — DA LUGLIO 2026")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
                Spacer()
                Button { nuovaBolletta = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Nuova bolletta").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(PSE.warn))
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                card("TOTALE PAGATO", eurc(bolletteTot), PSE.neg)
                card("VIA PO", eurc(bolletteCasa("via-po")), PSE.dim)
                card("VIA ROMAGNA", eurc(bolletteCasa("via-romagna")), PSE.dim)
                card("N. BOLLETTE", "\(bolletteCorrenti.count)", PSE.accent)
            }
            HStack(spacing: 12) {
                ForEach(TIPI_BOLLETTA, id: \.0) { t in
                    tipoCard(t.0, t.1, t.2)
                }
            }
            if bolletteCorrenti.isEmpty {
                EmptyStateCard(icon: "doc.text", text: "Nessuna bolletta da luglio 2026 in poi.")
            } else {
                ForEach(perCasa(bolletteCorrenti), id: \.casa) { g in
                    bolletteTable(g.righe, titolo: "BOLLETTE DA LUGLIO 2026 — \(casaLbl(g.casa).uppercased())")
                }
            }
            Text("Si pagano dal conto corrente, non da Cassa/Massimo/Beeper: per questo non compaiono tra i movimenti e non toccano i saldi. Ogni bolletta che arriva si registra con «Nuova bolletta» e ci si attacca il PDF; le vecchie si aprono cliccando sulla riga. Acqua, immondizia e IMU non erano nel foglio del maestro: le voci sono pronte, vanno solo riempite. Le utenze addebitate agli inquilini Educamp sono un'altra cosa e stanno nella scheda Educamp.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)

            if !bolletteStorico.isEmpty {
                Text("PRIMA DI LUGLIO 2026 — ARCHIVIO, FUORI DAL CONTEGGIO")
                    .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint).padding(.top, 10)
                ForEach(perCasa(bolletteStorico), id: \.casa) { g in
                    bolletteTable(g.righe, titolo: "ARCHIVIO — \(casaLbl(g.casa).uppercased())", spenta: true)
                }
            }
        }
    }

    // Card compatta per tipo di bolletta: resta visibile anche a zero, così si
    // vede subito quali voci non sono ancora state registrate.
    private func tipoCard(_ tipo: String, _ label: String, _ icon: String) -> some View {
        let v = bolletteTipo(tipo)
        let vuota = v == 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(vuota ? PSE.faint : PSE.neg)
                Text(label.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(PSE.faint).lineLimit(1)
            }
            Text(vuota ? "—" : eurc(v)).font(.system(size: 14, weight: .bold))
                .foregroundStyle(vuota ? PSE.faint : PSE.ink).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
    }

    /// `spenta` = tabella d'archivio: stessi dati, colori attenuati e nessun
    /// totale, così non si confonde con quello che conta.
    private func bolletteTable(_ righe: [Bolletta], titolo: String?, spenta: Bool = false) -> some View {
        let tot = righe.reduce(0) { $0 + $1.importo_cents }
        return tableCard {
            if let titolo {
                Text(titolo).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            HStack(spacing: 10) {
                th("SCADENZA").frame(width: 78, alignment: .leading)
                th("CASA").frame(width: 96, alignment: .leading)
                th("TIPO").frame(width: 86, alignment: .leading)
                th("FORNITORE").frame(width: 110, alignment: .leading)
                th("PERIODO / NOTA").frame(maxWidth: .infinity, alignment: .leading)
                th("IMPORTO").frame(width: 84, alignment: .trailing)
                Image(systemName: "paperclip").font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(PSE.faint).frame(width: 24, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            // La riga apre la scheda della bolletta: è lì che si attacca il PDF
            // e lo si riapre quando serve controllare un importo.
            ForEach(Array(righe.enumerated()), id: \.element.id) { i, b in
                Button { bollettaSheet = b } label: {
                    HStack(spacing: 10) {
                        num(svDayYStr(b.scadenza), PSE.dim).frame(width: 78, alignment: .leading)
                        td(casaLbl(b.casa)).frame(width: 96, alignment: .leading)
                        Text(TIPI_BOLLETTA.first { $0.0 == b.tipo }?.1 ?? b.tipo.capitalized)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(spenta ? PSE.dim : PSE.ink)
                            .frame(width: 86, alignment: .leading).lineLimit(1)
                        td(b.fornitore ?? "—").frame(width: 110, alignment: .leading)
                        td(b.periodo ?? b.note ?? "—").frame(maxWidth: .infinity, alignment: .leading)
                        num(eurc(b.importo_cents), spenta ? PSE.dim : PSE.neg).frame(width: 84, alignment: .trailing)
                        AllegatiPin(n: model.allegatiPerBolletta[b.id] ?? 0).frame(width: 24, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
            }
            HStack(spacing: 10) {
                Text(spenta ? "TOTALE ARCHIVIO (non conteggiato)" : "TOTALE BOLLETTE")
                    .font(.system(size: 10, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(spenta ? PSE.faint : PSE.ink)
                Spacer()
                Text(eurc(tot)).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(spenta ? PSE.dim : PSE.neg).monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Color.white.opacity(spenta ? 0.02 : 0.04))
        }
    }

    private func meseBreve(_ key: String) -> String {
        guard let d = svYmd.date(from: key + "-01") else { return key }
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMMM yyyy"
        return f.string(from: d).capitalized
    }

    // ── helper ──
    private func tableCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content().padding(.bottom, 6) }
            .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func card(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(v).font(.system(size: 17, weight: .bold)).foregroundStyle(c).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func statoPill(_ s: String?) -> some View {
        let done = (s == "fatta" || s == "servite")
        return Text((s ?? "—").capitalized)
            .font(.system(size: 9.5, weight: .heavy)).tracking(0.5)
            .foregroundStyle(done ? PSE.pos : PSE.warn)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill((done ? PSE.pos : PSE.warn).opacity(0.14)))
            .overlay(Capsule().strokeBorder((done ? PSE.pos : PSE.warn).opacity(0.45), lineWidth: 1))
            .frame(width: 78, alignment: .leading)
    }
    private func th(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint).lineLimit(1)
    }
    private func td(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(PSE.dim).lineLimit(1)
    }
    private func num(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 11.5)).foregroundStyle(c).monospacedDigit().lineLimit(1)
    }
}


// ── Scheda bolletta: i dati, la fattura in PDF, e il modo di crearne una ────
//
// Stessa vista per la bolletta che c'è già e per quella nuova. La riga in
// tabella dice quanto si è pagato; qui si attacca il documento che lo dimostra,
// e da qui lo si riapre quando c'è da controllare un conguaglio o discutere un
// addebito col fornitore.
private struct BollettaForm: View {
    let existing: Bolletta?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var allegati: AllegatiStore

    @State private var casa = "via-po"
    @State private var tipo = "luce"
    @State private var fornitore = ""
    @State private var scadenza = Date()
    @State private var periodo = ""
    @State private var importo = ""
    @State private var pagata = true
    @State private var note = ""
    @State private var saving = false
    @State private var confermaElimina = false

    init(existing: Bolletta?, onSaved: @escaping () async -> Void) {
        self.existing = existing; self.onSaved = onSaved
        _allegati = StateObject(wrappedValue: AllegatiStore(entita: .bolletta, entitaId: existing?.id))
    }

    private var cents: Int? {
        let s = importo.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(s), v > 0 else { return nil }
        return Int((v * 100).rounded())
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "NUOVA BOLLETTA" : "BOLLETTA")
                    .font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(PSE.ink)

                HStack(spacing: 12) {
                    pick("Casa", [("via-po", "Via Po"), ("via-romagna", "Via Romagna"), ("comune", "Comune")], casa) { casa = $0 }
                    pick("Tipo", TIPI_BOLLETTA.map { ($0.0, $0.1) }, tipo) { tipo = $0 }
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        etichetta("Scadenza")
                        DatePicker("", selection: $scadenza, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact).colorScheme(.dark)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HoloField(label: "Importo €", text: $importo, placeholder: "112,15").frame(width: 150)
                }
                HoloField(label: "Fornitore", text: $fornitore, placeholder: "Enel, Plenitude, Acquambiente…")
                HoloField(label: "Periodo", text: $periodo, placeholder: "01/03 -> 30/04/26")
                HoloField(label: "Nota", text: $note, placeholder: "Conguaglio, contatore, numero cliente…")

                // Chi la registra di solito l'ha già pagata: il difetto è
                // «pagata», e si toglie la spunta solo per quelle in scadenza.
                Toggle(isOn: $pagata) {
                    Text("Già pagata").font(.system(size: 12.5)).foregroundStyle(PSE.text)
                }
                .toggleStyle(.switch).tint(PSE.pos).fixedSize()

                AllegatiBox(store: allegati, titolo: "FATTURA IN PDF")

                HStack(spacing: 10) {
                    if let b = existing {
                        Button { confermaElimina = true } label: {
                            Text("Elimina").font(.system(size: 13)).foregroundStyle(Color(hex: 0xffb3ad))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }.buttonStyle(.plain)
                        .confirmationDialog("Eliminare questa bolletta?", isPresented: $confermaElimina) {
                            Button("Elimina bolletta", role: .destructive) { Task { await del() } }
                            Button("Annulla", role: .cancel) {}
                        } message: {
                            Text("\(TIPI_BOLLETTA.first { $0.0 == b.tipo }?.1 ?? b.tipo) · \(eurc(b.importo_cents)). Sparisce anche la fattura allegata.")
                        }
                    }
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(PSE.dim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : (existing == nil ? "Salva bolletta" : "Salva modifiche"))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(PSE.warn))
                    }.buttonStyle(.plain).disabled(saving || cents == nil)
                    .opacity(cents == nil ? 0.5 : 1)
                }.padding(.top, 4)
            }
            .padding(22)
        }
        .frame(width: 540, height: 700)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
        .onAppear(perform: fill)
    }

    private func etichetta(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Holo.labelDim)
    }
    private func pick(_ label: String, _ opts: [(String, String)], _ sel: String, _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            etichetta(label)
            Menu {
                ForEach(opts, id: \.0) { o in Button(o.1) { set(o.0) } }
            } label: {
                HStack(spacing: 8) {
                    Text(opts.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 13)).foregroundStyle(PSE.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Holo.labelDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                .contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity)
    }

    private func fill() {
        guard let b = existing else { return }
        casa = b.casa; tipo = b.tipo
        fornitore = b.fornitore ?? ""
        scadenza = svYmd.date(from: String((b.scadenza ?? "").prefix(10))) ?? Date()
        periodo = b.periodo ?? ""
        importo = String(format: "%.2f", Double(b.importo_cents) / 100)
        pagata = b.pagata; note = b.note ?? ""
    }

    private func fields() -> [String: Any?] {
        [ "casa": casa, "tipo": tipo,
          "fornitore": fornitore.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fornitore,
          "scadenza": svYmd.string(from: scadenza),
          "periodo": periodo.trimmingCharacters(in: .whitespaces).isEmpty ? nil : periodo,
          "importo_cents": cents ?? 0, "pagata": pagata,
          "note": note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note ]
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            if let b = existing {
                try await HubAPI.updateBolletta(id: b.id, fields: fields())
            } else {
                // La fattura scelta prima di salvare sale solo adesso: prima
                // non c'era una bolletta a cui attaccarla.
                let creata = try await HubAPI.createBolletta(fields())
                await allegati.salvaInAttesa(su: creata.id)
            }
            await onSaved(); dismiss()
        } catch {}
    }

    private func del() async {
        guard let b = existing else { return }
        do { try await HubAPI.deleteBolletta(id: b.id); await onSaved(); dismiss() } catch {}
    }
}
