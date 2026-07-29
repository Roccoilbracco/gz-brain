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
    /// Bollette: le utenze del riepilogo si leggono da qui, come nella scheda
    /// Servizi, così i due numeri non possono divergere.
    @Published var bollette: [Bolletta] = []
    /// Quanti allegati ha ciascun movimento, per mostrare la graffetta in
    /// tabella: una sola query per tutti, non una per riga.
    @Published var allegatiPerMov: [String: Int] = [:]
    @Published var loading = true
    /// - Parameter silenzioso: ricarico automatico dopo una modifica altrove —
    ///   niente rotella, la pagina non deve sparire mentre la si guarda.
    func load(silenzioso: Bool = false) async {
        if !silenzioso { loading = true }
        defer { if !silenzioso { loading = false } }
        conti = (try? await HubAPI.listConti()) ?? []
        movimenti = (try? await HubAPI.listMovimenti()) ?? []
        pulizie = (try? await HubAPI.listPulizie()) ?? []
        colazioni = (try? await HubAPI.listColazioni()) ?? []
        educampRighe = (try? await HubAPI.listEducampRighe()) ?? []
        bollette = (try? await HubAPI.listBollette()) ?? []
        allegatiPerMov = (try? await HubAPI.contaAllegati(.movimento)) ?? [:]
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
// Le due schede in coda sono lo storico contabile chiuso (vedi StoricoView):
// stagioni finite, tabelle `storico_*` tutte loro. Non entrano in
// nessun saldo, in nessun «da incassare» e in nessun conto di questa pagina:
// stanno qui solo perché è qui che uno le va a cercare. Per questo sono in un
// gruppo staccato nella barra, sotto l'etichetta ARCHIVIO.
enum TesSub: String, CaseIterable, Identifiable {
    case riepilogo = "Riepilogo", conti = "Conti", contoEconomico = "Conto economico", servizi = "Servizi", movimenti = "Movimenti", depositi = "Depositi", educamp = "Educamp"
    case storico2425 = "Apr 2024 – Set 2025", storico2526 = "Ott 2025 – Giu 2026"
    case storicoTutto = "Riassunto"
    var id: String { rawValue }
    /// La gestione viva: quello che si muove ogni giorno.
    static let correnti: [TesSub] = [.riepilogo, .conti, .contoEconomico, .servizi, .movimenti, .depositi, .educamp]
    /// L'archivio: contabilità chiusa, che non si tocca più.
    static let archivio: [TesSub] = [.storico2425, .storico2526, .storicoTutto]
    var isArchivio: Bool { TesSub.archivio.contains(self) }
}

// ── Sotto-finestre di dettaglio del Riepilogo ────────────────────────────────
// Riga generica: un movimento, una prenotazione o una voce di riepilogo.
struct DettaglioRiga: Identifiable {
    let id: String
    var data: String = ""
    /// La stessa data in `yyyy-MM-dd`. `data` è già scritta come si legge
    /// (`dd/MM/yy`) e ordinarci sopra mette il 1º ottobre 2024 dopo il 1º
    /// settembre 2025: per mettere in fila le righe si usa questa.
    var ymd: String = ""
    let descrizione: String
    var extra: String = ""      // casa · conto · canale
    /// Casa da sola, quando la si conosce: serve a spaccare i totali per
    /// struttura senza dover leggere dentro `extra`.
    var casa: String = ""
    /// Chi ha tirato fuori i soldi: il conto della società, un socio, i
    /// contanti. Serve a dire, fornitore per fornitore, chi ha pagato cosa.
    var pagatoDa: String = ""
    /// Di che spesa si tratta — pulizie, colazioni, mutuo, utenze. Nelle
    /// finestre dell'archivio le righe si raccolgono sotto la loro voce:
    /// centoventi pulizie da 10 € una sotto l'altra non si leggono.
    var voce: String = ""
    let importo: Int
    var positivo: Bool = true
    var mostraSegno: Bool = true
}

// ══ Le tabelle si dividono per casa ══════════════════════════════════════════
//
// Quando un elenco mette insieme Via Po e Via Romagna, la casa è una colonna
// come le altre: si legge riga per riga e il lavoro lo fa l'occhio. Diviso per
// casa, col totale in testa al gruppo, risponde da solo alla domanda che uno si
// fa davanti a una lista mista — «di questo, quanto è di Via Po?».
//
// Con una casa sola non si divide: un'intestazione «Via Po» sopra una lista
// tutta di Via Po è rumore. Vale anche col filtro casa attivo, dove la casa è
// una per costruzione — così le stesse tabelle si dividono o restano piatte da
// sé, senza che nessuno debba ricordarsi di accendere niente.

/// L'ordine è questo, non quello che capita dai dati: Via Po, Via Romagna, e in
/// fondo ciò che non appartiene a una casa (spese comuni, giroconti).
private let CASE_IN_ORDINE = ["Via Po", "Via Romagna"]
private let CASA_SENZA = "Non attribuito"

/// Le righe raccolte per casa, oppure `nil` quando la casa è una sola: in quel
/// caso chi chiama lascia la tabella com'era. L'ordine dentro ogni gruppo non si
/// tocca — arriva già ordinato per data da chi costruisce l'elenco.
private func gruppiPerCasa<T>(_ righe: [T], casa: (T) -> String) -> [(casa: String, righe: [T])]? {
    var mappa: [String: [T]] = [:]
    for r in righe {
        let c = casa(r)
        mappa[c.isEmpty || c == "—" ? CASA_SENZA : c, default: []].append(r)
    }
    guard mappa.count > 1 else { return nil }
    let peso: (String) -> Int = { CASE_IN_ORDINE.firstIndex(of: $0) ?? CASE_IN_ORDINE.count }
    return mappa.keys.sorted { (peso($0), $0) < (peso($1), $1) }
                     .map { (casa: $0, righe: mappa[$0]!) }
}

/// L'intestazione di un gruppo: la casa, quante righe, il suo totale. Il valore
/// arriva già scritto perché ogni tabella ha la sua convenzione di segno — un
/// estratto conto e un elenco di cauzioni non si leggono allo stesso modo.
private func intestazioneCasa(_ casa: String, _ righe: Int, _ valore: String,
                             _ colore: Color, padding: CGFloat = 16) -> some View {
    HStack(spacing: 10) {
        Text(casa.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(1.2)
            .foregroundStyle(PSE.accent)
        Text(righe == 1 ? "1 riga" : "\(righe) righe")
            .font(.system(size: 10)).foregroundStyle(PSE.faint)
        Spacer(minLength: 8)
        Text(valore).font(.system(size: 12, weight: .bold)).foregroundStyle(colore).monospacedDigit()
    }
    .padding(.horizontal, padding).padding(.vertical, 7)
    .background(Color.white.opacity(0.05))
    .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
}

/// Il netto di un gruppo di righe di dettaglio, col segno di come si legge.
private func nettoDettaglio(_ righe: [DettaglioRiga]) -> (testo: String, colore: Color) {
    let t = righe.reduce(0) { $0 + ($1.positivo ? $1.importo : -$1.importo) }
    return ((t < 0 ? "−" : "") + eurc(abs(t)), t < 0 ? PSE.neg : PSE.pos)
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
                // Mista Via Po / Via Romagna: una colonna per casa, affiancate.
                // Una sotto l'altra costringeva a scorrere fino in fondo a Via Po
                // per arrivare a Via Romagna — e le due non si vedevano mai
                // insieme, che è il motivo per cui uno le divide.
                // Di una casa sola resta l'elenco piatto, e la casa torna in coda
                // all'`extra` perché nessuna intestazione la dice.
                if let gruppi = gruppiPerCasa(righe, casa: { $0.casa }) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(gruppi.enumerated()), id: \.element.casa) { i, g in
                            colonnaCasa(g)
                            if i < gruppi.count - 1 {
                                Rectangle().fill(PSE.line).frame(width: 1)
                            }
                        }
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(righe) { r in riga(r, mostraCasa: true) }
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
        // Affiancare due case vuole il doppio dello spazio: la finestra si allarga
        // solo quando c'è davvero più di una colonna, e di una casa sola resta
        // della misura di prima.
        .frame(width: larghezza, height: altezza)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
    }

    /// Quanto larga: 620 punti per colonna, la misura in cui una riga si legge
    /// ancora tutta (data, descrizione, conto, importo). Ma mai più larga dello
    /// schermo: una finestra che esce dai bordi nasconde la colonna di destra, che
    /// è esattamente quella che si voleva vedere. Con una casa sola resta 760,
    /// com'era prima.
    private var larghezza: CGFloat {
        let n = min(gruppiPerCasa(righe, casa: { $0.casa })?.count ?? 1, 3)
        guard n > 1 else { return 760 }
        let schermo = (NSScreen.main?.visibleFrame.width ?? 1440) * 0.94
        return min(CGFloat(n) * 620, max(760, schermo))
    }
    private var altezza: CGFloat {
        min(600, max(420, (NSScreen.main?.visibleFrame.height ?? 900) * 0.9))
    }

    /// Una casa: la sua intestazione col totale, e sotto le sue righe che
    /// scorrono da sole. Ogni colonna scorre indipendente, così scendere in Via Po
    /// non sposta Via Romagna.
    private func colonnaCasa(_ g: (casa: String, righe: [DettaglioRiga])) -> some View {
        let netto = nettoDettaglio(g.righe)
        return VStack(spacing: 0) {
            intestazioneCasa(g.casa, g.righe.count, netto.testo, netto.colore, padding: 16)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(g.righe) { r in riga(r, mostraCasa: false, larghezzaCoda: 84, bordo: 16) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func riga(_ r: DettaglioRiga, mostraCasa: Bool,
                      larghezzaCoda: CGFloat = 150, bordo: CGFloat = 20) -> some View {
        let coda = mostraCasa ? [r.extra, r.casa].filter { !$0.isEmpty }.joined(separator: " · ") : r.extra
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !r.data.isEmpty {
                    Text(r.data).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
                        .frame(width: 62, alignment: .leading).monospacedDigit()
                }
                Text(r.descrizione).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                if !coda.isEmpty {
                    Text(coda).font(.system(size: 11)).foregroundStyle(PSE.faint)
                        .frame(width: larghezzaCoda, alignment: .leading).lineLimit(1)
                }
                Text((r.mostraSegno ? (r.positivo ? "+" : "−") : "") + eurc(r.importo))
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(r.mostraSegno ? (r.positivo ? PSE.pos : PSE.neg) : PSE.ink)
                    .frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, bordo).padding(.vertical, 9)
            Divider().overlay(PSE.line).padding(.leading, bordo)
        }
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
    // Archivio storico: la scheda per correggere una riga. Passa da qui perché
    // di tutti i .sheet appesi a questa vista ne funziona uno solo, l'ultimo.
    case storicoEdit(StoricoEditTarget, String)
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
        case .storicoEdit(let t, let p): return "sto-\(p)-\(t.id)"
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
    // Utenze: le bollette registrate, divise fra quelle già pagate e quelle che
    // scadranno. Contano solo dal primo luglio, come nella scheda Servizi: le
    // bollette di prima sono arretrati di casa, restano in archivio e fuori dai
    // totali — se no il riepilogo diceva €4.636 di utenze in un mese di attività.
    private var bolletteContate: [Bolletta] {
        model.bollette.filter { ($0.scadenza ?? "") >= INIZIO_CONTEGGIO_PSE }
    }
    private var utenzePagate: Int { bolletteContate.filter { $0.pagata }.reduce(0) { $0 + $1.importo_cents } }
    private var utenzeDaPagare: Int { bolletteContate.filter { !$0.pagata }.reduce(0) { $0 + $1.importo_cents } }
    private var utenzeArchivio: Int {
        model.bollette.filter { ($0.scadenza ?? "") < INIZIO_CONTEGGIO_PSE }.reduce(0) { $0 + $1.importo_cents }
    }
    /// Manutenzione e spese varie: non hanno una tabella, sono uscite di cassa
    /// lette per categoria — la stessa regola della scheda Servizi.
    private func speseServizio(_ t: ServizioTab) -> Int {
        movStrutFiltrati.filter { m in
            guard m.tipo == "uscita" else { return false }
            let c = (m.categoria ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            if c.contains("manutenzion") || c.contains("riparaz") { return t == .manutenzione }
            guard t == .speseVarie else { return false }
            let escluse = ["pulizia", "pulizie", "colazion", "utenz", "bolletta", "luce", "gas", "acqua",
                           "commission", "airbnb", "booking", "debito", "debiti", "prestito", "mutuo",
                           "rata", "finanziam", "deposito", "banca"]
            return !escluse.contains { c.contains($0) }
        }.reduce(0) { $0 + $1.importo_cents }
    }
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
                    PSESegmented(items: TesSub.correnti.map { ($0, $0.rawValue) }, selection: $sub)
                    // Stacco netto: a destra della riga c'è l'archivio, che con
                    // i conti di sopra non c'entra niente.
                    Rectangle().fill(PSE.line).frame(width: 1, height: 20)
                    Text("ARCHIVIO").font(.system(size: 8.5, weight: .heavy)).tracking(0.8)
                        .foregroundStyle(PSE.faint).fixedSize()
                    PSESegmented(items: TesSub.archivio.map { ($0, $0.rawValue) }, selection: $sub)
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
                    case .storico2425:
                        StoricoView(periodo: "2024-2025") { voceSheet = .storicoEdit($0, "2024-2025") }
                    case .storico2526:
                        StoricoView(periodo: "2025-2026") { voceSheet = .storicoEdit($0, "2025-2026") }
                    // Il riassunto legge tutte e due le stagioni insieme.
                    case .storicoTutto:
                        StoricoView(periodo: "tutto") { voceSheet = .storicoEdit($0, "tutto") }
                    case .servizi: ServiziView(tab: $servizioSel)
                    case .movimenti: movimentiList
                    }
                }
            }
        }
        .task { await model.load() }
        // Qualcuno ha scritto qualcosa, in questa pagina o in un'altra: i numeri
        // qui si rifanno da soli, senza rotella e senza riavviare l'app.
        .onReceive(NotificationCenter.default.publisher(for: .datiCambiati)) { _ in
            Task { await model.load(silenzioso: true) }
        }
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
            if case .storicoEdit(let t, let p) = v {
                StoricoEditSheet(periodo: p, target: t) { voceSheet = nil }
            } else {
                let d = dettaglioVoce(v)
                DettaglioVoceSheet(titolo: d.titolo, nota: d.nota, righe: d.righe,
                                   totaleLabel: d.totaleLabel, totale: d.totale) { voceSheet = nil }
            }
        }
    }

    // ── Contenuto delle sotto-finestre del Riepilogo ─────────────────────────
    // La casa sta in un campo suo, non incollata dentro `extra`: così la finestra
    // può dividere le righe per casa, e ripeterla su ogni riga solo quando non
    // c'è un'intestazione che la dica già.
    private func rigaDaMov(_ m: TesMovimento) -> DettaglioRiga {
        DettaglioRiga(id: m.id, data: tesPrettyStr(m.data),
                      descrizione: m.descrizione ?? (m.categoria ?? "—"),
                      extra: contoNomeBreve(m.conto_id),
                      casa: m.struttura != nil ? casaLabel(m.struttura) : "",
                      importo: m.importo_cents, positivo: m.tipo == "entrata")
    }
    private func rigaDaPren(_ b: Prenotazione) -> DettaglioRiga {
        let res = residuoIncassare(b)
        return DettaglioRiga(id: b.id, data: "\(tesPrettyStr(b.checkin))",
                             descrizione: b.guest_name + (b.camera.map { " · \($0)" } ?? ""),
                             extra: (b.source ?? "—").capitalized,
                             casa: casaLabel(b.struttura),
                             importo: res, positivo: true, mostraSegno: false)
    }
    private func dettaglioVoce(_ v: RiepVoce) -> (titolo: String, nota: String, righe: [DettaglioRiga], totaleLabel: String, totale: Int?) {
        switch v {
        // Non passa mai di qui: la modifica dell'archivio apre la sua scheda.
        case .storicoEdit: return ("", "", [], "", nil)
        case .conto(let id):
            let c = model.conti.first { $0.id == id }
            let mov = model.movimenti.filter { $0.conto_id == id }.sorted { $0.data > $1.data }
            let cauz = depositiConto(id)
            let nota = contoNotaFor(id) + (cauz > 0
                ? " Di questo saldo \(eurc(cauz)) sono cauzioni da restituire agli inquilini: disponibile davvero \(eurc(model.saldo(id) - cauz))."
                : "")
            return ("\(c?.nome.uppercased() ?? "CONTO") — ESTRATTO", nota,
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
            let mov = movStrutFiltrati.filter { $0.tipo == "uscita" && !isDebito($0.categoria)
                                                && !isUscitaNonCosto($0.categoria) }.sorted { $0.data > $1.data }
            return ("COSTI OPERATIVI — \(periodoLabel.uppercased())", "Costi di gestione (senza debiti/finanziamenti né partite di giro).",
                    mov.map { rigaDaMov($0) }, "TOTALE COSTI", totCostiOperativi)
        case .debiti:
            let mov = movStrutFiltrati.filter { $0.tipo == "uscita" && isDebito($0.categoria) }.sorted { $0.data > $1.data }
            return ("DEBITI / FINANZIAMENTI", "Rimborsi (debito vecchio, mutuo, rata): fuori dal margine operativo.",
                    mov.map { rigaDaMov($0) }, "TOTALE DEBITI", totDebiti)
        case .cauzioniApporti:
            let mov = movStrutFiltrati.filter { $0.tipo == "entrata" && isEntrataNonRicavo($0.categoria) }.sorted { $0.data > $1.data }
            return ("CAUZIONI + APPORTI SOCI", "Entrate che non sono ricavi: depositi da restituire, capitale dei soci, saldi di apertura e storni di commissione.",
                    mov.map { rigaDaMov($0) }, "TOTALE", totEntrateFinanziarie)
        case .movimenti(let titolo, let mov, let tot):
            return (titolo.uppercased(), "", mov.sorted { $0.data > $1.data }.map { rigaDaMov($0) }, "TOTALE", tot)
        }
    }
    private func contoNotaFor(_ id: String) -> String {
        switch id {
        case "massimo": return "Conto delle OTA di Via Po: Booking (lordo entrata / commissione uscita) e Airbnb. Il saldo è il netto e sta sopra a quello che vedi in banca, perché gli incassi sono segnati al check-out mentre Booking paga i suoi payout qualche giorno dopo."
        case "beeper": return "Bonifici (entrambe le case): affitti, depositi da restituire, apporti soci e uscite."
        case "carifermo": return "Mutuo e utenze di Via Po: solo uscite, il saldo negativo è normale."
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
                // Le altre voci di costo che vivono nella scheda Servizi: qui
                // mancavano, e il riepilogo diceva che i servizi erano solo
                // pulizie e colazioni.
                servCard("UTENZE — PAGATE DA LUGLIO", utenzePagate, "bolt.fill", PSE.neg) { servizioSheet = .utenze }
                servCard("UTENZE — DA PAGARE", utenzeDaPagare, "bolt.badge.clock", PSE.warn) { servizioSheet = .utenze }
                servCard("MANUTENZIONE", speseServizio(.manutenzione), "wrench.and.screwdriver.fill", PSE.neg) { servizioSheet = .manutenzione }
                servCard("SPESE VARIE", speseServizio(.speseVarie), "cart.fill", PSE.neg) { servizioSheet = .speseVarie }
            }
            if utenzeArchivio > 0 {
                nota("I conti dell'affittacamere partono dal 1° luglio 2026. Le bollette arrivate prima — \(eurc(utenzeArchivio)) fra luce, gas e internet da settembre 2025 — sono arretrati di casa: restano registrate e si ritrovano in Servizi → Utenze, in fondo, ma non entrano in nessun totale.")
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
        // Il saldo da solo dice quanto c'è, non quanto se ne può usare: le
        // cauzioni degli inquilini stanno su questo conto ma vanno restituite.
        let cauz = depositiConto(c.id)
        return VStack(alignment: .leading, spacing: 7) {
            Text(c.nome.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.5).foregroundStyle(PSE.faint).lineLimit(1)
            Text(eurc(s)).font(.system(size: 22, weight: .bold)).foregroundStyle(s < 0 ? PSE.neg : PSE.ink).monospacedDigit()
            if inc > 0 {
                Text("+ \(eurc(inc)) da incassare\(c.tipo == "ota" ? " (lordo)" : "")").font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.warn)
            } else {
                Text(c.tipo == "cassa" ? "Contante" : c.tipo == "ota" ? "Booking + Airbnb" : "Banca").font(.system(size: 10)).foregroundStyle(PSE.dim)
            }
            if cauz > 0 {
                Text("\(eurc(cauz)) sono cauzioni · disponibile \(eurc(s - cauz))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle((s - cauz) < 0 ? PSE.neg : PSE.dim)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        // Altezza minima: la riga delle cauzioni compare su un conto solo e
        // senza questo le card della griglia verrebbero di due altezze diverse.
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading).padding(16)
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
        if isPartitaDiGiro(m.categoria) { return true }
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
    /// Le cauzioni ferme su UN conto. Il saldo del conto le contiene — il denaro
    /// è davvero lì — ma non è spendibile: sta lì in attesa di tornare indietro.
    /// Su Beeper è la differenza fra quello che si legge in banca e quello che
    /// si può usare davvero.
    private func depositiConto(_ contoId: String) -> Int {
        depositiMov.filter { $0.conto_id == contoId }
            .reduce(0) { $0 + ($1.tipo == "entrata" ? $1.importo_cents : -$1.importo_cents) }
    }

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
                    if let gruppi = gruppiPerCasa(depositiMov, casa: { casaLabel($0.struttura) }) {
                        ForEach(gruppi, id: \.casa) { g in
                            // Qui il totale è «cauzioni ancora in mano» di quella
                            // casa: incassate meno restituite, come il totale in
                            // fondo alla tabella.
                            intestazioneCasa(g.casa, g.righe.count, saldoTesto(g.righe), PSE.warn)
                            ForEach(g.righe) { m in depositoRow(m) }
                        }
                    } else {
                        ForEach(depositiMov) { m in depositoRow(m) }
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

    private func depositoRow(_ m: TesMovimento) -> some View {
        let entrata = m.tipo == "entrata"
        return VStack(spacing: 0) {
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
                    if let gruppi = gruppiPerCasa(visibiliMov, casa: { casaLabel($0.struttura) }) {
                        ForEach(gruppi, id: \.casa) { g in
                            intestazioneCasa(g.casa, g.righe.count, saldoTesto(g.righe), saldoColore(g.righe))
                            ForEach(g.righe) { m in
                                movRow(m)
                                Divider().overlay(PSE.line).padding(.leading, 16)
                            }
                        }
                    } else {
                        ForEach(visibiliMov) { m in
                            movRow(m)
                            Divider().overlay(PSE.line).padding(.leading, 16)
                        }
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
            // Quello che sta fuori dalle card qui sopra sta fuori anche qui: se
            // no il mese diceva un totale diverso da «Entrate» e da «Costi» a
            // due centimetri di distanza.
            if fuoriDalContoEconomico(m) { continue }
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
        isCauzione(cat) || isApporto(cat) || isPartitaDiGiro(cat)
    }
    // Partite di giro: entrate che non sono soldi guadagnati. Il saldo di
    // apertura del conto (soldi che c'erano già il primo del mese) e lo storno
    // delle commissioni Booking segnate per competenza — quelle escono davvero
    // dalla banca con l'addebito SDD del mese dopo, e senza storno il conto non
    // torna con l'estratto conto. Contarle come ricavo gonfiava l'utile.
    private func isPartitaDiGiro(_ cat: String?) -> Bool {
        let c = (cat ?? "").lowercased()
        return c.hasPrefix("giro:") || c.contains("saldo iniziale") || c.contains("storno")
    }
    /// L'altro lato della partita di giro: uscite che non sono costi. Il bonifico
    /// SDD con cui Booking incassa le commissioni paga righe già contate come
    /// costo quando è arrivata la prenotazione: contarlo di nuovo faceva pagare
    /// due volte la stessa commissione.
    private func isUscitaNonCosto(_ cat: String?) -> Bool { isPartitaDiGiro(cat) }
    /// Fuori dal conto economico: entrate che non sono ricavi e uscite che non
    /// sono costi. Restano dentro ai saldi dei conti — i soldi si sono mossi
    /// davvero — ma non sono né guadagno né spesa.
    private func fuoriDalContoEconomico(_ m: TesMovimento) -> Bool {
        m.tipo == "entrata" ? isEntrataNonRicavo(m.categoria) : isUscitaNonCosto(m.categoria)
    }
    // Cauzioni e apporti stavano in una casella sola, ma sono due cose diverse:
    // la cauzione è denaro dell'inquilino da restituire, l'apporto è capitale
    // messo da un socio. Sommarle nascondeva quanto deve rientrare e quanto no.
    private func isCauzione(_ cat: String?) -> Bool { (cat ?? "").lowercased().contains("deposito") }
    private func isApporto(_ cat: String?) -> Bool { (cat ?? "").lowercased().contains("apporto") }
    private func perCategoria(_ tipo: String) -> [(cat: String, tot: Int)] {
        var map: [String: Int] = [:]
        for m in movStrutFiltrati where m.tipo == tipo {
            if fuoriDalContoEconomico(m) { continue }   // fuori dai ricavi e dai costi
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
        for m in movStrutFiltrati where m.tipo == "uscita" && isDebito(m.categoria) == debiti
                                        && !isUscitaNonCosto(m.categoria) {
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
    private var totCostiOperativi: Int { movStrutFiltrati.filter { $0.tipo == "uscita" && !isDebito($0.categoria) && !isUscitaNonCosto($0.categoria) }.reduce(0) { $0 + $1.importo_cents } }
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

            cascata(entrate: totEntrate, costi: totCostiOperativi, debiti: totDebiti)
            raccontoConto(utileOp: utileOp, utileNetto: utileNetto, margine: margineOp)

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

            // In fondo i grafici: com'è andata, cosa c'è già in calendario, e
            // dove si va a finire se il ritmo resta questo.
            PSEPieghevole("GRAFICI E PROIEZIONI",
                          valore: "andamento · prenotato · anni a venire",
                          colore: PSE.ink, coloreValore: PSE.accent,
                          nota: "tre viste, un menu", grande: true) {
                GraficiTesoreria(movimenti: movStrutFiltrati, prenotazioni: prenotazioni, struttura: movStrut)
            }
            .padding(.top, 16)
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
        movCasa(s).filter { $0.tipo == "uscita" && !isCommissioneOTA($0)
                            && !isUscitaNonCosto($0.categoria) }.sorted { $0.data < $1.data }
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
        // Sul conto Massimo non arrivano solo le OTA: c'è il saldo di apertura,
        // lo storno delle commissioni, il POS e qualche bonifico diretto. Le
        // partite di giro qui dentro sembravano incassi di ospiti mai esistiti.
        return movCasa(s).filter { $0.tipo == "entrata" && $0.conto_id == "massimo"
                                   && !isEntrataNonRicavo($0.categoria) }
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

        // Una casa = una scatola che si apre, col saldo già in testata: prima
        // erano sedici righe in colonna per due case, e per arrivare al numero
        // di Via Romagna si scorreva tutto il conto di Via Po.
        PSEPieghevole("\(s.label.uppercased()) — ENTRATE E USCITE",
                      valore: eurc(totGenerate - totUscite), colore: PSE.ink,
                      coloreValore: totGenerate - totUscite >= 0 ? PSE.pos : PSE.neg,
                      nota: "saldo generato · \(eurc(totGenerate)) entrate, \(eurc(totUscite)) uscite",
                      grande: true) {
            dettaglioCasaContenuto(s, dirette: dirette, bonifici: bonifici, incassato: incassato,
                                   uscite: uscite, future: future, totDirette: totDirette,
                                   totBonifici: totBonifici, totIncassatoNetto: totIncassatoNetto,
                                   totGenerate: totGenerate, totUscite: totUscite, totFutureNetto: totFutureNetto)
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }
    @ViewBuilder
    private func dettaglioCasaContenuto(_ s: Struttura, dirette: [TesMovimento], bonifici: [TesMovimento],
                                        incassato: [RigaOTA], uscite: [TesMovimento], future: [RigaOTA],
                                        totDirette: Int, totBonifici: Int, totIncassatoNetto: Int,
                                        totGenerate: Int, totUscite: Int, totFutureNetto: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
        switch id { case "cassa": return "Cassa"; case "massimo": return "Massimo"; case "beeper": return "Beeper"
        case "carifermo": return "Carifermo"; default: return id ?? "—" }
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
            } else {
                // Quanto di questo saldo è di qualcun altro. Detto qui e non solo
                // nella scheda «Depositi», perché è qui che si guarda il conto
                // prima di pagare qualcosa.
                let cauz = tuttiIConti ? depositiDaRestituire : depositiConto(contoSel)
                if cauz > 0 {
                    let oggi = tuttiIConti ? model.totaleConti : model.saldo(contoSel)
                    Text("Di quello che c'è oggi \(tuttiIConti ? "sui conti" : "su questo conto") — \(eurc(oggi)) — \(eurc(cauz)) sono cauzioni degli inquilini da restituire: disponibile davvero \(eurc(oggi - cauz)). Il dettaglio è nella scheda «Depositi».")
                        .font(.system(size: 10.5)).foregroundStyle((oggi - cauz) < 0 ? PSE.neg : PSE.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        case "tutti": return "Tutti i conti insieme: Cassa (contante, entrambe le case) + Massimo (le OTA di Via Po) + Beeper (bonifici) + Carifermo (mutuo e utenze di Via Po). La colonna «Conto» indica dove è transitato il denaro."
        case "massimo": return "Conto delle OTA di Via Po: qui arrivano Booking e Airbnb, e solo di quella casa. Booking entra al lordo con la commissione (16,5%) come uscita, quindi il saldo è il netto; Airbnb non ha commissione. Via Romagna non passa da qui: incassa in contante o per bonifico. Le prenotazioni future sono in «da incassare»."
        case "beeper": return "Estratto conto bonifici, entrambe le case: affitti bonificati, depositi degli inquilini (da restituire) e uscite (rata prestito, muratore, Marroni, spese banca)."
        case "carifermo": return "Il conto da cui è partito il mutuo di Via Po: da qui escono la rata da 690 € (scritta da sola il primo di ogni mese) e le bollette di Via Po pagate da luglio 2026, che restano allineate alla scheda Servizi. Non incassa nulla: il saldo negativo è normale, i soldi per coprirlo si spostano dagli altri conti."
        default: return "Contante Via Po + Via Romagna: affitti in entrata; pulizia, colazioni, chiavi e idraulico in uscita."
        }
    }
    private func contoLedger(_ title: String, _ items: [TesMovimento], _ tot: Int, _ c: Color, _ sign: String, showConto: Bool = false) -> some View {
        PSEPieghevole(title, valore: sign + eurc(tot), coloreValore: c,
                      nota: "\(items.count) movimenti") {
            // Un estratto conto mette insieme le due case per forza: il conto è
            // in comune. Dividerlo dice quanta parte di queste entrate (o di
            // queste uscite) è di una casa e quanta dell'altra.
            if let gruppi = gruppiPerCasa(items, casa: { casaLabel($0.struttura) }) {
                ForEach(gruppi, id: \.casa) { g in
                    intestazioneCasa(g.casa, g.righe.count, sommaTesto(g.righe, segno: sign), c)
                    ForEach(Array(g.righe.enumerated()), id: \.element.id) { i, m in
                        contoLedgerRow(m, c, sign, showConto: showConto,
                                       ultima: i == g.righe.count - 1)
                    }
                }
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                    contoLedgerRow(m, c, sign, showConto: showConto, ultima: i == items.count - 1)
                }
            }
        }
    }
    private func contoLedgerRow(_ m: TesMovimento, _ c: Color, _ sign: String,
                                showConto: Bool, ultima: Bool) -> some View {
        VStack(spacing: 0) {
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
            if !ultima { Divider().overlay(PSE.line).padding(.leading, 16) }
        }
    }
    private func casaLabel(_ s: String?) -> String {
        s == "via-po" ? "Via Po" : s == "via-romagna" ? "Via Romagna" : "—"
    }
    // ── Il totale di un gruppo di casa ───────────────────────────────────────
    /// Entrate meno uscite: in un elenco che contiene i due versi è l'unico
    /// numero che significa qualcosa. In un elenco di soli movimenti dello
    /// stesso verso viene la loro somma, che è quello che uno si aspetta.
    private func saldoGruppo(_ mov: [TesMovimento]) -> Int {
        mov.reduce(0) { $0 + ($1.tipo == "entrata" ? $1.importo_cents : -$1.importo_cents) }
    }
    private func saldoTesto(_ mov: [TesMovimento]) -> String {
        let s = saldoGruppo(mov)
        return (s < 0 ? "−" : "") + eurc(abs(s))
    }
    private func saldoColore(_ mov: [TesMovimento]) -> Color {
        saldoGruppo(mov) < 0 ? PSE.neg : PSE.pos
    }
    /// Nelle sezioni di un verso solo (ENTRATE / USCITE dell'estratto conto, le
    /// cauzioni) il segno lo dà già il titolo: qui basta la somma.
    private func sommaTesto(_ mov: [TesMovimento], segno: String) -> String {
        segno + eurc(mov.reduce(0) { $0 + $1.importo_cents })
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
    // ══ COME L'INCASSO DIVENTA UTILE ═════════════════════════════════════════
    // Otto numeri in fila non raccontano niente: si legge il primo, si legge
    // l'ultimo e in mezzo si tira a indovinare. Qui la stessa cifra si vede
    // scendere — entrate, meno i costi, meno i debiti — e sotto c'è scritto a
    // parole cosa vuol dire, con i soldi veri dentro la frase.
    private func cascata(entrate: Int, costi: Int, debiti: Int) -> some View {
        let base = max(1, entrate)
        let utileOp = entrate - costi
        let netto = utileOp - debiti
        return VStack(alignment: .leading, spacing: 10) {
            Text("DOVE FINISCONO I SOLDI CHE ENTRANO")
                .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
            VStack(spacing: 7) {
                barraCascata("Entrano", entrate, base, PSE.pos, "Affitti, OTA ed Educamp — cauzioni e apporti esclusi", nil)
                barraCascata("Costi di gestione", -costi, base, PSE.neg,
                             "Pulizie, colazioni, commissioni, utenze, manutenzione", .costiOperativi)
                barraCascata("Restano dalla gestione", utileOp, base, PSE.ink,
                             "Quello che l'attività produce, prima dei debiti", nil)
                if debiti > 0 {
                    barraCascata("Rimborsi di debiti", -debiti, base, PSE.warn,
                                 "Marroni, muratore, mutuo, rata: restituzioni, non costi", .debiti)
                }
                barraCascata("Restano a noi", netto, base, netto >= 0 ? PSE.pos : PSE.neg,
                             "Il denaro che l'attività ha lasciato in cassa nel periodo", nil)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    @ViewBuilder
    private func barraCascata(_ t: String, _ v: Int, _ base: Int, _ c: Color, _ spiega: String, _ voce: RiepVoce?) -> some View {
        let frac = min(1, Double(abs(v)) / Double(base))
        let riga = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink).lineLimit(1)
                Text(spiega).font(.system(size: 10)).foregroundStyle(PSE.faint).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(width: 250, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(PSE.surface).frame(height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(c.opacity(v < 0 ? 0.55 : 0.8))
                        .frame(width: max(3, geo.size.width * frac), height: 14)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 20)
            Text((v < 0 ? "−" : "") + eurc(abs(v)))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(c).monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                .foregroundStyle(PSE.faint.opacity(voce == nil ? 0 : 1)).frame(width: 10)
        }
        if let voce {
            Button { voceSheet = voce } label: { riga.contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Clicca per vedere le righe")
        } else {
            riga
        }
    }
    /// La stessa cosa detta a parole, con dentro i numeri del periodo scelto.
    private func raccontoConto(utileOp: Int, utileNetto: Int, margine: Int) -> some View {
        let periodoTxt = periodo == "tutto" ? "da quando è aperto" : "in \(periodoLabel.lowercased())"
        // .capitalized alzerebbe ogni parola («Da Quando È Aperto»): qui va solo
        // la prima lettera, come in una frase.
        var t = "\(periodoTxt.prefix(1).uppercased() + periodoTxt.dropFirst()) sono entrati \(eurc(totEntrate)) di ricavi veri. "
        t += "Farli girare è costato \(eurc(totCostiOperativi)): resta \(eurc(utileOp)), cioè \(margine) centesimi ogni euro incassato. "
        if totDebiti > 0 {
            t += "Poi \(eurc(totDebiti)) se ne sono andati a rimborsare debiti — che non sono costi dell'attività, sono soldi restituiti — quindi in cassa restano \(eurc(utileNetto)). "
        }
        if totCauzioni > 0 || totApporti > 0 {
            t += "Sui conti ci sono anche \(eurc(totCauzioni)) di cauzioni degli inquilini (da rendere) e \(eurc(totApporti)) messi dai soci: entrano, ma non sono guadagno."
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.book.closed.fill").font(.system(size: 13)).foregroundStyle(PSE.accent)
                .padding(.top, 1)
            Text(t).font(.system(size: 12)).foregroundStyle(PSE.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.accent.opacity(0.25), lineWidth: 1))
    }

    /// I movimenti di una categoria, nel periodo e nella casa già filtrati:
    /// sono gli stessi che compongono la barra su cui si è cliccato.
    private func movimentiCategoria(_ cat: String) -> [TesMovimento] {
        movStrutFiltrati.filter { ($0.categoria?.isEmpty == false ? $0.categoria! : "altro") == cat }
            .sorted { $0.data > $1.data }
    }
    private func mensileRow(_ r: (key: String, entrate: Int, uscite: Int), maxAbs: Int) -> some View {
        let utile = r.entrate - r.uscite
        let frac = min(1, Double(abs(utile)) / Double(maxAbs))
        let delMese = movStrutFiltrati.filter { $0.data.hasPrefix(r.key) }.sorted { $0.data > $1.data }
        return Button {
            voceSheet = .movimenti(meseNome(r.key), delMese, r.entrate - r.uscite)
        } label: {
            mensileRiga(r, utile: utile, frac: frac).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(meseNome(r.key)): \(delMese.count) movimenti — clicca per vederli")
    }
    private func mensileRiga(_ r: (key: String, entrate: Int, uscite: Int), utile: Int, frac: Double) -> some View {
        HStack(spacing: 12) {
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
                    // Ogni categoria si apre: «Pulizia 400 €» è una domanda finché
                    // non si vedono le righe che ci stanno sotto.
                    Button { voceSheet = .movimenti(r.cat.capitalized, movimentiCategoria(r.cat), r.tot) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(r.cat.capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(eurc(r.tot)).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                                Text("\(pct)%").font(.system(size: 10, weight: .semibold)).foregroundStyle(PSE.faint).frame(width: 34, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(PSE.faint)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(PSE.surface).frame(height: 6)
                                    RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.7))
                                        .frame(width: max(2, geo.size.width * Double(r.tot) / Double(maxTot)), height: 6)
                                }
                            }.frame(height: 6)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(r.cat.capitalized): \(eurc(r.tot)) — clicca per vedere i movimenti")
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
        }.buttonStyle(.plain).help("Scarica tutta la tesoreria in un unico CSV: ogni conto con entrate e uscite divise per casa")
    }

    /// Cosa finisce nell'export: tutti i movimenti del periodo scelto (e della
    /// casa, se il filtro è attivo). Non dipende dalla scheda aperta né dal
    /// «solo fino a oggi»: il file è sempre la tesoreria intera, Educamp a parte.
    private var exportMovimenti: [TesMovimento] {
        model.movimenti
            .filter { nelPeriodo($0) && (movStrut == nil || $0.struttura == movStrut!.rawValue) }
            .sorted { $0.data > $1.data }
    }

    private func exportCSV() {
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func riga(_ campi: [String]) -> String { campi.map { q($0) }.joined(separator: ";") + "\n" }
        func num(_ cents: Int) -> String {
            String(format: "%.2f", Double(cents) / 100).replacingOccurrences(of: ".", with: ",")
        }
        func casaNome(_ s: String?) -> String {
            s == "via-po" ? "Via Po" : s == "via-romagna" ? "Via Romagna" : "Non attribuito"
        }
        func contoNome(_ id: String?) -> String { model.conti.first { $0.id == id }?.nome ?? (id ?? "—") }
        func tot(_ mov: [TesMovimento]) -> Int { mov.reduce(0) { $0 + $1.importo_cents } }
        func totTipo(_ mov: [TesMovimento], _ tipo: String) -> Int { tot(mov.filter { $0.tipo == tipo }) }
        let colonne = ["Data", "Casa", "Categoria", "Descrizione", "Conto", "Modalità", "Importo"]
        let vuote = [String](repeating: "", count: colonne.count - 2)   // per allineare i totali all'ultima colonna

        let mov = exportMovimenti
        // Le case in cui si divide ogni blocco: col filtro attivo resta solo
        // quella, se no Via Po, Via Romagna e i movimenti senza casa.
        let leCase: [String?] = movStrut != nil ? [movStrut!.rawValue] : ["via-po", "via-romagna", nil]
        func diCasa(_ righe: [TesMovimento], _ slug: String?) -> [TesMovimento] {
            righe.filter { slug == nil ? ($0.struttura != "via-po" && $0.struttura != "via-romagna") : $0.struttura == slug }
        }
        /// Un conto (o «tutti i conti»): entrate e uscite, ognuna divisa casa per
        /// casa, e in fondo la differenza — la stessa lettura della scheda Conti.
        func sezioneConto(_ titolo: String, _ righe: [TesMovimento]) -> String {
            var s = "\n" + riga([titolo]) + riga(["Movimenti", String(righe.count)]) + "\n"
            for tipo in ["entrata", "uscita"] {
                let etichetta = tipo == "entrata" ? "ENTRATE" : "USCITE"
                let delTipo = righe.filter { $0.tipo == tipo }
                for slug in leCase {
                    let g = diCasa(delTipo, slug)
                    guard !g.isEmpty else { continue }
                    s += riga(["\(etichetta) — \(casaNome(slug).uppercased()) (\(g.count) moviment\(g.count == 1 ? "o" : "i"))"])
                    s += riga(colonne)
                    for m in g {
                        s += riga([m.data, casaNome(m.struttura), m.categoria ?? "", m.descrizione ?? "",
                                   contoNome(m.conto_id), m.modalita ?? "", num(m.importo_cents)])
                    }
                    s += riga(["Totale \(etichetta.lowercased()) \(casaNome(slug))"] + vuote + [num(tot(g))]) + "\n"
                }
                s += riga(["TOTALE \(etichetta) — \(titolo)"] + vuote + [num(tot(delTipo))]) + "\n"
            }
            s += riga(["TOTALE DIFFERENZA (ENTRATE − USCITE) — \(titolo)"] + vuote
                      + [num(totTipo(righe, "entrata") - totTipo(righe, "uscita"))])
            return s
        }

        // ── Intestazione ──
        var csv = "\u{FEFF}"
        csv += riga(["TESORERIA — CAMERE PSE"])
        csv += riga(["Periodo", periodoLabel])
        csv += riga(["Casa", movStrut?.label ?? "Tutte"])
        csv += riga(["Esportato il", oggiStr])
        csv += riga(["Movimenti nel file", String(mov.count)])

        // ── Riepiloghi in testa: gli stessi totali delle card ──
        csv += "\n" + riga(["RIEPILOGO PER CASA"]) + riga(["Casa", "Entrate", "Uscite", "Differenza"])
        for slug in leCase {
            let g = diCasa(mov, slug)
            guard !g.isEmpty else { continue }
            let e = totTipo(g, "entrata"), u = totTipo(g, "uscita")
            csv += riga([casaNome(slug), num(e), num(u), num(e - u)])
        }
        let totE = totTipo(mov, "entrata"), totU = totTipo(mov, "uscita")
        csv += riga(["TOTALE", num(totE), num(totU), num(totE - totU)])

        csv += "\n" + riga(["RIEPILOGO PER CONTO"]) + riga(["Conto", "Entrate", "Uscite", "Differenza", "Saldo del conto (tutti i periodi)"])
        for c in model.conti {
            let g = mov.filter { $0.conto_id == c.id }
            let e = totTipo(g, "entrata"), u = totTipo(g, "uscita")
            csv += riga([c.nome, num(e), num(u), num(e - u), num(model.saldo(c.id))])
        }
        csv += riga(["TOTALE", num(totE), num(totU), num(totE - totU), num(model.totaleConti)])

        // ── Un blocco per ogni voce dei conti, come le schede a schermo ──
        csv += sezioneConto("TUTTI I CONTI", mov)
        for c in model.conti { csv += sezioneConto(c.nome.uppercased(), mov.filter { $0.conto_id == c.id }) }
        // Movimenti senza conto: se ci sono devono comparire, o i blocchi dei
        // singoli conti non sommerebbero al blocco «tutti i conti».
        let senzaConto = mov.filter { m in !model.conti.contains { $0.id == m.conto_id } }
        if !senzaConto.isEmpty { csv += sezioneConto("SENZA CONTO", senzaConto) }

        // ── Conto economico (base cassa), stessa classificazione della scheda ──
        csv += "\n" + riga(["CONTO ECONOMICO — \(periodoLabel.uppercased())"]) + riga(["Voce", "Importo"])
        csv += riga(["Ricavi da attività", num(totEntrate)])
        csv += riga(["Costi operativi", num(totCostiOperativi)])
        csv += riga(["Utile operativo (ricavi − costi)", num(totEntrate - totCostiOperativi)])
        csv += riga(["Debiti e finanziamenti (rimborsi)", num(totDebiti)])
        csv += riga(["Cauzioni incassate (da restituire)", num(totCauzioni)])
        csv += riga(["Apporti soci (capitale)", num(totApporti)])
        csv += riga(["Totale entrate", num(totE)])
        csv += riga(["Totale uscite", num(totU)])
        let ricaviCat = perCategoria("entrata"), costiCat = perCategoriaUscite(debiti: false), debitiCat = perCategoriaUscite(debiti: true)
        if !ricaviCat.isEmpty {
            csv += "\n" + riga(["RICAVI PER CATEGORIA"]) + riga(["Categoria", "Importo"])
            for r in ricaviCat { csv += riga([r.cat, num(r.tot)]) }
        }
        if !costiCat.isEmpty {
            csv += "\n" + riga(["COSTI OPERATIVI PER CATEGORIA"]) + riga(["Categoria", "Importo"])
            for r in costiCat { csv += riga([r.cat, num(r.tot)]) }
        }
        if !debitiCat.isEmpty {
            csv += "\n" + riga(["DEBITI E FINANZIAMENTI PER CATEGORIA"]) + riga(["Categoria", "Importo"])
            for r in debitiCat { csv += riga([r.cat, num(r.tot)]) }
        }

        // ── Depositi cauzionali: entrano ed escono, quindi hanno colonna «movimento» ──
        let dep = mov.filter { isDeposito($0) }
        if !dep.isEmpty {
            csv += "\n" + riga(["DEPOSITI CAUZIONALI"])
            csv += riga(["Data", "Casa", "Movimento", "Descrizione", "Conto", "Importo"])
            for m in dep {
                csv += riga([m.data, casaNome(m.struttura), m.tipo == "entrata" ? "Incassata" : "Restituita",
                             m.descrizione ?? "", contoNome(m.conto_id), num(m.importo_cents)])
            }
            let daRestituire = dep.reduce(0) { $0 + ($1.tipo == "entrata" ? $1.importo_cents : -$1.importo_cents) }
            csv += riga(["ANCORA DA RESTITUIRE", "", "", "", "", num(daRestituire)])
        }

        // ── Servizi: pulizie, colazioni e bollette stanno in tabelle loro, non
        //    nei movimenti, quindi vanno in coda con i propri totali. ──
        func nelPeriodoData(_ d: String?) -> Bool { periodo == "tutto" || (d ?? "").hasPrefix(periodo) }
        func casaOk(_ c: String?) -> Bool { movStrut == nil || c == movStrut!.rawValue }
        let pulizie = model.pulizie.filter { nelPeriodoData($0.data) && casaOk($0.casa) }
        if !pulizie.isEmpty {
            csv += "\n" + riga(["SERVIZI — PULIZIE"]) + riga(["Data", "Casa", "Descrizione", "Stato", "Costo"])
            for p in pulizie.sorted(by: { ($0.data ?? "") > ($1.data ?? "") }) {
                csv += riga([p.data ?? "", casaNome(p.casa), p.descrizione ?? "", p.stato ?? "", num(p.costo_cents)])
            }
            let fatte = pulizie.filter { $0.stato == "fatta" }.reduce(0) { $0 + $1.costo_cents }
            csv += riga(["TOTALE FATTE", "", "", "", num(fatte)])
            csv += riga(["TOTALE PREVISTE", "", "", "", num(pulizie.reduce(0) { $0 + $1.costo_cents } - fatte)])
        }
        let colazioni = model.colazioni.filter { nelPeriodoData($0.arrivo) && casaOk($0.casa) }
        if !colazioni.isEmpty {
            csv += "\n" + riga(["SERVIZI — COLAZIONI"])
            csv += riga(["Arrivo", "Partenza", "Casa", "Ospite", "Camera", "Notti", "Persone", "Notti servite", "Costo servito", "Costo totale", "Stato"])
            for c in colazioni.sorted(by: { ($0.arrivo ?? "") > ($1.arrivo ?? "") }) {
                csv += riga([c.arrivo ?? "", c.partenza ?? "", casaNome(c.casa), c.ospite ?? "", c.camera ?? "",
                             String(c.notti ?? 0), String(c.persone ?? 0), String(c.notti_servite ?? 0),
                             num(c.costo_servito_cents), num(c.costo_totale_cents), c.stato ?? ""])
            }
            csv += riga(["TOTALE SERVITO", "", "", "", "", "", "", "", num(colazioni.reduce(0) { $0 + $1.costo_servito_cents }),
                         num(colazioni.reduce(0) { $0 + $1.costo_totale_cents }), ""])
        }
        let bollette = model.bollette.filter { nelPeriodoData($0.scadenza) && (movStrut == nil || $0.casa == movStrut!.rawValue || $0.casa == "comune") }
        if !bollette.isEmpty {
            csv += "\n" + riga(["SERVIZI — UTENZE (BOLLETTE)"])
            csv += riga(["Scadenza", "Casa", "Tipo", "Fornitore", "Periodo", "Pagata", "Importo"])
            for b in bollette.sorted(by: { ($0.scadenza ?? "") > ($1.scadenza ?? "") }) {
                let casa = b.casa == "comune" ? "Comune" : casaNome(b.casa)
                csv += riga([b.scadenza ?? "", casa, b.tipo, b.fornitore ?? "", b.periodo ?? "",
                             b.pagata ? "sì" : "no", num(b.importo_cents)])
            }
            let pagate = bollette.filter { $0.pagata }.reduce(0) { $0 + $1.importo_cents }
            csv += riga(["TOTALE PAGATE", "", "", "", "", "", num(pagate)])
            csv += riga(["TOTALE DA PAGARE", "", "", "", "", "", num(bollette.reduce(0) { $0 + $1.importo_cents } - pagate)])
        }

        // nome file parlante: casa + periodo, così i CSV per il commercialista
        // non finiscono tutti con lo stesso nome
        var parti = ["camere-pse", "tesoreria"]
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

    // ── Le categorie ─────────────────────────────────────────────────────────
    // Il Conto economico raggruppa per questa stringa: «Affitto» e «affitto»
    // erano due voci diverse, e una categoria scritta a mano come frase («RATA
    // MUTUO LUGLIO») diventava una riga tutta sua. Il database ora normalizza
    // maiuscole e spazi da sé, ma l'unico modo di non inventare ogni volta una
    // parola nuova è vedere quelle che esistono già.
    //
    // Restano scrivibili a mano: le partite di giro («giro: …») non si possono
    // elencare in anticipo, e sarebbe sbagliato impedirle.
    private static let ALTRA = "__altra__"
    private static let categorieEntrata: [(String, String)] = [
        ("affitto", "Affitto — incasso di un soggiorno"),
        ("booking", "Booking — incasso OTA"),
        ("airbnb", "Airbnb — incasso OTA"),
        ("educamp", "Educamp — affitto mensile"),
        ("deposito", "Deposito — cauzione ricevuta"),
        ("apporto", "Apporto — capitale dei soci"),
        ("altro", "Altro"),
    ]
    private static let categorieUscita: [(String, String)] = [
        ("pulizia", "Pulizia — 20 € per check-out"),
        ("colazioni", "Colazioni"),
        ("commissione", "Commissione — OTA"),
        ("utenze", "Utenze — luce, gas, internet"),
        ("mutuo", "Mutuo — rata"),
        ("manutenzione", "Manutenzione"),
        ("spesa", "Spesa"),
        ("banca", "Banca — spese e commissioni"),
        ("tasse", "Tasse"),
        ("assicurazione", "Assicurazione"),
        ("debito", "Debito — rimborso di un debito vecchio"),
        ("deposito", "Deposito — cauzione restituita"),
        ("altro", "Altro"),
    ]
    private var categorieCorrenti: [(String, String)] {
        tipo == "entrata" ? Self.categorieEntrata : Self.categorieUscita
    }
    private var categorieOpts: [(String, String)] {
        categorieCorrenti + [(Self.ALTRA, "Altra… (la scrivo io)")]
    }
    /// Cosa mostra il menù: la categoria scelta, oppure «Altra…» quando quella
    /// che c'è non è in elenco — una `giro:` o una vecchia riga da correggere.
    private var categoriaNelMenu: String {
        categorieCorrenti.contains { $0.0 == categoria } ? categoria : Self.ALTRA
    }
    /// Le categorie che NON si scrivono qui: le porta la sincronizzazione dalla
    /// prenotazione o dalla scheda Servizi. Metterle a mano fa contare due volte
    /// lo stesso soggiorno — è esattamente l'errore che si vuole rendere difficile.
    private var categoriaGiaAutomatica: String? {
        if tipo == "entrata", ["affitto", "booking", "airbnb"].contains(categoria) {
            return "Questa entrata la scrive la sincronizzazione da sola, dalla prenotazione. "
                 + "Se la metti anche qui, l'incasso si conta due volte: apri la prenotazione in "
                 + "Prenotazioni e scrivi quanto ha pagato."
        }
        if tipo == "uscita", ["pulizia", "colazioni"].contains(categoria) {
            return "Questa uscita nasce dalla scheda Servizi al check-out, non si registra a mano: "
                 + "se la scrivi qui diventa un doppione. Serve una correzione? Cambiala in Servizi."
        }
        return nil
    }
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
                pick("Categoria", categorieOpts, categoriaNelMenu) { scelta in
                    // «Altra…» non è una categoria: è il permesso di scriverne una.
                    // Il campo di testo resta con quello che c'era, così una
                    // «giro: …» aperta per correggerla non si perde.
                    categoria = scelta == Self.ALTRA ? categoria : scelta
                }
                if categoriaNelMenu == Self.ALTRA {
                    HoloField(label: "Quale categoria", text: $categoria, placeholder: "giro: storno commissioni…")
                }
                if let avviso = categoriaGiaAutomatica {
                    Text(avviso)
                        .font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xffd08a))
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    // Un bottone spento che non dice cosa gli manca lascia a
                    // indovinare: se l'importo non si legge, lo scrive qui.
                    if cents == nil, !importo.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Importo non leggibile: scrivi solo la cifra, tipo 700 o 1.200,50")
                            .font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xffb3ad))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
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

    /// L'importo si prende come lo scrivi: «700», «700€», «€ 700», «1.200,50».
    /// Il campo si chiama «Importo €», quindi scriverci dentro l'euro è la cosa
    /// naturale da fare, e prima bastava quel simbolo perché il bottone Salva
    /// restasse spento senza dire perché. Stessa cosa per i punti delle
    /// migliaia, che erano il modo normale di scrivere milleduecento.
    private var cents: Int? {
        var s = importo.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }
        if s.contains(",") {
            // virgola decimale all'italiana: i punti rimasti sono le migliaia
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if s.contains("."), (s.split(separator: ".").last?.count ?? 0) == 3 {
            // «1.200» sono milleduecento, «700.50» sono settecento e cinquanta
            // centesimi: a distinguerli è solo quante cifre vengono dopo.
            s = s.replacingOccurrences(of: ".", with: "")
        }
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
        // Minuscolo e senza spazi: lo fa anche il database con un trigger, ma
        // farlo qui evita che la riga appena salvata si mostri diversa da come
        // sta scritta, fino al prossimo caricamento.
        let cat = categoria.trimmingCharacters(in: .whitespaces).lowercased()
        return ["data": tesYmd.string(from: data), "conto_id": contoId, "tipo": tipo,
                "categoria": cat.isEmpty ? nil : cat, "descrizione": descrizioneFinale(),
                "importo_cents": cents ?? 0, "modalita": modalita,
                "struttura": struttura == "—" ? nil : struttura]
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
