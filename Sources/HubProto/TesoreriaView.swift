import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ============================================================================
// Camere PSE — Tesoreria (dentro il progetto Camere PSE)
// Conti (Cassa / Massimo OTA / Beeper), Movimenti entrate·uscite, Riepilogo,
// Conto economico, Educamp e Servizi (Pulizia 20€/check-out, Colazioni
// 3,50€/pers·notte Booking).
// Sorgente: public.conti + public.movimenti (+ pulizie/colazioni per i servizi).
// Tutti gli importi in contabilità si mostrano con i centesimi: eurc().
// ============================================================================

struct Conto: Identifiable, Decodable, Equatable {
    let id: String
    var nome: String
    var tipo: String
    var sort_order: Int
}

struct TesMovimento: Identifiable, Decodable, Equatable {
    let id: String
    var data: String
    var struttura: String?
    var tipo: String            // entrata | uscita
    var categoria: String?
    var descrizione: String?
    var importo_cents: Int
    var modalita: String?
    var conto_id: String?
    /// Soggiorno che ha generato il movimento, quando lo conosciamo: serve a
    /// mostrare notti e prezzo per notte nel dettaglio per casa.
    var prenotazione_id: String?
}

extension HubAPI {
    static func listConti() async throws -> [Conto] { try await sb.fetch("conti?select=*&order=sort_order.asc") }
    static func listMovimenti() async throws -> [TesMovimento] { try await sb.fetch("movimenti?select=*&order=data.desc&limit=3000") }
    @discardableResult
    static func createTesMovimento(_ f: [String: Any?]) async throws -> TesMovimento { try await sb.insertReturning("movimenti", body: f) }
    static func updateTesMovimento(id: String, fields: [String: Any?]) async throws {
        var b = fields; b["updated_at"] = isoNowString()
        try await sb.mutate("movimenti?id=eq.\(id)", method: "PATCH", body: b)
    }
    static func deleteTesMovimento(id: String) async throws { try await sb.mutate("movimenti?id=eq.\(id)", method: "DELETE") }
    static func deleteMovimentoByExtKey(_ key: String) async throws {
        let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        try await sb.mutate("movimenti?ext_key=eq.\(enc)", method: "DELETE")
    }
}

private let tesYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let tesPretty: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM"; return f }()
private func tesDate(_ s: String?) -> Date? { s.flatMap { tesYmd.date(from: String($0.prefix(10))) } }
private func tesPrettyStr(_ s: String?) -> String { tesDate(s).map { tesPretty.string(from: $0) } ?? "—" }

// Tariffe dei servizi: le righe vere stanno nelle tabelle public.pulizie e
// public.colazioni (sezione Servizi), queste restano come riferimento del calcolo.
let CLEAN_COST = 2000      // 20,00 € per check-out
let BREAKFAST_COST = 350   // 3,50 € per persona/notte (solo Booking)

@MainActor final class TesoreriaModel: ObservableObject {
    @Published var conti: [Conto] = []
    @Published var movimenti: [TesMovimento] = []
    // Pulizie e colazioni arrivano dalle stesse tabelle che legge la sezione
    // Servizi: il Riepilogo non li ricalcola dalle prenotazioni, altrimenti le
    // due schermate mostrerebbero due numeri diversi per la stessa voce.
    @Published var pulizie: [Pulizia] = []
    @Published var colazioni: [Colazione] = []
    // Righe Educamp: servono per il «da incassare» netto degli ospiti di Via
    // Romagna, che sono la fonte OTA-equivalente di quella struttura.
    @Published var educampRighe: [EducampRiga] = []
    /// Quanti allegati ha ciascun movimento, per mostrare la graffetta in
    /// tabella: una sola query per tutti, non una per riga.
    @Published var allegatiPerMov: [String: Int] = [:]
    @Published var loading = true
    func load() async {
        loading = true
        conti = (try? await HubAPI.listConti()) ?? []
        movimenti = (try? await HubAPI.listMovimenti()) ?? []
        pulizie = (try? await HubAPI.listPulizie()) ?? []
        colazioni = (try? await HubAPI.listColazioni()) ?? []
        educampRighe = (try? await HubAPI.listEducampRighe()) ?? []
        allegatiPerMov = (try? await HubAPI.contaAllegati(.movimento)) ?? [:]
        loading = false
    }
    func ricontaAllegati() async {
        allegatiPerMov = (try? await HubAPI.contaAllegati(.movimento)) ?? [:]
    }
    /// Quello che gli ospiti Educamp pagano in tutto (affitto + utenze): è la
    /// base giusta per il «da incassare», perché è ciò che entra davvero in cassa.
    var educampTotaleOspite: Int { educampRighe.reduce(0) { $0 + $1.totale_ospite_cents } }
    /// Netto che resta a noi dopo la commissione dell'intermediario (il nostro
    /// utile Educamp), non ciò che si incassa.
    var educampNettoTotale: Int { educampRighe.reduce(0) { $0 + $1.netto_noi_cents } }
    /// Quanto degli Educamp è già entrato sui conti (movimenti categoria «educamp»).
    var educampIncassato: Int {
        movimenti.filter { $0.tipo == "entrata" && $0.categoria == "educamp" }.reduce(0) { $0 + $1.importo_cents }
    }
    /// Da incassare = quello che gli ospiti devono ancora versare (stessa base
    /// dell'incassato), non netto − lordo come prima.
    var educampDaIncassare: Int { max(0, educampTotaleOspite - educampIncassato) }
    func saldo(_ contoId: String) -> Int {
        var t = 0
        for m in movimenti where m.conto_id == contoId {
            t += (m.tipo == "entrata") ? m.importo_cents : -m.importo_cents
        }
        return t
    }
    var totaleConti: Int {
        var t = 0
        for c in conti { t += saldo(c.id) }
        return t
    }
}

// L'ordine dei case è quello delle schede a schermo (CaseIterable segue la
// dichiarazione): prima le viste d'insieme e operative, in fondo le sezioni
// specialistiche (depositi cauzionali, Educamp).
enum TesSub: String, CaseIterable, Identifiable { case riepilogo = "Riepilogo", conti = "Conti", contoEconomico = "Conto economico", servizi = "Servizi", movimenti = "Movimenti", depositi = "Depositi", educamp = "Educamp"; var id: String { rawValue } }

// ── Sotto-finestre di dettaglio del Riepilogo ────────────────────────────────
// Riga generica: un movimento, una prenotazione o una voce di riepilogo.
struct DettaglioRiga: Identifiable {
    let id: String
    var data: String = ""
    let descrizione: String
    var extra: String = ""      // casa · conto · canale
    let importo: Int
    var positivo: Bool = true
    var mostraSegno: Bool = true
}

// Finestra che elenca le righe di una card, con nota e totale. Riusa lo stile
// delle tabelle della Tesoreria così il dettaglio è coerente ovunque.
struct DettaglioVoceSheet: View {
    let titolo: String
    var nota: String = ""
    let righe: [DettaglioRiga]
    var totaleLabel: String = "TOTALE"
    var totale: Int? = nil
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(titolo).font(.system(size: 14, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 10, trailing: 16))
            if !nota.isEmpty {
                Text(nota).font(.system(size: 11)).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            if righe.isEmpty {
                Text("Nessuna voce.").font(.system(size: 12)).foregroundStyle(PSE.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(righe) { r in
                            HStack(spacing: 12) {
                                if !r.data.isEmpty {
                                    Text(r.data).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
                                        .frame(width: 62, alignment: .leading).monospacedDigit()
                                }
                                Text(r.descrizione).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                if !r.extra.isEmpty {
                                    Text(r.extra).font(.system(size: 11)).foregroundStyle(PSE.faint)
                                        .frame(width: 150, alignment: .leading).lineLimit(1)
                                }
                                Text((r.mostraSegno ? (r.positivo ? "+" : "−") : "") + eurc(r.importo))
                                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(r.mostraSegno ? (r.positivo ? PSE.pos : PSE.neg) : PSE.ink)
                                    .frame(width: 100, alignment: .trailing)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 9)
                            Divider().overlay(PSE.line).padding(.leading, 20)
                        }
                    }
                }
                if let totale {
                    HStack {
                        Text(totaleLabel).font(.system(size: 11, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                        Spacer()
                        Text(eurc(totale)).font(.system(size: 15, weight: .bold)).foregroundStyle(PSE.accent).monospacedDigit()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12).background(Color.white.opacity(0.04))
                }
            }
        }
        .frame(width: 760, height: 560)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
    }
}

// Le voci del Riepilogo che aprono una sotto-finestra al click.
enum RiepVoce: Identifiable {
    case conto(String)                       // id conto → estratto
    case totaleConti
    case nostroReale
    case potenziale
    case daIncassareSrc(String, [String])    // titolo, fonti
    case daIncassareConto(String)            // id conto → residuo di quel conto
    case daIncassareEducamp
    case daIncassareTotale
    case casa(Struttura)
    // Conto economico
    case ricavi
    case costiOperativi
    case debiti
    case cauzioniApporti
    // Movimenti / Conti: un elenco di movimenti già filtrato, con titolo
    case movimenti(String, [TesMovimento], Int)
    var id: String {
        switch self {
        case .conto(let c): return "conto-\(c)"
        case .totaleConti: return "tot"
        case .nostroReale: return "nostro"
        case .potenziale: return "pot"
        case .daIncassareSrc(let t, _): return "inc-\(t)"
        case .daIncassareConto(let c): return "inc-conto-\(c)"
        case .daIncassareEducamp: return "inc-edu"
        case .daIncassareTotale: return "inc-tot"
        case .casa(let s): return "casa-\(s.rawValue)"
        case .ricavi: return "ricavi"
        case .costiOperativi: return "costiop"
        case .debiti: return "debiti"
        case .cauzioniApporti: return "cauzapp"
        case .movimenti(let t, _, _): return "mov-\(t)"
        }
    }
}

// nome mese esteso "MMMM yyyy" da chiave "yyyy-MM"
private let tesMese: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMMM yyyy"; return f }()
private func meseNome(_ key: String) -> String {
    guard let d = tesYmd.date(from: key + "-01") else { return key }
    return tesMese.string(from: d).capitalized
}

struct TesoreriaView: View {
    let prenotazioni: [Prenotazione]
    @Binding var newTrigger: Bool
    @StateObject private var model = TesoreriaModel()
    @State private var sub: TesSub = .riepilogo
    @State private var showForm = false
    @State private var editing: TesMovimento?
    @State private var movStrut: Struttura? = nil
    // "tutto" | "2026" (anno) | "2026-07" (mese): il confronto è per prefisso, così
    // la stessa voce di menu copre sia gli anni sia i mesi.
    @State private var periodo: String = "tutto"
    @State private var cerca: String = ""
    @State private var contoSel: String = "tutti"     // "tutti" = tutti i conti insieme; altrimenti id conto
    @State private var servizioSel: ServizioTab = .pulizie
    // Quale scheda servizi aprire in dettaglio dal Riepilogo (nil = nessuna)
    @State private var servizioSheet: ServizioTab?
    // Quale card del Riepilogo aprire in dettaglio
    @State private var voceSheet: RiepVoce?
    // Movimenti: di default nasconde le entrate datate in avanti (incassi di
    // prenotazioni future non ancora avvenuti), così la lista è il denaro reale.
    @State private var soloFinoAOggi = true

    private var oggiStr: String { tesYmd.string(from: Date()) }

    /// Il Riepilogo e l'Educamp non hanno filtri: senza questo la seconda riga
    /// resterebbe vuota lasciando un buco sotto le sezioni.
    private var mostraFiltri: Bool { sub != .riepilogo && sub != .educamp }
    private func nelPeriodo(_ m: TesMovimento) -> Bool { periodo == "tutto" || m.data.hasPrefix(periodo) }
    private func matchCerca(_ m: TesMovimento) -> Bool {
        let q = cerca.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return [m.descrizione, m.categoria, m.modalita].contains { ($0 ?? "").lowercased().contains(q) }
    }
    private var visibiliMov: [TesMovimento] {
        model.movimenti.filter { m in
            (movStrut == nil || m.struttura == movStrut!.rawValue) && nelPeriodo(m) && matchCerca(m)
            && (!soloFinoAOggi || m.data <= oggiStr)   // niente entrate future se il filtro è attivo
        }
    }
    private var movEntrate: Int { var t = 0; for m in visibiliMov where m.tipo == "entrata" { t += m.importo_cents }; return t }
    private var movUscite: Int { var t = 0; for m in visibiliMov where m.tipo == "uscita" { t += m.importo_cents }; return t }
    private var anniDisponibili: [String] { Set(model.movimenti.map { String($0.data.prefix(4)) }).sorted(by: >) }
    private var mesiDisponibili: [(String, String)] {
        let keys = Set(model.movimenti.map { String($0.data.prefix(7)) })
        return keys.sorted(by: >).compactMap { k in
            guard tesYmd.date(from: k + "-01") != nil else { return nil }
            return (k, meseNome(k))
        }
    }
    private var periodoLabel: String {
        if periodo == "tutto" { return "Tutti i periodi" }
        if periodo.count == 4 { return "Anno \(periodo)" }
        return mesiDisponibili.first { $0.0 == periodo }?.1 ?? periodo
    }
    private func casaStats(_ s: Struttura) -> (inc: Int, spese: Int) {
        var inc = 0, spese = 0
        for m in model.movimenti where m.struttura == s.rawValue {
            // Cauzioni da restituire e capitale dei soci restano fuori dal «generato»
            // (vedi fuoriDalGenerato). Il deposito trattenuto (no-show) è ricavo e resta.
            if fuoriDalGenerato(m) { continue }
            if m.tipo == "entrata" { inc += m.importo_cents } else { spese += m.importo_cents }
        }
        return (inc, spese)
    }
    private var prenFiltrate: [Prenotazione] { prenotazioni.filter { $0.status != "cancellata" } }

