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

enum ServizioTab: String, CaseIterable, Identifiable { case pulizie = "Pulizie", colazioni = "Colazioni", utenze = "Utenze"; var id: String { rawValue } }

/// Le due strutture, nell'ordine in cui vanno mostrate come sotto-finestre.
let CASE_PSE: [(String, String)] = [("via-po", "Via Po"), ("via-romagna", "Via Romagna")]

@MainActor final class ServiziModel: ObservableObject {
    @Published var pulizie: [Pulizia] = []
    @Published var colazioni: [Colazione] = []
    @Published var utenze: [EducampRiga] = []
    @Published var bollette: [Bolletta] = []
    @Published var loading = true
    func load() async {
        loading = true
        pulizie = (try? await HubAPI.listPulizie()) ?? []
        colazioni = (try? await HubAPI.listColazioni()) ?? []
        utenze = (try? await HubAPI.listEducampRighe()) ?? []
        bollette = (try? await HubAPI.listBollette()) ?? []
        loading = false
    }
}

struct ServiziView: View {
    @Binding var tab: ServizioTab
    @StateObject private var model = ServiziModel()

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
                        }
                    }.padding(.bottom, 20)
                }
            }
        }
        .task { await model.load() }
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

    private var utenzeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UTENZE CHE PAGHIAMO NOI — DA LUGLIO 2026")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
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
                bolletteTable(bolletteCorrenti, titolo: "BOLLETTE DA LUGLIO 2026")
            }
            Text("Si pagano dal conto corrente, non da Cassa/Massimo/Beeper: per questo non compaiono tra i movimenti e non toccano i saldi. Acqua, immondizia e IMU non erano nel foglio del maestro — le voci sono pronte, vanno solo riempite. Le utenze addebitate agli inquilini Educamp sono un'altra cosa e stanno nella scheda Educamp.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)

            if !bolletteStorico.isEmpty {
                Text("PRIMA DI LUGLIO 2026 — ARCHIVIO, FUORI DAL CONTEGGIO")
                    .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint).padding(.top, 10)
                bolletteTable(bolletteStorico, titolo: nil, spenta: true)
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
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(Array(righe.enumerated()), id: \.element.id) { i, b in
                HStack(spacing: 10) {
                    num(svDayYStr(b.scadenza), PSE.dim).frame(width: 78, alignment: .leading)
                    td(casaLbl(b.casa)).frame(width: 96, alignment: .leading)
                    Text(TIPI_BOLLETTA.first { $0.0 == b.tipo }?.1 ?? b.tipo.capitalized)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(spenta ? PSE.dim : PSE.ink)
                        .frame(width: 86, alignment: .leading).lineLimit(1)
                    td(b.fornitore ?? "—").frame(width: 110, alignment: .leading)
                    td(b.periodo ?? b.note ?? "—").frame(maxWidth: .infinity, alignment: .leading)
                    num(eurc(b.importo_cents), spenta ? PSE.dim : PSE.neg).frame(width: 84, alignment: .trailing)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
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