    // ── servizi: stessi dati della sezione Servizi (tabelle pulizie/colazioni) ──
    private var puliziaFatte: Int { model.pulizie.filter { $0.stato == "fatta" }.reduce(0) { $0 + $1.costo_cents } }
    private var puliziePreviste: Int { model.pulizie.filter { $0.stato != "fatta" }.reduce(0) { $0 + $1.costo_cents } }
    private var colazioni: (servite: Int, totale: Int) {
        (model.colazioni.reduce(0) { $0 + $1.costo_servito_cents },
         model.colazioni.reduce(0) { $0 + $1.costo_totale_cents })
    }
    // Conto di destinazione dei soldi: OTA → Massimo, dirette → il conto scelto,
    // e se non è stato scelto, Cassa (le dirette sono in contante salvo bonifico).
    private func contoDest(_ b: Prenotazione) -> String {
        if let c = b.conto_id, !c.isEmpty { return c }
        let s = b.source ?? ""
        return (s == "booking" || s == "airbnb") ? "massimo" : "cassa"
    }
    /// Residuo ancora da incassare di una prenotazione. Le OTA (Booking/Airbnb)
    /// si considerano incassate una volta passato il checkout — Booking paga a
    /// soggiorno concluso — quindi escono da sole dal «da incassare» quando la
    /// data passa, senza dover aggiornare paid_cents a mano. Dirette ed Educamp
    /// seguono invece il pagato reale: il contante non arriva col checkout.
    private func residuoIncassare(_ b: Prenotazione) -> Int {
        let src = b.source ?? ""
        if (src == "booking" || src == "airbnb"), let co = b.checkout, co <= oggiStr { return 0 }
        return max(0, b.amount_cents - b.paid_cents)
    }
    private func daIncassare(_ contoId: String) -> Int {
        var t = 0
        for b in prenFiltrate where contoDest(b) == contoId {
            t += residuoIncassare(b)
        }
        return t
    }
    // da incassare del periodo/casa selezionati (checkin nel periodo, filtro casa)
    private var daIncassarePeriodo: Int {
        var t = 0
        for b in prenFiltrate {
            if let s = movStrut, b.struttura != s.rawValue { continue }
            if periodo != "tutto" && !(b.checkin ?? "").hasPrefix(periodo) { continue }
            t += residuoIncassare(b)
        }
        return t
    }
    // Somma da-incassare di OTA + dirette, MA senza l'Educamp: nel «potenziale»
    // e nel «totale da incassare» l'Educamp è aggiunto a parte come netto
    // (educampDaIncassare, dal foglio). Le prenotazioni source "educamp" stanno
    // sui conti cassa/beeper, quindi sommarle qui le conterebbe due volte.
    // (Le card per-conto invece le includono: quei soldi arrivano davvero lì.)
    private var daIncassareTot: Int {
        var t = 0
        for b in prenFiltrate where (b.source ?? "") != "educamp" {
            t += residuoIncassare(b)
        }
        return t
    }
    // da incassare per canale/fonte
    private func daIncassareSource(_ srcs: [String]) -> Int {
        var t = 0
        for b in prenFiltrate where srcs.contains(b.source ?? "") {
            t += residuoIncassare(b)
        }
        return t
    }
    private var daIncassareDirette: Int { daIncassareSource(["diretto", "sito", "whatsapp", "telefono", "email"]) }
    // Booking trattiene il 16,5%: quanto del «da incassare» lordo non arriverà mai
    // sul conto. Airbnb e dirette non hanno commissione.
    private var commissioneAttesa: Int { Int((Double(daIncassareSource(["booking"])) * 0.165).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Due righe: sopra le sezioni, sotto i filtri della sezione scelta.
            // Su una riga sola i comandi non ci stavano e le etichette venivano
            // schiacciate fino ad andare a capo una lettera per riga.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    PSESegmented(items: TesSub.allCases.map { ($0, $0.rawValue) }, selection: $sub)
                    Spacer(minLength: 12)
                    if sub == .movimenti {
                        Text("\(visibiliMov.count) movimenti").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PSE.faint).lineLimit(1).fixedSize()
                    }
                    if sub == .conti || sub == .contoEconomico || sub == .movimenti { exportButton }
                }
                if mostraFiltri {
                    HStack(spacing: 12) {
                        if sub == .conti {
                            PSESegmented(items: [("tutti", "Tutti i conti")] + model.conti.map { ($0.id, $0.nome) }, selection: $contoSel)
                        } else if sub == .servizi {
                            PSESegmented(items: ServizioTab.allCases.map { ($0, $0.rawValue) }, selection: $servizioSel)
                        }
                        if sub == .conti || sub == .contoEconomico || sub == .movimenti {
                            PSESegmented(items: [(nil, "Tutte"), (.viaPo, "Via Po"), (.viaRomagna, "Via Romagna")] as [(Struttura?, String)], selection: $movStrut)
                        }
                        if sub == .conti || sub == .contoEconomico || sub == .movimenti { periodoMenu }
                        if sub == .movimenti { campoCerca; togglefuturi }
                        Spacer(minLength: 0)
                    }
                }
            }
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    switch sub {
                    case .riepilogo: riepilogo
                    case .conti: contiView
                    case .depositi: depositiView
                    case .contoEconomico: contoEconomico
                    // I movimenti arrivano da qui: registrato un incasso, il
                    // modello si ricarica e le spunte «pagato» seguono subito.
                    case .educamp: EducampView(movimenti: model.movimenti)
                    case .servizi: ServiziView(tab: $servizioSel)
                    case .movimenti: movimentiList
                    }
                }
            }
        }
        .task { await model.load() }
        .onChange(of: newTrigger) { _, v in
            if v { editing = nil; sub = .movimenti; showForm = true; newTrigger = false }
        }
        // Il riconteggio serve anche a chi chiude con Annulla dopo aver solo
        // attaccato una fattura: il salvataggio non passa di lì.
        .sheet(isPresented: $showForm, onDismiss: { editing = nil; Task { await model.ricontaAllegati() } }) {
            TesMovimentoForm(conti: model.conti, existing: editing) { await model.load() }
        }
        .sheet(item: $servizioSheet) { tab in
            ServizioDettaglioSheet(tab: tab) { servizioSheet = nil }
        }
        .sheet(item: $voceSheet) { v in
            let d = dettaglioVoce(v)
            DettaglioVoceSheet(titolo: d.titolo, nota: d.nota, righe: d.righe,
                               totaleLabel: d.totaleLabel, totale: d.totale) { voceSheet = nil }
        }
    }

    // ── Contenuto delle sotto-finestre del Riepilogo ─────────────────────────
    private func rigaDaMov(_ m: TesMovimento) -> DettaglioRiga {
        DettaglioRiga(id: m.id, data: tesPrettyStr(m.data),
                      descrizione: m.descrizione ?? (m.categoria ?? "—"),
                      extra: contoNomeBreve(m.conto_id) + (m.struttura != nil ? " · \(casaLabel(m.struttura))" : ""),
                      importo: m.importo_cents, positivo: m.tipo == "entrata")
    }
    private func rigaDaPren(_ b: Prenotazione) -> DettaglioRiga {
        let res = residuoIncassare(b)
        return DettaglioRiga(id: b.id, data: "\(tesPrettyStr(b.checkin))",
                             descrizione: b.guest_name + (b.camera.map { " · \($0)" } ?? ""),
                             extra: (b.source ?? "—").capitalized + " · " + casaLabel(b.struttura),
                             importo: res, positivo: true, mostraSegno: false)
    }
    private func dettaglioVoce(_ v: RiepVoce) -> (titolo: String, nota: String, righe: [DettaglioRiga], totaleLabel: String, totale: Int?) {
        switch v {
        case .conto(let id):
            let c = model.conti.first { $0.id == id }
            let mov = model.movimenti.filter { $0.conto_id == id }.sorted { $0.data > $1.data }
            return ("\(c?.nome.uppercased() ?? "CONTO") — ESTRATTO", contoNotaFor(id),
                    mov.map { rigaDaMov($0) }, "SALDO", model.saldo(id))
        case .totaleConti:
            let mov = model.movimenti.sorted { $0.data > $1.data }
            return ("TOTALE CONTI — TUTTI I MOVIMENTI",
                    "Cassa + Massimo + Beeper insieme. La colonna indica dove è transitato il denaro.",
                    mov.map { rigaDaMov($0) }, "SALDO TOTALE", model.totaleConti)
        case .nostroReale:
            return ("NOSTRO REALE — DEPOSITI DA TOGLIERE",
                    "Il «nostro reale» è il totale conti (\(eurc(model.totaleConti))) meno i depositi cauzionali qui sotto, che sono degli inquilini e vanno restituiti.",
                    depositiMov.map { rigaDaMov($0) }, "DEPOSITI DA RESTITUIRE", depositiDaRestituire)
        case .potenziale:
            let righe = [
                DettaglioRiga(id: "conti", descrizione: "Già sui conti (incassato)", importo: model.totaleConti, mostraSegno: false),
                DettaglioRiga(id: "booking", descrizione: "Booking da incassare (lordo)", importo: daIncassareSource(["booking"]), mostraSegno: false),
                DettaglioRiga(id: "airbnb", descrizione: "Airbnb da incassare", importo: daIncassareSource(["airbnb"]), mostraSegno: false),
                DettaglioRiga(id: "dirette", descrizione: "Dirette da incassare", importo: daIncassareDirette, mostraSegno: false),
                DettaglioRiga(id: "educamp", descrizione: "Educamp da incassare (netto)", importo: model.educampDaIncassare, mostraSegno: false),
            ]
            return ("POTENZIALE — DA COSA È COMPOSTO",
                    "Quanto ci sarebbe sui conti incassando tutte le prenotazioni confermate. È un tetto: le commissioni OTA non sono ancora tolte.",
                    righe, "POTENZIALE", model.totaleConti + daIncassareTot + model.educampDaIncassare)
        case .daIncassareSrc(let titolo, let fonti):
            let pren = prenFiltrate.filter { fonti.contains($0.source ?? "") && residuoIncassare($0) > 0 }
                .sorted { ($0.checkin ?? "") < ($1.checkin ?? "") }
            return ("\(titolo.uppercased()) — DA INCASSARE",
                    "Prenotazioni confermate con soldi non ancora incassati. Importi lordi (quello che il cliente paga all'OTA).",
                    pren.map { rigaDaPren($0) }, "TOTALE", pren.reduce(0) { $0 + residuoIncassare($1) })
        case .daIncassareConto(let id):
            // prenotazioni confermate i cui soldi entreranno su QUESTO conto ma non
            // ancora incassate: è la parte «che deve arrivare» del conto.
            let pren = prenFiltrate.filter { contoDest($0) == id && residuoIncassare($0) > 0 }
                .sorted { ($0.checkin ?? "") < ($1.checkin ?? "") }
            let nome = model.conti.first { $0.id == id }?.nome.uppercased() ?? contoNomeBreve(id).uppercased()
            return ("\(nome) — DA INCASSARE",
                    "Prenotazioni confermate i cui incassi finiranno su questo conto ma non sono ancora entrati. Il saldo mostra i soldi già in cassa; questo è quanto deve ancora arrivare.",
                    pren.map { rigaDaPren($0) }, "TOTALE DA INCASSARE", pren.reduce(0) { $0 + residuoIncassare($1) })
        case .daIncassareEducamp:
            // ospiti Educamp con residuo da versare (per mese, dal foglio)
            let righe = model.educampRighe.filter { $0.totale_ospite_cents > 0 }
                .sorted { ($0.ospite, $0.mese) < ($1.ospite, $1.mese) }
                .map { r in DettaglioRiga(id: r.id, descrizione: r.ospite, extra: meseNome(r.mese),
                                          importo: r.totale_ospite_cents, mostraSegno: false) }
            return ("EDUCAMP — DA INCASSARE",
                    "Totale che gli ospiti Educamp pagano (\(eurc(model.educampTotaleOspite))) meno il già incassato (\(eurc(model.educampIncassato))) = \(eurc(model.educampDaIncassare)). Sotto, il dovuto per ospite e mese.",
                    righe, "TOTALE DOVUTO OSPITI", model.educampTotaleOspite)
        case .daIncassareTotale:
            let righe = [
                DettaglioRiga(id: "b", descrizione: "Booking (lordo)", importo: daIncassareSource(["booking"]), mostraSegno: false),
                DettaglioRiga(id: "a", descrizione: "Airbnb", importo: daIncassareSource(["airbnb"]), mostraSegno: false),
                DettaglioRiga(id: "d", descrizione: "Dirette", importo: daIncassareDirette, mostraSegno: false),
                DettaglioRiga(id: "e", descrizione: "Educamp (netto)", importo: model.educampDaIncassare, mostraSegno: false),
            ]
            return ("TOTALE DA INCASSARE", "Somma di tutto ciò che resta da incassare.",
                    righe, "TOTALE", daIncassareTot + model.educampDaIncassare)
        case .casa(let s):
            // Solo i movimenti che entrano nel «generato»: cauzioni e apporti fuori
            // (coerente con casaStats), altrimenti la lista non tornerebbe con l'utile.
            let mov = model.movimenti.filter { $0.struttura == s.rawValue && !fuoriDalGenerato($0) }.sorted { $0.data > $1.data }
            let st = casaStats(s)
            return ("\(s.label.uppercased()) — GENERATO",
                    "Entrate \(eurc(st.inc)) · spese \(eurc(st.spese)) · utile \(eurc(st.inc - st.spese)). Cauzioni e apporti soci sono esclusi (li trovi in «Depositi» e «Conto economico»).",
                    mov.map { rigaDaMov($0) }, "UTILE", st.inc - st.spese)
        case .ricavi:
            let mov = movStrutFiltrati.filter { $0.tipo == "entrata" && !isEntrataNonRicavo($0.categoria) }.sorted { $0.data > $1.data }
            return ("RICAVI — \(periodoLabel.uppercased())", "Entrate da attività (esclusi cauzioni e apporti soci).",
                    mov.map { rigaDaMov($0) }, "TOTALE RICAVI", totEntrate)
        case .costiOperativi:
            let mov = movStrutFiltrati.filter { $0.tipo == "uscita" && !isDebito($0.categoria) }.sorted { $0.data > $1.data }
            return ("COSTI OPERATIVI — \(periodoLabel.uppercased())", "Costi di gestione (senza debiti/finanziamenti).",
                    mov.map { rigaDaMov($0) }, "TOTALE COSTI", totCostiOperativi)
        case .debiti:
            let mov = movStrutFiltrati.filter { $0.tipo == "uscita" && isDebito($0.categoria) }.sorted { $0.data > $1.data }
            return ("DEBITI / FINANZIAMENTI", "Rimborsi (debito vecchio, mutuo, rata): fuori dal margine operativo.",
                    mov.map { rigaDaMov($0) }, "TOTALE DEBITI", totDebiti)
        case .cauzioniApporti:
            let mov = movStrutFiltrati.filter { $0.tipo == "entrata" && isEntrataNonRicavo($0.categoria) }.sorted { $0.data > $1.data }
            return ("CAUZIONI + APPORTI SOCI", "Entrate che non sono ricavi: depositi da restituire e capitale dei soci.",
                    mov.map { rigaDaMov($0) }, "TOTALE", totEntrateFinanziarie)
        case .movimenti(let titolo, let mov, let tot):
            return (titolo.uppercased(), "", mov.sorted { $0.data > $1.data }.map { rigaDaMov($0) }, "TOTALE", tot)
        }
    }
    private func contoNotaFor(_ id: String) -> String {
        switch id {
        case "massimo": return "Conto delle OTA di Via Po: Booking (lordo entrata / commissione uscita) e Airbnb. Il saldo è il netto."
        case "beeper": return "Bonifici (entrambe le case): affitti, depositi da restituire, apporti soci e uscite."
        default: return "Contante Via Po + Via Romagna."
        }
    }

    // ── Riepilogo (conti + servizi uniti) ──
    // Ogni card del Riepilogo è un pulsante che apre la sua sotto-finestra, con
    // la freccetta a destra come le card servizi.
    private func clic<V: View>(_ v: RiepVoce, @ViewBuilder _ card: () -> V) -> some View {
        Button { voceSheet = v } label: {
            card().overlay(alignment: .trailing) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PSE.faint).padding(.trailing, 14)
            }
        }.buttonStyle(.plain)
    }
    // Colonne a larghezza uguale, riusate da tutte le sezioni così le card di
    // righe diverse restano allineate in verticale.
    private func cols(_ n: Int) -> [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12), count: n) }
    // Intestazione di sezione uniforme (stesso peso/tracking ovunque).
    private func sezione(_ t: String, _ c: Color = PSE.faint) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(c)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
    private func nota(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5)).foregroundStyle(PSE.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
    // Totale a barra piena: chiude una sezione senza lasciare celle vuote.
    private func totaleStrip(_ t: String, _ v: Int, _ c: Color, _ voce: RiepVoce) -> some View {
        Button { voceSheet = voce } label: {
            HStack(spacing: 10) {
                Text(t).font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.dim)
                Spacer()
                Text(eurc(v)).font(.system(size: 17, weight: .bold)).foregroundStyle(c).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(PSE.faint)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(c.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.opacity(0.30), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var riepilogo: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── CONTI ──────────────────────────────────────────────────────
            sezione("CONTI — saldo attuale").padding(.top, 0)
            LazyVGrid(columns: cols(3), spacing: 12) {
                ForEach(model.conti) { c in clic(.conto(c.id)) { contoCard(c) } }
            }
            LazyVGrid(columns: cols(3), spacing: 12) {
                clic(.totaleConti) { totCard("TOTALE CONTI (incassato, netto)", model.totaleConti, PSE.accent) }
                clic(.nostroReale) { totCard("NOSTRO REALE (netto depositi)", nostroReale, nostroReale < 0 ? PSE.neg : PSE.pos) }
                clic(.potenziale) { totCard("POTENZIALE (+ da incassare)", model.totaleConti + daIncassareTot + model.educampDaIncassare, PSE.pos) }
            }
            if depositiDaRestituire > 0 {
                nota("Sui conti ci sono \(eurc(depositiDaRestituire)) di depositi cauzionali da restituire agli inquilini (dettaglio nella scheda «Depositi»): il «nostro reale» li toglie dal totale.")
            }

            // ── DA INCASSARE ───────────────────────────────────────────────
            sezione("DA INCASSARE — prenotazioni confermate, non ancora incassate", PSE.warn)
            LazyVGrid(columns: cols(4), spacing: 12) {
                clic(.daIncassareSrc("Booking", ["booking"])) { totCard("BOOKING (lordo)", daIncassareSource(["booking"]), PSE.warn) }
                clic(.daIncassareSrc("Airbnb", ["airbnb"])) { totCard("AIRBNB", daIncassareSource(["airbnb"]), PSE.warn) }
                clic(.daIncassareSrc("Dirette", ["diretto", "sito", "whatsapp", "telefono", "email"])) { totCard("DIRETTE", daIncassareDirette, PSE.warn) }
                clic(.daIncassareEducamp) { totCard("EDUCAMP (netto)", model.educampDaIncassare, PSE.warn) }
            }
            totaleStrip("TOTALE DA INCASSARE", daIncassareTot + model.educampDaIncassare, PSE.pos, .daIncassareTotale)
            nota("Educamp (Via Romagna): gli ospiti pagano \(eurc(model.educampTotaleOspite)) in tutto, di cui \(eurc(model.educampIncassato)) già in cassa/beeper → \(eurc(model.educampDaIncassare)) ancora da incassare. Di quel totale, il netto che resta a noi (dopo la commissione) è \(eurc(model.educampNettoTotale)). Dettaglio mese per mese nella scheda Educamp.")

            // ── PER CASA ───────────────────────────────────────────────────
            sezione("PER CASA — entrate, spese e utile registrati")
            LazyVGrid(columns: cols(2), spacing: 12) {
                clic(.casa(.viaPo)) { casaCard(.viaPo) }
                clic(.casa(.viaRomagna)) { casaCard(.viaRomagna) }
            }

            // ── SERVIZI ────────────────────────────────────────────────────
            sezione("SERVIZI")
            LazyVGrid(columns: cols(4), spacing: 12) {
                servCard("PULIZIA — FATTE", puliziaFatte, "sparkles", PSE.pos) { servizioSheet = .pulizie }
                servCard("PULIZIA — PREVISTE", puliziePreviste, "sparkles", PSE.warn) { servizioSheet = .pulizie }
                servCard("COLAZIONI — SERVITE", colazioni.servite, "cup.and.saucer.fill", PSE.pos) { servizioSheet = .colazioni }
                servCard("COLAZIONI — PREVISTE", colazioni.totale - colazioni.servite, "cup.and.saucer.fill", PSE.warn) { servizioSheet = .colazioni }
            }

            // ── note ───────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 7) {
                nota("I saldi dei conti sono NETTI (su Massimo la commissione Booking è già registrata come uscita); il «da incassare» invece è LORDO, quello che il cliente paga all'OTA. Su Booking arriverà circa il 16,5% in meno — oggi ≈ \(eurc(commissioneAttesa)) — mentre Airbnb e le dirette non hanno commissione. Perciò il «potenziale» è un tetto, non l'incasso atteso.")
                nota("OTA (Booking/Airbnb) → conto Massimo · dirette → Beeper o Cassa (scelto per prenotazione). Pulizia 20 €/check-out. Le colazioni Booking (3,50 €/pers·notte) sono aggiunte automaticamente ai Movimenti.")
            }
            .padding(.top, 12)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1).padding(.top, 4), alignment: .top)
        }.padding(.bottom, 20)
    }
    private func contoCard(_ c: Conto) -> some View {
        let s = model.saldo(c.id)
        let inc = daIncassare(c.id)
        return VStack(alignment: .leading, spacing: 7) {
            Text(c.nome.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.5).foregroundStyle(PSE.faint).lineLimit(1)
            Text(eurc(s)).font(.system(size: 22, weight: .bold)).foregroundStyle(s < 0 ? PSE.neg : PSE.ink).monospacedDigit()
            if inc > 0 {
                Text("+ \(eurc(inc)) da incassare\(c.tipo == "ota" ? " (lordo)" : "")").font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.warn)
            } else {
                Text(c.tipo == "cassa" ? "Contante" : c.tipo == "ota" ? "Booking + Airbnb" : "Banca").font(.system(size: 10)).foregroundStyle(PSE.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    // toggle «solo fino a oggi» per i movimenti
    private var togglefuturi: some View {
        Button { soloFinoAOggi.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: soloFinoAOggi ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11)).foregroundStyle(soloFinoAOggi ? PSE.accent : PSE.dim)
                Text("Solo fino a oggi").font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.dim).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
        }.buttonStyle(.plain).help("Nasconde le entrate datate in avanti (incassi non ancora avvenuti)")
    }

    // ══ DEPOSITI — cauzioni da restituire, separate dal denaro nostro ═════════
    // Un deposito cauzionale è denaro dell'inquilino che teniamo e dovremo
    // rendere: non è utile nostro. Qui si separa il «nostro reale».
    private func isDeposito(_ m: TesMovimento) -> Bool {
        m.categoria == "deposito" && !(m.descrizione ?? "").lowercased().contains("trattenut")
    }
    // Movimento che sta FUORI dal «generato» di una casa: capitale dei soci
    // (apporto) e cauzioni da restituire (deposito non trattenuto) non sono né
    // ricavi né spese — sono soldi di terzi/soci che entrano ed escono. Vanno
    // esclusi da tutte le viste «generato/per casa». Restano invece nel saldo
    // vero del conto (senza filtro casa), perché il denaro è davvero lì.
    // Il deposito TRATTENUTO (penale no-show) è ricavo → NON rientra qui.
    private func fuoriDalGenerato(_ m: TesMovimento) -> Bool {
        let c = (m.categoria ?? "").lowercased()
        if c.contains("apporto") { return true }
        return m.tipo == "entrata" ? isDeposito(m) : c.contains("deposito")
    }
    private var depositiMov: [TesMovimento] {
        model.movimenti.filter { isDeposito($0) }.sorted { $0.data > $1.data }
    }
    /// Cauzioni ancora in mano: incassate (entrate) meno quelle restituite (uscite).
    private var depositiDaRestituire: Int {
        depositiMov.reduce(0) { $0 + ($1.tipo == "entrata" ? $1.importo_cents : -$1.importo_cents) }
    }
    private var nostroReale: Int { model.totaleConti - depositiDaRestituire }

    private var depositiView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                clic(.totaleConti) { totCard("TOTALE SUI CONTI", model.totaleConti, PSE.accent) }
                clic(.movimenti("Depositi cauzionali", depositiMov, depositiDaRestituire)) { totCard("DEPOSITI CAUZIONALI (da restituire)", depositiDaRestituire, PSE.warn) }
                clic(.nostroReale) { totCard("NOSTRO REALE (netto depositi)", nostroReale, nostroReale < 0 ? PSE.neg : PSE.pos) }
            }
            Text("I depositi cauzionali sono soldi degli inquilini che dovremo restituire: stanno sui conti (per lo più Beeper) ma non sono nostri. «Nostro reale» = totale conti − depositi. Quando restituisci una cauzione, registra un'uscita categoria «deposito»: scende da sola.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)

            if depositiMov.isEmpty {
                EmptyStateCard(icon: "lock.shield", text: "Nessun deposito cauzionale registrato.")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("DATA").frame(width: 62, alignment: .leading)
                        Text("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CASA").frame(width: 96, alignment: .leading)
                        Text("CONTO").frame(width: 120, alignment: .leading)
                        Text("IMPORTO").frame(width: 92, alignment: .trailing)
                    }
                    .font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
                    ForEach(depositiMov) { m in
                        let entrata = m.tipo == "entrata"
                        Button { editing = m; showForm = true } label: {
                            HStack(spacing: 12) {
                                Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim).frame(width: 62, alignment: .leading).monospacedDigit()
                                Text(m.descrizione ?? "Deposito").font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(casaLabel(m.struttura)).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 96, alignment: .leading).lineLimit(1)
                                Text(contoNomeBreve(m.conto_id)).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 120, alignment: .leading).lineLimit(1)
                                Text((entrata ? "+" : "−") + eurc(m.importo_cents))
                                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(entrata ? PSE.warn : PSE.pos)
                                    .frame(width: 92, alignment: .trailing)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider().overlay(PSE.line).padding(.leading, 16)
                    }
                    HStack(spacing: 12) {
                        Text("TOTALE CAUZIONI IN MANO").font(.system(size: 10.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                        Spacer()
                        Text(eurc(depositiDaRestituire)).font(.system(size: 15, weight: .bold)).foregroundStyle(PSE.warn).monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).background(Color.white.opacity(0.04))
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
            }
        }.padding(.bottom, 20)
    }

    private func totCard(_ t: String, _ v: Int, _ c: Color) -> some View { testoCard(t, eurc(v), c) }
    private func testoCard(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(v).font(.system(size: 18, weight: .bold)).foregroundStyle(c).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── Movimenti ──
    private var periodoMenu: some View {
        Menu {
            Button("Tutti i periodi") { periodo = "tutto" }
            Divider()
            ForEach(anniDisponibili, id: \.self) { a in Button("Anno \(a)") { periodo = a } }
            Divider()
            ForEach(mesiDisponibili, id: \.0) { m in Button(m.1) { periodo = m.0 } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 10))
                Text(periodoLabel).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(periodo == "tutto" ? PSE.dim : PSE.ink).padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(periodo == "tutto" ? PSE.line : PSE.accent.opacity(0.7), lineWidth: 1))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
    private var campoCerca: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(PSE.faint)
            TextField("Cerca", text: $cerca)
                .textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(PSE.ink).frame(width: 130)
            if !cerca.isEmpty {
                Button { cerca = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(PSE.faint)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
    }
    private var movimentiList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                clic(.movimenti("Entrate del periodo", visibiliMov.filter { $0.tipo == "entrata" }, movEntrate)) { totCard("ENTRATE", movEntrate, PSE.pos) }
                clic(.movimenti("Uscite del periodo", visibiliMov.filter { $0.tipo == "uscita" }, movUscite)) { totCard("USCITE", movUscite, PSE.neg) }
                clic(.movimenti("Movimenti del periodo", visibiliMov, movEntrate - movUscite)) { totCard("SALDO PERIODO", movEntrate - movUscite, PSE.accent) }
                clic(.daIncassareTotale) { totCard("DA INCASSARE (lordo)", daIncassarePeriodo, PSE.warn) }
            }
            VStack(spacing: 0) {
                if visibiliMov.isEmpty {
                    EmptyStateCard(icon: "tray", text: "Nessun movimento per il filtro scelto.")
                } else {
                    movHeader
                    ForEach(visibiliMov) { m in
                        movRow(m)
                        Divider().overlay(PSE.line).padding(.leading, 16)
                    }
                    movTotaleRow
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
        }
        .padding(.bottom, 20)
    }
    private var movHeader: some View {
        HStack(spacing: 12) {
            Text("DATA").frame(width: 62, alignment: .leading)
            Text("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
            Text("CASA").frame(width: 96, alignment: .leading)
            Text("CONTO").frame(width: 150, alignment: .leading)
            Text("CATEGORIA").frame(width: 100, alignment: .leading)
            Text("MODALITÀ").frame(width: 84, alignment: .leading)
            Text("IMPORTO").frame(width: 92, alignment: .trailing)
            Image(systemName: "paperclip").frame(width: 24, alignment: .trailing)
        }
        .font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    // Riga di chiusura della tabella: entrate, uscite e saldo di ciò che è
    // effettivamente a schermo, filtri compresi.
    private var movTotaleRow: some View {
        let saldo = movEntrate - movUscite
        return HStack(spacing: 12) {
            Text("TOTALE — \(visibiliMov.count) MOVIMENTI")
                .font(.system(size: 10.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
            Spacer()
            Text("+" + eurc(movEntrate)).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.pos).monospacedDigit()
            Text("−" + eurc(movUscite)).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.neg).monospacedDigit()
            Text("=").font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.faint)
            Text(eurc(saldo)).font(.system(size: 15, weight: .bold))
                .foregroundStyle(saldo < 0 ? PSE.neg : PSE.ink).monospacedDigit()
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white.opacity(0.04))
    }
    private func movRow(_ m: TesMovimento) -> some View {
        let entrata = m.tipo == "entrata"
        let contoNome = model.conti.first { $0.id == m.conto_id }?.nome ?? (m.conto_id ?? "—")
        let casa = m.struttura == "via-po" ? "Via Po" : m.struttura == "via-romagna" ? "Via Romagna" : "—"
        return Button { editing = m; showForm = true } label: {
            HStack(spacing: 12) {
                Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim).frame(width: 62, alignment: .leading).monospacedDigit()
                Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(casa).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 96, alignment: .leading).lineLimit(1)
                Text(contoNome).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 150, alignment: .leading).lineLimit(1)
                Text((m.categoria ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(PSE.faint).frame(width: 100, alignment: .leading).lineLimit(1)
                Text((m.modalita ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(PSE.faint).frame(width: 84, alignment: .leading).lineLimit(1)
                Text((entrata ? "+" : "−") + eurc(m.importo_cents))
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(entrata ? PSE.pos : PSE.neg)
                    .frame(width: 92, alignment: .trailing)
                AllegatiPin(n: model.allegatiPerMov[m.id] ?? 0).frame(width: 24, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func servCard(_ t: String, _ v: Int, _ icon: String, _ c: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(c)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                    Text(eurc(v)).font(.system(size: 18, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(PSE.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }

    // card per casa: entrate, spese, utile
    private func casaCard(_ s: Struttura) -> some View {
        let st = casaStats(s)
        let utile = st.inc - st.spese
        return VStack(alignment: .leading, spacing: 12) {
            Text(s.label.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.ink)
            HStack(spacing: 0) {
                miniStat("ENTRATE", st.inc, PSE.pos)
                miniStat("SPESE", st.spese, PSE.neg)
                miniStat("UTILE", utile, utile >= 0 ? PSE.pos : PSE.neg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func miniStat(_ t: String, _ v: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
            Text(eurc(v)).font(.system(size: 15, weight: .bold)).foregroundStyle(c).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // ══ CONTO ECONOMICO ══════════════════════════════════════════════════════
    // Vista temporale + per categoria: la parte che serve al commercialista e
    // per capire l'andamento. Rispetta il filtro casa (movStrut), tutti i mesi.

    private var movStrutFiltrati: [TesMovimento] {
        model.movimenti.filter { (movStrut == nil || $0.struttura == movStrut!.rawValue) && nelPeriodo($0) }
    }
    // (chiave "yyyy-MM", entrate, uscite) per mese, dal più recente
    private var mensili: [(key: String, entrate: Int, uscite: Int)] {
        var map: [String: (e: Int, u: Int)] = [:]
        for m in movStrutFiltrati {
            let k = String(m.data.prefix(7)); var v = map[k] ?? (0, 0)
            if m.tipo == "entrata" { v.e += m.importo_cents } else { v.u += m.importo_cents }
            map[k] = v
        }
        return map.keys.sorted(by: >).map { (key: $0, entrate: map[$0]!.e, uscite: map[$0]!.u) }
    }
    // Entrate che NON sono ricavi da attività: cauzioni (da restituire) e apporti
    // dei soci (capitale). Entrano in cassa ma non fanno margine, come i debiti
    // sul lato uscite.
    private func isEntrataNonRicavo(_ cat: String?) -> Bool {
        isCauzione(cat) || isApporto(cat)
    }
    // Cauzioni e apporti stavano in una casella sola, ma sono due cose diverse:
    // la cauzione è denaro dell'inquilino da restituire, l'apporto è capitale
    // messo da un socio. Sommarle nascondeva quanto deve rientrare e quanto no.
    private func isCauzione(_ cat: String?) -> Bool { (cat ?? "").lowercased().contains("deposito") }
    private func isApporto(_ cat: String?) -> Bool { (cat ?? "").lowercased().contains("apporto") }
    private func perCategoria(_ tipo: String) -> [(cat: String, tot: Int)] {
        var map: [String: Int] = [:]
        for m in movStrutFiltrati where m.tipo == tipo {
            if tipo == "entrata" && isEntrataNonRicavo(m.categoria) { continue }   // fuori dai ricavi
            let c = (m.categoria?.isEmpty == false) ? m.categoria! : "altro"
            map[c, default: 0] += m.importo_cents
        }
        return map.map { (cat: $0.key, tot: $0.value) }.sorted { $0.tot > $1.tot }
    }
    // Debiti e finanziamenti: rimborsi (debito vecchio, mutuo, rata prestito), non
    // costi di gestione. Vanno tenuti fuori dal margine operativo.
    private func isDebito(_ cat: String?) -> Bool {
        let c = (cat ?? "").lowercased()
        return ["debito", "debiti", "prestito", "mutuo", "rata", "finanziam"].contains { c.contains($0) }
    }
    private func perCategoriaUscite(debiti: Bool) -> [(cat: String, tot: Int)] {
        var map: [String: Int] = [:]
        for m in movStrutFiltrati where m.tipo == "uscita" && isDebito(m.categoria) == debiti {
            let c = (m.categoria?.isEmpty == false) ? m.categoria! : "altro"
            map[c, default: 0] += m.importo_cents
        }
        return map.map { (cat: $0.key, tot: $0.value) }.sorted { $0.tot > $1.tot }
    }
    // Ricavi veri: entrate meno cauzioni e apporti soci.
    private var totEntrate: Int { movStrutFiltrati.filter { $0.tipo == "entrata" && !isEntrataNonRicavo($0.categoria) }.reduce(0) { $0 + $1.importo_cents } }
    // Cauzioni + apporti soci: entrate non da attività, tenute fuori dal margine.
    private var totEntrateFinanziarie: Int { movStrutFiltrati.filter { $0.tipo == "entrata" && isEntrataNonRicavo($0.categoria) }.reduce(0) { $0 + $1.importo_cents } }
    private var cauzioniMov: [TesMovimento] { movStrutFiltrati.filter { $0.tipo == "entrata" && isCauzione($0.categoria) }.sorted { $0.data > $1.data } }
    private var apportiMov: [TesMovimento] { movStrutFiltrati.filter { $0.tipo == "entrata" && isApporto($0.categoria) }.sorted { $0.data > $1.data } }
    private var totCauzioni: Int { cauzioniMov.reduce(0) { $0 + $1.importo_cents } }
    private var totApporti: Int { apportiMov.reduce(0) { $0 + $1.importo_cents } }
    private var totUscite: Int { movStrutFiltrati.filter { $0.tipo == "uscita" }.reduce(0) { $0 + $1.importo_cents } }
    private var totCostiOperativi: Int { movStrutFiltrati.filter { $0.tipo == "uscita" && !isDebito($0.categoria) }.reduce(0) { $0 + $1.importo_cents } }
    private var totDebiti: Int { movStrutFiltrati.filter { $0.tipo == "uscita" && isDebito($0.categoria) }.reduce(0) { $0 + $1.importo_cents } }

    private var contoEconomico: some View {
        VStack(alignment: .leading, spacing: 12) {
            let utileOp = totEntrate - totCostiOperativi          // margine di gestione
            let utileNetto = utileOp - totDebiti                  // dopo debiti/finanziamenti
            let margineOp = totEntrate > 0 ? Int((Double(utileOp) / Double(totEntrate) * 100).rounded()) : 0
            // Gestione: entrate vs costi operativi (senza debiti)
            HStack(spacing: 12) {
                clic(.ricavi) { totCard("ENTRATE", totEntrate, PSE.pos) }
                clic(.costiOperativi) { totCard("COSTI OPERATIVI", totCostiOperativi, PSE.neg) }
                totCard("UTILE OPERATIVO", utileOp, utileOp >= 0 ? PSE.pos : PSE.neg)
                testoCard("MARGINE OP.", totEntrate > 0 ? "\(margineOp)%" : "—", PSE.accent)
            }
            // Sotto la gestione: debiti/finanziamenti e utile netto reale
            // Cauzioni e apporti in due caselle distinte: una è debito verso gli
            // inquilini, l'altra è capitale dei soci. Sommate non dicevano niente.
            if totDebiti > 0 || totEntrateFinanziarie > 0 {
                HStack(spacing: 12) {
                    clic(.debiti) { totCard("DEBITI / FINANZIAMENTI", totDebiti, PSE.warn) }
                    clic(.movimenti("Cauzioni ricevute", cauzioniMov, totCauzioni)) {
                        totCard("CAUZIONI (da restituire)", totCauzioni, PSE.warn)
                    }
                    clic(.movimenti("Apporti dei soci", apportiMov, totApporti)) {
                        totCard("APPORTI SOCI (capitale)", totApporti, PSE.accent)
                    }
                    totCard("UTILE NETTO (dopo debiti)", utileNetto, utileNetto >= 0 ? PSE.pos : PSE.neg)
                }
            }

            Text("ANDAMENTO MENSILE").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint).padding(.top, 6)
            if mensili.isEmpty {
                EmptyStateCard(icon: "chart.bar", text: "Nessun movimento registrato.")
            } else {
                let maxAbs = max(1, mensili.map { abs($0.entrate - $0.uscite) }.max() ?? 1)
                VStack(spacing: 0) {
                    mensiliHeader
                    ForEach(Array(mensili.enumerated()), id: \.element.key) { i, r in
                        mensileRow(r, maxAbs: maxAbs)
                        if i < mensili.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
            }

            HStack(alignment: .top, spacing: 12) {
                categoriaCard("COSTI OPERATIVI PER CATEGORIA", perCategoriaUscite(debiti: false), totCostiOperativi, PSE.neg)
                categoriaCard("ENTRATE PER CATEGORIA", perCategoria("entrata"), totEntrate, PSE.pos)
            }
            .padding(.top, 6)

            if totDebiti > 0 {
                categoriaCard("DEBITI E FINANZIAMENTI (rimborsi)", perCategoriaUscite(debiti: true), totDebiti, PSE.warn)
                    .padding(.top, 2)
            }

            Text("Conto economico su base cassa. «Utile operativo» = ricavi − costi di gestione. Restano fuori dal margine: i debiti (Marroni, Muratore, mutuo, rata) sul lato uscite, e cauzioni + apporti soci sul lato entrate (soldi che entrano ma non sono ricavi). Periodo: \(periodoLabel.lowercased()), filtro casa applicato. «Esporta CSV» per il commercialista.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)

            // Sotto la sintesi, il dettaglio riga per riga come nel foglio Excel.
            ForEach(caseDaMostrare, id: \.self) { s in
                dettaglioCasa(s).padding(.top, 16)
            }
        }.padding(.bottom, 20)
    }

    // ══ DETTAGLIO PER CASA — entrate e uscite voce per voce ═══════════════════
    // Riproduce il foglio «VIA PO — ENTRATE E USCITE»: dirette in contante,
    // Booking già incassato con la sua commissione, uscite registrate, e le
    // entrate future ancora da incassare. I numeri escono dagli stessi movimenti
    // del conto economico qui sopra, così i due blocchi non possono discordare.
    private var caseDaMostrare: [Struttura] { movStrut.map { [$0] } ?? Struttura.allCases }

    private func movCasa(_ s: Struttura) -> [TesMovimento] {
        model.movimenti.filter { $0.struttura == s.rawValue && nelPeriodo($0) }
    }
    private func prenDi(_ m: TesMovimento) -> Prenotazione? {
        guard let pid = m.prenotazione_id else { return nil }
        return prenotazioni.first { $0.id == pid }
    }
    /// Entrate in contante: solo quelle passate dalla cassa.
    // Cauzioni e apporti stavano dentro le entrate generate — le cauzioni sul
    // conto Beeper finivano nel blocco «bonifici» — e gonfiavano il totale di
    // soldi che non sono ricavi. Ora escono di qui e hanno le loro sezioni.
    private func diretteContante(_ s: Struttura) -> [TesMovimento] {
        movCasa(s).filter { $0.tipo == "entrata" && $0.conto_id == "cassa" && !isEntrataNonRicavo($0.categoria) }
            .sorted { $0.data < $1.data }
    }
    /// Entrate arrivate in banca (Beeper): affitti bonificati, giroconti.
    /// Stavano mescolate al contante e il blocco diceva «contante» anche per loro.
    private func entrateBonifico(_ s: Struttura) -> [TesMovimento] {
        movCasa(s).filter { $0.tipo == "entrata" && $0.conto_id != "cassa" && $0.conto_id != "massimo"
                            && !isEntrataNonRicavo($0.categoria) }
            .sorted { $0.data < $1.data }
    }
    /// Uscite registrate, senza le commissioni OTA: quelle sono già dedotte nel
    /// blocco Booking (che mostra il netto) e conteggiarle qui le raddoppierebbe.
    private func usciteCasa(_ s: Struttura) -> [TesMovimento] {
        movCasa(s).filter { $0.tipo == "uscita" && !isCommissioneOTA($0) }.sorted { $0.data < $1.data }
    }
    /// Commissione OTA: si riconosce dalla categoria, ma anche dalla descrizione.
    /// Tre commissioni Booking erano state salvate in categoria «airbnb» e così
    /// non venivano dedotte dal netto OTA e comparivano tra i costi di gestione.
    private func isCommissioneOTA(_ m: TesMovimento) -> Bool {
        m.categoria == "commissione" || (m.descrizione ?? "").lowercased().hasPrefix("commissione")
    }
    /// Cauzioni e apporti di questa casa: fuori dal generato, ma vanno mostrati
    /// perché sono soldi che stanno sui conti e che non sono utile.
    private func cauzioniCasa(_ s: Struttura) -> [TesMovimento] {
        movCasa(s).filter { $0.tipo == "entrata" && isCauzione($0.categoria) }.sorted { $0.data < $1.data }
    }
    private func apportiCasa(_ s: Struttura) -> [TesMovimento] {
        movCasa(s).filter { $0.tipo == "entrata" && isApporto($0.categoria) }.sorted { $0.data < $1.data }
    }

    private struct RigaOTA: Identifiable {
        let id: String, periodo: String, ospite: String, canale: String
        let lordo: Int, commissione: Int
        var netto: Int { lordo - commissione }
    }
    /// Il riferimento Booking «#123456» in fondo alla descrizione: è ciò che
    /// lega l'incasso alla sua commissione.
    private func rifBooking(_ s: String?) -> String? {
        guard let t = (s ?? "").split(separator: "#").last, !t.isEmpty, t.allSatisfy({ $0.isNumber }) else { return nil }
        return String(t)
    }
    private func bookingIncassato(_ s: Struttura) -> [RigaOTA] {
        let commissioni = movCasa(s).filter { $0.tipo == "uscita" && isCommissioneOTA($0) }
        return movCasa(s).filter { $0.tipo == "entrata" && $0.conto_id == "massimo" }
            .sorted { $0.data < $1.data }
            .map { m in
                let rif = rifBooking(m.descrizione)
                let c = commissioni.first { rif != nil && rifBooking($0.descrizione) == rif }
                let nome = (m.descrizione ?? "").replacingOccurrences(of: "Booking — ", with: "")
                // Il canale lo dice la prenotazione collegata, non la categoria
                // del movimento: la categoria si sbaglia a scriverla, e infatti
                // tre incassi Booking risultavano Airbnb.
                let canale = prenDi(m)?.source ?? m.categoria ?? "booking"
                return RigaOTA(id: m.id, periodo: tesPrettyStr(m.data), ospite: nome,
                               canale: canale.capitalized,
                               lordo: m.importo_cents, commissione: c?.importo_cents ?? 0)
            }
    }
    /// Prenotazioni confermate non ancora incassate: il lordo è quello che paga
    /// il cliente, il netto quello che arriva dopo la commissione Booking.
    private func daIncassareRighe(_ s: Struttura) -> [RigaOTA] {
        prenFiltrate
            .filter { $0.struttura == s.rawValue && residuoIncassare($0) > 0 }
            .sorted { ($0.checkin ?? "") < ($1.checkin ?? "") }
            .map { b in
                let lordo = residuoIncassare(b)
                let src = b.source ?? "diretto"
                let comm = src == "booking" ? Int((Double(lordo) * 0.165).rounded()) : 0
                return RigaOTA(id: b.id,
                               periodo: "\(tesPrettyStr(b.checkin))–\(tesPrettyStr(b.checkout))",
                               ospite: b.guest_name + (b.camera.map { " (\($0))" } ?? ""),
                               canale: src.capitalized, lordo: lordo, commissione: comm)
            }
    }

    @ViewBuilder private func dettaglioCasa(_ s: Struttura) -> some View {
        let dirette = diretteContante(s)
        let bonifici = entrateBonifico(s)
        let incassato = bookingIncassato(s)
        let uscite = usciteCasa(s)
        let future = daIncassareRighe(s)
        let totDirette = dirette.reduce(0) { $0 + $1.importo_cents }
        let totBonifici = bonifici.reduce(0) { $0 + $1.importo_cents }
        let totIncassatoNetto = incassato.reduce(0) { $0 + $1.netto }
        let totGenerate = totDirette + totBonifici + totIncassatoNetto
        let totUscite = uscite.reduce(0) { $0 + $1.importo_cents }
        let totFutureNetto = future.reduce(0) { $0 + $1.netto }

        VStack(alignment: .leading, spacing: 10) {
            Text("\(s.label.uppercased()) — ENTRATE E USCITE")
                .font(.system(size: 12, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(PSE.accent.opacity(0.18)))

            if !dirette.isEmpty { blocco("ENTRATE GENERATE — DIRETTE (contante)", PSE.pos, totale: totDirette) { direttaTable(dirette, totale: totDirette, titoloTot: "SUBTOTALE DIRETTE (contante)") } }
            if !bonifici.isEmpty { blocco("ENTRATE GENERATE — BONIFICI (banca)", PSE.pos, totale: totBonifici) { direttaTable(bonifici, totale: totBonifici, titoloTot: "SUBTOTALE BONIFICI (banca)") } }
            if !incassato.isEmpty { blocco("OTA — GIÀ INCASSATO (commissioni dedotte)", PSE.pos, totale: totIncassatoNetto) { otaTable(incassato, titoloTot: "SUBTOTALE INCASSATO") } }
            rigaTotale("TOTALE ENTRATE GENERATE (contante + bonifici + OTA netto)", totGenerate, PSE.pos)
            if !uscite.isEmpty { blocco("USCITE (già registrate)", PSE.neg, totale: totUscite) { uscitaTable(uscite, totale: totUscite) } }
            rigaTotale("SALDO GENERATO (entrate − uscite)", totGenerate - totUscite, totGenerate - totUscite >= 0 ? PSE.pos : PSE.neg)
            if !future.isEmpty {
                blocco("ENTRATE FUTURE — DA INCASSARE", PSE.warn, totale: totFutureNetto) { otaTable(future, titoloTot: "TOTALE DA INCASSARE") }
                rigaTotale("TOTALE POTENZIALE (generato + futuro netto)", totGenerate - totUscite + totFutureNetto, PSE.accent)
            }
            // Fuori dal saldo generato, ma sono soldi di questa casa che stanno
            // sui conti: le cauzioni torneranno agli inquilini, gli apporti sono
            // capitale dei soci. Tenerli separati evita di leggerli come utile.
            let cauz = cauzioniCasa(s), app = apportiCasa(s)
            if !cauz.isEmpty || !app.isEmpty {
                Text("FUORI DAL GENERATO — NON SONO RICAVI")
                    .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.dim)
                    .padding(.top, 4)
            }
            if !cauz.isEmpty {
                let t = cauz.reduce(0) { $0 + $1.importo_cents }
                blocco("CAUZIONI RICEVUTE — DA RESTITUIRE", PSE.warn, totale: t) { uscitaTable(cauz, totale: t) }
            }
            if !app.isEmpty {
                let t = app.reduce(0) { $0 + $1.importo_cents }
                blocco("APPORTI DEI SOCI — CAPITALE", PSE.accent, totale: t) { uscitaTable(app, totale: t) }
            }
        }
    }

    /// Blocco del dettaglio per casa: chiuso, col totale già in testata. Il
    /// numero si legge senza aprire; le righe si aprono se servono.
    private func blocco<C: View>(_ titolo: String, _ c: Color, totale: Int? = nil,
                                 @ViewBuilder _ content: @escaping () -> C) -> some View {
        PSEPieghevole(titolo, valore: totale.map { eurc($0) }, colore: c, coloreValore: c, contenuto: content)
    }
    private func rigaTotale(_ t: String, _ v: Int, _ c: Color) -> some View {
        HStack {
            Text(t).font(.system(size: 10.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 12)
            Text(eurc(v)).font(.system(size: 15, weight: .bold)).foregroundStyle(c).monospacedDigit()
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(c.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c.opacity(0.30), lineWidth: 1))
    }
    private func thc(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.7).foregroundStyle(PSE.faint).lineLimit(1)
    }
    private func subtotaleBar(_ t: String, _ v: Int, _ c: Color) -> some View {
        HStack {
            Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 12)
            Text(eurc(v)).font(.system(size: 13, weight: .bold)).foregroundStyle(c).monospacedDigit()
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color.white.opacity(0.04))
    }

    // Dirette: notti e prezzo per notte arrivano dal soggiorno agganciato; dove
    // il movimento non è agganciato a nessuna prenotazione restano vuoti.
    private func direttaTable(_ righe: [TesMovimento], totale: Int, titoloTot: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                thc("DATA").frame(width: 62, alignment: .leading)
                thc("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
                thc("NOTTI").frame(width: 48, alignment: .trailing)
                thc("PREZZO/NOTTE").frame(width: 92, alignment: .trailing)
                thc("TOTALE").frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(righe) { m in
                let p = prenDi(m)
                let n = p.flatMap { nights($0.checkin, $0.checkout) }
                HStack(spacing: 10) {
                    Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
                        .frame(width: 62, alignment: .leading).monospacedDigit()
                    Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12)).foregroundStyle(PSE.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(n.map { "\($0)" } ?? "—").font(.system(size: 11.5)).foregroundStyle(PSE.dim)
                        .frame(width: 48, alignment: .trailing).monospacedDigit()
                    Text(n.flatMap { $0 > 0 ? eurc(m.importo_cents / $0) : nil } ?? "—")
                        .font(.system(size: 11.5)).foregroundStyle(PSE.dim)
                        .frame(width: 92, alignment: .trailing).monospacedDigit()
                    Text(eurc(m.importo_cents)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(PSE.pos)
                        .frame(width: 96, alignment: .trailing).monospacedDigit()
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                Divider().overlay(PSE.line).padding(.leading, 16)
            }
            subtotaleBar(titoloTot, totale, PSE.pos)
        }
    }

    private func otaTable(_ righe: [RigaOTA], titoloTot: String) -> some View {
        let lordo = righe.reduce(0) { $0 + $1.lordo }
        let comm = righe.reduce(0) { $0 + $1.commissione }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                thc("PERIODO").frame(width: 96, alignment: .leading)
                thc("OSPITE").frame(maxWidth: .infinity, alignment: .leading)
                thc("LORDO").frame(width: 88, alignment: .trailing)
                thc("COMMISSIONE").frame(width: 96, alignment: .trailing)
                thc("NETTO").frame(width: 96, alignment: .trailing)
                thc("CANALE").frame(width: 72, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(righe) { r in
                HStack(spacing: 10) {
                    Text(r.periodo).font(.system(size: 11)).foregroundStyle(PSE.dim)
                        .frame(width: 96, alignment: .leading).monospacedDigit().lineLimit(1)
                    Text(r.ospite).font(.system(size: 12)).foregroundStyle(PSE.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(eurc(r.lordo)).font(.system(size: 11.5)).foregroundStyle(PSE.text)
                        .frame(width: 88, alignment: .trailing).monospacedDigit()
                    Text(r.commissione > 0 ? "−" + eurc(r.commissione) : "—")
                        .font(.system(size: 11.5)).foregroundStyle(r.commissione > 0 ? PSE.warn : PSE.faint)
                        .frame(width: 96, alignment: .trailing).monospacedDigit()
                    Text(eurc(r.netto)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(PSE.ink)
                        .frame(width: 96, alignment: .trailing).monospacedDigit()
                    canalePill(r.canale).frame(width: 72, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                Divider().overlay(PSE.line).padding(.leading, 16)
            }
            HStack(spacing: 10) {
                Text(titoloTot).font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                Spacer()
                Text(eurc(lordo)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
                    .frame(width: 88, alignment: .trailing).monospacedDigit()
                Text(comm > 0 ? "−" + eurc(comm) : "—").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.warn)
                    .frame(width: 96, alignment: .trailing).monospacedDigit()
                Text(eurc(lordo - comm)).font(.system(size: 13, weight: .bold)).foregroundStyle(PSE.pos)
                    .frame(width: 96, alignment: .trailing).monospacedDigit()
                Color.clear.frame(width: 72)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color.white.opacity(0.04))
        }
    }
    private func canalePill(_ c: String) -> some View {
        let tint: Color = c.lowercased().contains("airbnb") ? PSE.warn
            : c.lowercased().contains("booking") ? Color(hue: 45/360, saturation: 0.44, brightness: 0.62) : PSE.accent
        return Text(c).font(.system(size: 9, weight: .heavy)).tracking(0.4).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .lineLimit(1)
    }

    private func uscitaTable(_ righe: [TesMovimento], totale: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                thc("DATA").frame(width: 62, alignment: .leading)
                thc("CONCETTO").frame(maxWidth: .infinity, alignment: .leading)
                thc("CATEGORIA").frame(width: 110, alignment: .leading)
                thc("IMPORTO").frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(righe) { m in
                HStack(spacing: 10) {
                    Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
                        .frame(width: 62, alignment: .leading).monospacedDigit()
                    Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12)).foregroundStyle(PSE.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text((m.categoria ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(PSE.faint)
                        .frame(width: 110, alignment: .leading).lineLimit(1)
                    Text(eurc(m.importo_cents)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(PSE.neg)
                        .frame(width: 96, alignment: .trailing).monospacedDigit()
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                Divider().overlay(PSE.line).padding(.leading, 16)
            }
            subtotaleBar("TOTALE USCITE", totale, PSE.neg)
        }
    }

    // ══ CONTI — estratto conto per conto (Cassa · Massimo · Beeper) ═══════════
    // Ogni conto come nel relativo foglio dell'Excel: entrate, uscite, saldo.
    private var tuttiIConti: Bool { contoSel == "tutti" }
    private var contoMovimenti: [TesMovimento] {
        (tuttiIConti ? model.movimenti : model.movimenti.filter { $0.conto_id == contoSel })
            .filter { nelPeriodo($0) && (movStrut == nil || $0.struttura == movStrut!.rawValue) }
            .sorted { $0.data > $1.data }
    }
    /// Saldo del conto (o di tutti) prima dell'inizio del periodo scelto: senza
    /// questo, filtrare per mese farebbe leggere come «saldo» il solo movimento
    /// del mese, che non è il saldo del conto.
    private var saldoIniziale: Int {
        guard periodo != "tutto" else { return 0 }
        var t = 0
        for m in model.movimenti where (tuttiIConti || m.conto_id == contoSel)
            && (movStrut == nil || m.struttura == movStrut!.rawValue) && m.data < periodo {
            // Col filtro casa è un «generato»: cauzioni e apporti restano fuori (come
            // nel corpo dell'estratto). Senza filtro è il saldo vero e devono restare.
            if movStrut != nil && fuoriDalGenerato(m) { continue }
            t += (m.tipo == "entrata") ? m.importo_cents : -m.importo_cents
        }
        return t
    }
    private func contoNomeBreve(_ id: String?) -> String {
        switch id { case "cassa": return "Cassa"; case "massimo": return "Massimo"; case "beeper": return "Beeper"; default: return id ?? "—" }
    }
    private var contiView: some View {
        // Filtrando per casa non si guarda più un saldo ma quanto quella casa ha
        // generato: chiamarlo «saldo» sarebbe falso, il conto non si divide.
        let perCasa = movStrut != nil
        // In vista «generato» (filtro casa) cauzioni da restituire e apporti soci
        // non contano: non sono ricavi né spese (scheda «Depositi»/«Conto economico»).
        // Nel saldo vero del conto (senza filtro casa) invece devono restare, o
        // l'estratto non quadrerebbe col denaro effettivo sul conto.
        let mov = perCasa
            ? contoMovimenti.filter { !fuoriDalGenerato($0) }
            : contoMovimenti
        let entrate = mov.filter { $0.tipo == "entrata" }
        let uscite = mov.filter { $0.tipo == "uscita" }
        let totE = entrate.reduce(0) { $0 + $1.importo_cents }
        let totU = uscite.reduce(0) { $0 + $1.importo_cents }
        let conto = model.conti.first { $0.id == contoSel }
        let iniz = saldoIniziale
        let nome = tuttiIConti ? "TOTALE" : (conto?.nome.uppercased() ?? "")
        return VStack(alignment: .leading, spacing: 12) {
            // intestazione: col periodo filtrato l'estratto parte dal saldo
            // iniziale e chiude sul finale, come un vero estratto conto.
            HStack(spacing: 12) {
                if periodo == "tutto" {
                    testoCard(perCasa ? "GENERATO DA \(movStrut!.label.uppercased())" : "SALDO \(nome)\(perCasa ? "" : " (già entrato)")",
                              eurc(totE - totU), (totE - totU) < 0 ? PSE.neg : PSE.ink)
                    clic(.movimenti("Entrate", entrate, totE)) { totCard("ENTRATE", totE, PSE.pos) }
                    clic(.movimenti("Uscite", uscite, totU)) { totCard("USCITE", totU, PSE.neg) }
                    // Per un singolo conto: quarta card = soldi che devono ancora
                    // arrivare (prenotazioni confermate non incassate su quel conto).
                    // Su «Tutti i conti» o col filtro casa resta il conteggio movimenti.
                    let incConto = (!tuttiIConti && !perCasa) ? daIncassare(contoSel) : 0
                    if incConto > 0 {
                        clic(.daIncassareConto(contoSel)) { totCard("DA INCASSARE (in arrivo)", incConto, PSE.warn) }
                    } else {
                        testoCard("N. MOVIMENTI", "\(mov.count)", PSE.accent)
                    }
                } else {
                    totCard(perCasa ? "GENERATO PRIMA DEL PERIODO" : "SALDO INIZIALE", iniz, iniz < 0 ? PSE.neg : PSE.dim)
                    clic(.movimenti("Entrate", entrate, totE)) { totCard("ENTRATE", totE, PSE.pos) }
                    clic(.movimenti("Uscite", uscite, totU)) { totCard("USCITE", totU, PSE.neg) }
                    testoCard(perCasa ? "GENERATO DA \(movStrut!.label.uppercased())" : "SALDO FINALE \(nome)",
                              eurc(iniz + totE - totU), (iniz + totE - totU) < 0 ? PSE.neg : PSE.ink)
                }
            }
            if perCasa {
                Text("Filtro casa attivo: questi non sono saldi di conto ma quanto \(movStrut!.label) ha generato e speso. Il denaro sui conti è in comune e non si divide per casa — i saldi veri si vedono togliendo il filtro.")
                    .font(.system(size: 10.5)).foregroundStyle(PSE.warn)
            }
            // Con «Tutti i conti»: una card di saldo per ciascun conto (saldo pieno,
            // non del periodo: è quello che c'è davvero sul conto oggi)
            if tuttiIConti && !perCasa {
                HStack(spacing: 12) {
                    ForEach(model.conti) { c in
                        let s = model.saldo(c.id)
                        clic(.conto(c.id)) { totCard("\(c.nome.uppercased()) — SALDO OGGI", s, s < 0 ? PSE.neg : PSE.accent) }
                    }
                }
            }
            if tuttiIConti && !perCasa { ripartizionePerCasa }
            if mov.isEmpty {
                EmptyStateCard(icon: "tray", text: periodo == "tutto" ? "Nessun movimento." : "Nessun movimento in \(periodoLabel.lowercased()).")
            } else {
                contoLedger("ENTRATE", entrate, totE, PSE.pos, "+", showConto: tuttiIConti)
                contoLedger("USCITE", uscite, totU, PSE.neg, "−", showConto: tuttiIConti)
                // Riga finale: saldo iniziale + entrate − uscite = saldo finale
                rimanenteRow(iniz, totE, totU)
            }
            Text(contoNota).font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)

            // Per il conto OTA, sotto l'estratto, il dettaglio Booking/Airbnb:
            // già incassato, da incassare mese per mese, e il totale del conto.
            if let conto, conto.tipo == "ota" {
                dettaglioContoOTA(conto).padding(.top, 16)
            }
        }.padding(.bottom, 20)
    }

    // ══ CONTO OTA — Booking già incassato + da incassare ══════════════════════
    // Come il foglio «CONTO MASSIMO AFFITTACAMERE · BOOKING + AIRBNB»: quello che
    // Booking ha già pagato (checkout passato), quello che arriverà diviso per
    // mese, Airbnb a parte perché non ha commissione, e il totale del conto.
    private func otaIncassato(_ contoId: String) -> [RigaOTA] {
        let mov = model.movimenti.filter {
            $0.conto_id == contoId && nelPeriodo($0)
                && (movStrut == nil || $0.struttura == movStrut!.rawValue)
        }
        let commissioni = mov.filter { $0.tipo == "uscita" && $0.categoria == "commissione" }
        return mov.filter { $0.tipo == "entrata" }.sorted { $0.data < $1.data }.map { m in
            let rif = rifBooking(m.descrizione)
            let c = commissioni.first { rif != nil && rifBooking($0.descrizione) == rif }
            return RigaOTA(id: m.id, periodo: tesPrettyStr(m.data),
                           ospite: (m.descrizione ?? "").replacingOccurrences(of: "Booking — ", with: ""),
                           canale: (m.categoria ?? "booking").capitalized,
                           lordo: m.importo_cents, commissione: c?.importo_cents ?? 0)
        }
    }
    /// Prenotazioni i cui soldi finiranno su questo conto e non sono ancora arrivati.
    private func otaDaIncassare(_ contoId: String, fonti: [String]) -> [RigaOTA] {
        prenFiltrate
            .filter { contoDest($0) == contoId && fonti.contains($0.source ?? "")
                      && (movStrut == nil || $0.struttura == movStrut!.rawValue)
                      && residuoIncassare($0) > 0 }
            .sorted { ($0.checkin ?? "") < ($1.checkin ?? "") }
            .map { b in
                let lordo = residuoIncassare(b)
                let comm = (b.source ?? "") == "booking" ? Int((Double(lordo) * 0.165).rounded()) : 0
                return RigaOTA(id: b.id,
                               periodo: "\(tesPrettyStr(b.checkin))–\(tesPrettyStr(b.checkout))",
                               ospite: b.guest_name + (b.camera.map { " (\($0))" } ?? ""),
                               canale: (b.source ?? "—").capitalized, lordo: lordo, commissione: comm)
            }
    }
    /// Il da-incassare Booking spezzato per mese di check-in, come nel foglio.
    private func bookingPerMese(_ contoId: String) -> [(mese: String, righe: [RigaOTA])] {
        var map: [String: [RigaOTA]] = [:]
        for b in prenFiltrate where contoDest(b) == contoId && (b.source ?? "") == "booking"
                                    && (movStrut == nil || b.struttura == movStrut!.rawValue)
                                    && residuoIncassare(b) > 0 {
            let k = String((b.checkin ?? "").prefix(7))
            let lordo = residuoIncassare(b)
            map[k, default: []].append(RigaOTA(
                id: b.id, periodo: "\(tesPrettyStr(b.checkin))–\(tesPrettyStr(b.checkout))",
                ospite: b.guest_name + (b.camera.map { " (\($0))" } ?? ""),
                canale: "Booking", lordo: lordo, commissione: Int((Double(lordo) * 0.165).rounded())))
        }
        return map.keys.sorted().map { (mese: $0, righe: map[$0]!.sorted { $0.periodo < $1.periodo }) }
    }

    @ViewBuilder private func dettaglioContoOTA(_ conto: Conto) -> some View {
        let incassato = otaIncassato(conto.id)
        let perMese = bookingPerMese(conto.id)
        let airbnb = otaDaIncassare(conto.id, fonti: ["airbnb"])
        let nettoIncassato = incassato.reduce(0) { $0 + $1.netto }
        let nettoBooking = perMese.flatMap(\.righe).reduce(0) { $0 + $1.netto }
        let lordoBooking = perMese.flatMap(\.righe).reduce(0) { $0 + $1.lordo }
        let commBooking = perMese.flatMap(\.righe).reduce(0) { $0 + $1.commissione }
        let nettoAirbnb = airbnb.reduce(0) { $0 + $1.netto }

        VStack(alignment: .leading, spacing: 10) {
            Text("\(conto.nome.uppercased()) · BOOKING + AIRBNB")
                .font(.system(size: 12, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(PSE.accent.opacity(0.18)))

            // Combinazione impossibile per come sono fatte le cose: questo è il
            // conto delle OTA, e le OTA le ha solo Via Po. Meglio dirlo che
            // mostrare tre tabelle vuote.
            if incassato.isEmpty && perMese.isEmpty && airbnb.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nessun movimento OTA per \(movStrut?.label ?? "il filtro scelto")")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink)
                    Text(movStrut == .viaRomagna
                         ? "Su questo conto arrivano solo i soldi delle OTA, che sono di Via Po: Booking e Airbnb lavorano solo lì. Gli incassi di Via Romagna sono in contante (Cassa) o per bonifico (Beeper)."
                         : "Per il periodo e la casa selezionati non risulta nessun incasso da Booking o Airbnb.")
                        .font(.system(size: 11)).foregroundStyle(PSE.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(PSE.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
            }

            if !incassato.isEmpty {
                blocco("BOOKING — GIÀ INCASSATO (checkout passato, Booking ha pagato)", PSE.pos) {
                    otaTable(incassato, titoloTot: "SUBTOTALE INCASSATO")
                }
            }
            ForEach(perMese, id: \.mese) { g in
                blocco("BOOKING — DA INCASSARE · \(meseNome(g.mese).uppercased())", PSE.warn) {
                    otaTable(g.righe, titoloTot: "SUBTOTALE \(meseNome(g.mese).uppercased())")
                }
            }
            if perMese.count > 1 {
                rigaTotale("TOTALE BOOKING DA INCASSARE — lordo \(eurc(lordoBooking)), commissioni \(eurc(commBooking))",
                           nettoBooking, PSE.warn)
            }
            if !airbnb.isEmpty {
                blocco("AIRBNB — DA INCASSARE (nessuna commissione)", PSE.warn) {
                    otaTable(airbnb, titoloTot: "TOTALE AIRBNB")
                }
            }
            rigaTotale("TOTALE \(conto.nome.uppercased()) (incassato + da incassare + Airbnb, netto)",
                       nettoIncassato + nettoBooking + nettoAirbnb, PSE.accent)
            Text("Commissioni Booking 16,5% sul da incassare (stima); su quanto già incassato è la commissione reale registrata come uscita. Airbnb non ha commissione. Il saldo del conto qui sopra è solo l'incassato: \(eurc(nettoIncassato)).")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }
    // ── Ripartizione per casa ────────────────────────────────────────────────
    // Risponde a «da dove vengono e dove si spendono i soldi»: quanto ha
    // generato ciascuna casa e su quale conto è finito. Il denaro poi sta tutto
    // insieme sui conti — questa è un'attribuzione, non una divisione.
    private struct RigaCasa: Identifiable {
        let id: String, nome: String
        let entrate: Int, uscite: Int
        let perConto: [String: Int]      // conto_id → netto
        var netto: Int { entrate - uscite }
    }
    private func rigaCasa(_ nome: String, _ filtro: (TesMovimento) -> Bool) -> RigaCasa {
        let mov = model.movimenti.filter { nelPeriodo($0) && filtro($0) }
        var perConto: [String: Int] = [:]
        var e = 0, u = 0
        for m in mov {
            let segno = m.tipo == "entrata" ? m.importo_cents : -m.importo_cents
            perConto[m.conto_id ?? "—", default: 0] += segno
            if m.tipo == "entrata" { e += m.importo_cents } else { u += m.importo_cents }
        }
        return RigaCasa(id: nome, nome: nome, entrate: e, uscite: u, perConto: perConto)
    }
    private var righeCase: [RigaCasa] {
        Struttura.allCases.map { s in rigaCasa(s.label) { $0.struttura == s.rawValue } }
        + [rigaCasa("Non attribuito") { $0.struttura == nil || ($0.struttura ?? "").isEmpty }]
    }
    private var ripartizionePerCasa: some View {
        let righe = righeCase
        let tot = rigaCasa("TOTALE") { _ in true }
        return VStack(alignment: .leading, spacing: 0) {
            Text("DA DOVE VENGONO E DOVE SI SPENDONO — RIPARTIZIONE PER CASA")
                .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 10) {
                thc("CASA").frame(width: 130, alignment: .leading)
                thc("ENTRATE").frame(maxWidth: .infinity, alignment: .trailing)
                thc("USCITE").frame(maxWidth: .infinity, alignment: .trailing)
                thc("NETTO").frame(maxWidth: .infinity, alignment: .trailing)
                ForEach(model.conti) { c in
                    thc(c.nome.uppercased()).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(righe) { r in
                casaRow(r, grassetto: false)
                Divider().overlay(PSE.line).padding(.leading, 16)
            }
            casaRow(tot, grassetto: true)
            if !movNonAttribuiti.isEmpty { spiegazioneNonAttribuito }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    // ── «Non attribuito», detto per nome ─────────────────────────────────────
    // Prima c'era una frase generica che elencava categorie a memoria, e per
    // sapere davvero cos'erano quei soldi bisognava andarli a cercare nei
    // movimenti. Adesso la spiegazione la scrive il dato: riga per riga, con
    // data e importo, e si apre cliccando.
    private var movNonAttribuiti: [TesMovimento] {
        model.movimenti.filter { nelPeriodo($0) && ($0.struttura ?? "").isEmpty }
            .sorted { $0.data > $1.data }
    }
    private var spiegazioneNonAttribuito: some View {
        let entrate = movNonAttribuiti.filter { $0.tipo == "entrata" }
        let uscite = movNonAttribuiti.filter { $0.tipo == "uscita" }
        let totE = entrate.reduce(0) { $0 + $1.importo_cents }
        let totU = uscite.reduce(0) { $0 + $1.importo_cents }
        return VStack(alignment: .leading, spacing: 0) {
            PSEPieghevole("NON ATTRIBUITO — CHE COSA SONO",
                          valore: "+\(eurc(totE)) · −\(eurc(totU))", colore: PSE.warn, coloreValore: PSE.warn,
                          nota: "\(movNonAttribuiti.count) movimenti senza casa") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(movNonAttribuiti) { m in
                        Button { editing = m; showForm = true } label: {
                            HStack(spacing: 12) {
                                Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(PSE.dim).frame(width: 58, alignment: .leading).monospacedDigit()
                                Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(PSE.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text((m.categoria ?? "—").capitalized).font(.system(size: 11))
                                    .foregroundStyle(PSE.faint).frame(width: 100, alignment: .leading).lineLimit(1)
                                Text(contoNomeBreve(m.conto_id)).font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(PSE.accent).frame(width: 76, alignment: .leading).lineLimit(1)
                                Text((m.tipo == "entrata" ? "+" : "−") + eurc(m.importo_cents))
                                    .font(.system(size: 12.5, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(m.tipo == "entrata" ? PSE.pos : PSE.neg)
                                    .frame(width: 92, alignment: .trailing)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider().overlay(PSE.line).padding(.leading, 16)
                    }
                    Text("Sono i movimenti che non appartengono a una casa sola: il resto del denaro dell'asta, la rata del prestito, le spese di banca. Non è un errore — ma finché stanno qui non entrano nel conto di Via Po né in quello di Via Romagna. Clicca una riga per assegnarle una casa, se ce n'è una.")
                        .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 12)
        }
    }

    private func casaRow(_ r: RigaCasa, grassetto: Bool) -> some View {
        HStack(spacing: 10) {
            Text(r.nome).font(.system(size: grassetto ? 11 : 12, weight: grassetto ? .heavy : .semibold))
                .foregroundStyle(r.nome == "Non attribuito" ? PSE.warn : PSE.ink)
                .frame(width: 130, alignment: .leading).lineLimit(1)
            Text("+" + eurc(r.entrate)).font(.system(size: 11.5, weight: grassetto ? .bold : .regular))
                .foregroundStyle(PSE.pos).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            Text("−" + eurc(r.uscite)).font(.system(size: 11.5, weight: grassetto ? .bold : .regular))
                .foregroundStyle(PSE.neg).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            Text(eurc(r.netto)).font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(r.netto < 0 ? PSE.neg : PSE.ink).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            ForEach(model.conti) { c in
                let v = r.perConto[c.id] ?? 0
                Text(v == 0 ? "—" : eurc(v)).font(.system(size: 11.5, weight: grassetto ? .bold : .regular))
                    .foregroundStyle(v == 0 ? PSE.faint : (v < 0 ? PSE.neg : PSE.dim)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, grassetto ? 11 : 8)
        .background(grassetto ? Color.white.opacity(0.04) : .clear)
    }

    private var contoNota: String {
        switch contoSel {
        case "tutti": return "Tutti i conti insieme: Cassa (contante, entrambe le case) + Massimo (le OTA di Via Po) + Beeper (bonifici). La colonna «Conto» indica dove è transitato il denaro."
        case "massimo": return "Conto delle OTA di Via Po: qui arrivano Booking e Airbnb, e solo di quella casa. Booking entra al lordo con la commissione (16,5%) come uscita, quindi il saldo è il netto; Airbnb non ha commissione. Via Romagna non passa da qui: incassa in contante o per bonifico. Le prenotazioni future sono in «da incassare»."
        case "beeper": return "Estratto conto bonifici, entrambe le case: affitti bonificati, depositi degli inquilini (da restituire) e uscite (rata prestito, muratore, Marroni, spese banca)."
        default: return "Contante Via Po + Via Romagna: affitti in entrata; pulizia, colazioni, chiavi e idraulico in uscita."
        }
    }
    private func contoLedger(_ title: String, _ items: [TesMovimento], _ tot: Int, _ c: Color, _ sign: String, showConto: Bool = false) -> some View {
        PSEPieghevole(title, valore: sign + eurc(tot), coloreValore: c,
                      nota: "\(items.count) movimenti") {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                Button { editing = m; showForm = true } label: {
                    HStack(spacing: 12) {
                        Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim).frame(width: 58, alignment: .leading).monospacedDigit()
                        Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if showConto {
                            Text(contoNomeBreve(m.conto_id)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PSE.accent).frame(width: 76, alignment: .leading).lineLimit(1)
                        }
                        Text(casaLabel(m.struttura)).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 96, alignment: .leading).lineLimit(1)
                        Text((m.categoria ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(PSE.faint).frame(width: 100, alignment: .leading).lineLimit(1)
                        Text(sign + eurc(m.importo_cents)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(c).monospacedDigit().frame(width: 92, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if i < items.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
            }
        }
    }
    private func casaLabel(_ s: String?) -> String {
        s == "via-po" ? "Via Po" : s == "via-romagna" ? "Via Romagna" : "—"
    }
    // Riga di chiusura: saldo iniziale + entrate − uscite = saldo finale
    private func rimanenteRow(_ iniz: Int, _ totE: Int, _ totU: Int) -> some View {
        let saldo = iniz + totE - totU
        return HStack(spacing: 16) {
            Text(periodo == "tutto" ? "TOTALE RIMANENTE" : "SALDO FINALE").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
            Spacer()
            if periodo != "tutto" {
                Text(eurc(iniz)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim).monospacedDigit()
                    .help("Saldo prima dell'inizio del periodo")
            }
            Text("+\(eurc(totE))").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.pos).monospacedDigit()
            Text("−\(eurc(totU))").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.neg).monospacedDigit()
            Text("=").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.faint)
            Text(eurc(saldo)).font(.system(size: 16, weight: .bold)).foregroundStyle(saldo < 0 ? PSE.neg : PSE.ink).monospacedDigit()
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    private var mensiliHeader: some View {
        HStack(spacing: 12) {
            Text("MESE").frame(width: 130, alignment: .leading)
            Text("ENTRATE").frame(width: 90, alignment: .trailing)
            Text("USCITE").frame(width: 90, alignment: .trailing)
            Text("UTILE").frame(width: 90, alignment: .trailing)
            Text("").frame(maxWidth: .infinity)
        }
        .font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    private func mensileRow(_ r: (key: String, entrate: Int, uscite: Int), maxAbs: Int) -> some View {
        let utile = r.entrate - r.uscite
        let frac = min(1, Double(abs(utile)) / Double(maxAbs))
        return HStack(spacing: 12) {
            Text(meseNome(r.key)).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink)
                .frame(width: 130, alignment: .leading).lineLimit(1)
            Text("+" + eurc(r.entrate)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(PSE.pos).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text("−" + eurc(r.uscite)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(PSE.neg).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(eurc(utile)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(utile >= 0 ? PSE.pos : PSE.neg).monospacedDigit().frame(width: 90, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(PSE.surface).frame(height: 8)
                    RoundedRectangle(cornerRadius: 3).fill((utile >= 0 ? PSE.pos : PSE.neg).opacity(0.75))
                        .frame(width: max(2, geo.size.width * frac), height: 8)
                }.frame(maxHeight: .infinity, alignment: .center)
            }.frame(height: 18)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func categoriaCard(_ title: String, _ rows: [(cat: String, tot: Int)], _ tot: Int, _ c: Color) -> some View {
        let maxTot = max(1, rows.first?.tot ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
            if rows.isEmpty {
                Text("Nessuna voce").font(.system(size: 11)).foregroundStyle(PSE.dim).padding(.vertical, 8)
            } else {
                ForEach(rows, id: \.cat) { r in
                    let pct = tot > 0 ? Int((Double(r.tot) / Double(tot) * 100).rounded()) : 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(r.cat.capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(eurc(r.tot)).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                            Text("\(pct)%").font(.system(size: 10, weight: .semibold)).foregroundStyle(PSE.faint).frame(width: 34, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(PSE.surface).frame(height: 6)
                                RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * Double(r.tot) / Double(maxTot)), height: 6)
                            }
                        }.frame(height: 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── Export CSV per il commercialista (separatore ; per Excel IT) ──
    private var exportButton: some View {
        Button { exportCSV() } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .bold))
                Text("Esporta CSV").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(PSE.dim).padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
        }.buttonStyle(.plain).help("Esporta i movimenti visibili in CSV")
    }
    private func exportCSV() {
        // Movimenti → set filtrato visibile; Conti → estratto del conto; altro → tutti (filtro casa)
        let rows: [TesMovimento]
        switch sub {
        case .movimenti: rows = visibiliMov
        case .conti: rows = contoMovimenti
        default: rows = movStrutFiltrati.sorted { $0.data > $1.data }
        }
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "\u{FEFF}Data;Tipo;Struttura;Categoria;Descrizione;Conto;Modalità;Importo\n"
        for m in rows {
            let conto = model.conti.first { $0.id == m.conto_id }?.nome ?? (m.conto_id ?? "")
            let casa = m.struttura == "via-po" ? "Via Po" : m.struttura == "via-romagna" ? "Via Romagna" : ""
            let imp = String(format: "%.2f", Double(m.importo_cents) / 100).replacingOccurrences(of: ".", with: ",")
            csv += [m.data, m.tipo, casa, m.categoria ?? "", m.descrizione ?? "", conto, m.modalita ?? "", imp]
                .map { q($0) }.joined(separator: ";") + "\n"
        }
        // nome file parlante: sezione + casa + periodo, così i CSV per il
        // commercialista non finiscono tutti con lo stesso nome
        var parti = ["camere-pse", sub == .conti ? "conti-\(contoSel)" : sub == .contoEconomico ? "conto-economico" : "movimenti"]
        if let s = movStrut { parti.append(s.rawValue) }
        if periodo != "tutto" { parti.append(periodo) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = parti.joined(separator: "_") + ".csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.data(using: .utf8)?.write(to: url)
        }
    }
}

// ── Form nuovo/modifica movimento ──
private struct TesMovimentoForm: View {
    let conti: [Conto]
    let existing: TesMovimento?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    // Su un movimento nuovo l'id non c'è ancora: i file scelti restano in attesa
    // nello store e salgono subito dopo l'INSERT (vedi save()).
    @StateObject private var allegati: AllegatiStore

    init(conti: [Conto], existing: TesMovimento?, onSaved: @escaping () async -> Void) {
        self.conti = conti; self.existing = existing; self.onSaved = onSaved
        _allegati = StateObject(wrappedValue: AllegatiStore(entita: .movimento, entitaId: existing?.id))
    }

    @State private var data = Date()
    @State private var contoId = "cassa"
    @State private var tipo = "uscita"
    @State private var categoria = ""
    @State private var descrizione = ""
    @State private var importo = ""
    @State private var modalita = "contante"
    @State private var struttura = "—"
    @State private var camera = "—"
    @State private var saving = false
    @State private var confermaElimina = false

    private let modalitaOpts = ["contante", "booking", "airbnb", "bonifico"]
    // Le camere della struttura scelta, per il selettore (niente se «Entrambe»).
    private var camereOpts: [(String, String)] {
        guard struttura == "via-po" || struttura == "via-romagna" else { return [("—", "—")] }
        let rooms = Struttura.from(struttura).rooms.filter { !$0.lowercased().contains("inter") }
        return [("—", "Nessuna camera")] + rooms.map { ($0, $0) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "NUOVO MOVIMENTO" : "MODIFICA MOVIMENTO")
                    .font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HStack(spacing: 12) {
                    pick("Tipo", [("entrata", "Entrata"), ("uscita", "Uscita")], tipo) { tipo = $0 }
                    pick("Conto", conti.map { ($0.id, $0.nome) }, contoId) { contoId = $0 }
                }
                HStack(spacing: 12) {
                    dateField("Data", $data)
                    HoloField(label: "Importo €", text: $importo, placeholder: "120").frame(width: 150)
                }
                HStack(spacing: 12) {
                    pick("Modalità", modalitaOpts.map { ($0, $0.capitalized) }, modalita) { modalita = $0 }
                    // cambiando struttura la camera scelta non vale più
                    pick("Struttura", [("—", "Entrambe"), ("via-po", "Via Po"), ("via-romagna", "Via Romagna")], struttura) { struttura = $0; camera = "—" }
                }
                // Selettore camera: compare quando è scelta una struttura
                if struttura == "via-po" || struttura == "via-romagna" {
                    pick("Camera", camereOpts, camera) { camera = $0 }
                }
                HoloField(label: "Categoria", text: $categoria, placeholder: "affitto, spesa, pulizia…")
                HoloField(label: "Nome e cognome", text: $descrizione, placeholder: "Es. Mario Rossi")

                AllegatiBox(store: allegati)

                HStack(spacing: 10) {
                    if existing != nil {
                        Button { confermaElimina = true } label: {
                            Text("Elimina").font(.system(size: 13)).foregroundStyle(Color(hex: 0xffb3ad))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }.buttonStyle(.plain)
                        .confirmationDialog("Eliminare questo movimento?", isPresented: $confermaElimina) {
                            Button("Elimina movimento", role: .destructive) { Task { await del() } }
                            Button("Annulla", role: .cancel) {}
                        } message: {
                            Text("\(existing?.descrizione ?? existing?.categoria ?? "Movimento") · \(eurc(existing?.importo_cents ?? 0)). L'operazione non si può annullare.")
                        }
                    }
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : "Salva movimento").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain).disabled(saving || cents == nil)
                    .opacity(cents == nil ? 0.5 : 1)
                }.padding(.top, 4)
            }
            .padding(24)
        }
        .frame(width: 520, height: 660)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .onAppear(perform: fill)
    }

    private func dateField(_ label: String, _ date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
            DatePicker("", selection: date, displayedComponents: .date).labelsHidden().datePickerStyle(.compact).colorScheme(.dark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func pick(_ label: String, _ opts: [(String, String)], _ sel: String, _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
            Menu {
                ForEach(opts, id: \.0) { o in Button(o.1) { set(o.0) } }
            } label: {
                HStack(spacing: 8) {
                    Text(opts.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 13)).foregroundStyle(Color(hex: 0xe8f2ff)).lineLimit(1)
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

    private var cents: Int? {
        let s = importo.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(s), v > 0 else { return nil }
        return Int((v * 100).rounded())
    }
    private func fill() {
        guard let m = existing else { return }
        data = tesDate(m.data) ?? Date()
        contoId = m.conto_id ?? "cassa"; tipo = m.tipo
        categoria = m.categoria ?? ""
        importo = String(format: "%.2f", Double(m.importo_cents) / 100)
        modalita = m.modalita ?? "contante"; struttura = m.struttura ?? "—"
        // Se la descrizione è «camera — nome» e la camera è reale, riempi i due
        // campi separati; altrimenti tutta la descrizione va in «nome e cognome».
        let desc = m.descrizione ?? ""
        let rooms = (struttura == "via-po" || struttura == "via-romagna")
            ? Struttura.from(struttura).rooms.filter { !$0.lowercased().contains("inter") } : []
        if let sep = desc.range(of: " — "), rooms.contains(String(desc[..<sep.lowerBound])) {
            camera = String(desc[..<sep.lowerBound]); descrizione = String(desc[sep.upperBound...])
        } else {
            camera = "—"; descrizione = desc
        }
    }
    // La descrizione salvata unisce camera e nome: «Stanza 1 · Queen — Mario Rossi».
    private func descrizioneFinale() -> String? {
        let nome = descrizione.trimmingCharacters(in: .whitespaces)
        let cam = camera == "—" ? "" : camera
        if !cam.isEmpty && !nome.isEmpty { return "\(cam) — \(nome)" }
        if !cam.isEmpty { return cam }
        return nome.isEmpty ? nil : nome
    }
    private func fields() -> [String: Any?] {
        [ "data": tesYmd.string(from: data), "conto_id": contoId, "tipo": tipo,
          "categoria": categoria.isEmpty ? nil : categoria, "descrizione": descrizioneFinale(),
          "importo_cents": cents ?? 0, "modalita": modalita, "struttura": struttura == "—" ? nil : struttura ]
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            if let m = existing {
                try await HubAPI.updateTesMovimento(id: m.id, fields: fields())
            } else {
                // Solo adesso il movimento ha un id: i file scelti prima si
                // attaccano qui, altrimenti resterebbero dei file senza riga.
                let creato = try await HubAPI.createTesMovimento(fields())
                await allegati.salvaInAttesa(su: creato.id)
            }
            await onSaved(); dismiss()
        } catch {}
    }
    private func del() async {
        guard let m = existing else { return }
        do {
            // Prima gli allegati: cancellato il movimento, le sue fatture non
            // avrebbero più un modo per essere ritrovate né cancellate.
            await HubAPI.deleteAllegatiDi(.movimento, id: m.id)
            try await HubAPI.deleteTesMovimento(id: m.id); await onSaved(); dismiss()
        } catch {}
    }
}
