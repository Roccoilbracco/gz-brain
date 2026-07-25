import SwiftUI

// ============================================================================
// Camere PSE — pannello controllo prenotazioni (Via Po · Via Romagna)
// Stato prenotazioni, pagamenti, check-in/out. Dati demo ora; poi integrazione
// con le richieste dal sito camerepse.it.
// ============================================================================

struct Prenotazione: Identifiable, Decodable, Equatable {
    let id: String
    var struttura: String
    var camera: String?
    var guest_name: String
    var guest_phone: String?
    var guest_email: String?
    var checkin: String?
    var checkout: String?
    var guests: Int?
    var amount_cents: Int
    var paid_cents: Int
    var status: String
    var source: String?
    var conto_id: String?
    var notes: String?
    let created_at: String?
}

enum BookingStatus: String, CaseIterable, Identifiable {
    case in_attesa, confermata, in_casa, partita, cancellata
    var id: String { rawValue }
    var label: String {
        switch self {
        case .in_attesa: return "In attesa"
        case .confermata: return "Confermata"
        case .in_casa: return "In casa"
        case .partita: return "Partita"
        case .cancellata: return "Cancellata"
        }
    }
    var hue: Double {
        switch self {
        case .in_attesa: return 45
        case .confermata: return 210
        case .in_casa: return 150
        case .partita: return 190
        case .cancellata: return 5
        }
    }
    var active: Bool { self == .in_attesa || self == .confermata || self == .in_casa }
    static func from(_ s: String?) -> BookingStatus { BookingStatus(rawValue: s ?? "") ?? .in_attesa }
}

enum Struttura: String, CaseIterable, Identifiable {
    case viaPo = "via-po", viaRomagna = "via-romagna"
    var id: String { rawValue }
    var label: String { self == .viaPo ? "Via Po" : "Via Romagna" }
    var address: String { self == .viaPo ? "Via Po 13" : "Via Romagna 41" }
    var hue: Double { self == .viaPo ? 200 : 280 }
    var rooms: [String] {
        self == .viaPo
        ? ["Stanza 1 · Camera Queen", "Stanza 2 · Standard", "Stanza 3 · Camera King", "Stanza 4 · Ampia Matrimoniale", "Intera struttura"]
        : ["Doppia senza bagno", "Balcone senza bagno", "Stanza Camino", "Balcone con bagno (ragazzi)", "Mansarda", "Intero appartamento"]
    }
    // "es-vedra" è il vecchio slug di Via Po: i dati sono stati migrati, ma lo
    // riconosciamo comunque per non mostrare come Via Po una riga sconosciuta.
    static func from(_ s: String?) -> Struttura {
        if s == "es-vedra" { return .viaPo }
        return Struttura(rawValue: s ?? "") ?? .viaPo
    }
}

let bookingSources = ["sito", "whatsapp", "booking", "airbnb", "telefono", "email"]

enum PayState { case daPagare, acconto, pagato
    var label: String { switch self { case .daPagare: return "Da pagare"; case .acconto: return "Acconto"; case .pagato: return "Saldato" } }
    var hue: Double { switch self { case .daPagare: return 5; case .acconto: return 45; case .pagato: return 150 } }
}
func payState(amount: Int, paid: Int) -> PayState {
    if paid <= 0 { return .daPagare }
    return paid >= amount ? .pagato : .acconto
}

// cents → "€X" (arrotondato all'euro: viste operative, prezzi di listino)
func eur(_ cents: Int) -> String { LeadFmt.euro(cents / 100) }

// cents → "€1.076,77" — in contabilità i centesimi si mostrano sempre, altrimenti
// le righe non sommano al totale mostrato.
func eurc(_ cents: Int) -> String {
    let neg = cents < 0, a = abs(cents)
    return "€" + (neg ? "-" : "") + LeadFmt.euro(a / 100).dropFirst() + "," + String(format: "%02d", a % 100)
}

// ── Tema sobrio e professionale (poco colore, tinte desaturate) ──
enum PSE {
    static let ink = Holo.titleText                                   // testo forte
    static let text = Color(red: 210/255, green: 220/255, blue: 236/255)
    static let dim = Color(red: 190/255, green: 202/255, blue: 224/255).opacity(0.62)
    static let faint = Color(red: 150/255, green: 165/255, blue: 190/255).opacity(0.55)
    static let line = Color.white.opacity(0.09)
    static let surface = Color.white.opacity(0.035)
    static let accent = Color(red: 0.44, green: 0.56, blue: 0.74)     // slate blue sobrio
    static let warn = Color(hex: 0xd97757)   // arancio del brand (come sidebar/avatar): da confermare / azioni
    static let panel = Color(hex: 0x0f141e)
    static let pos = Color(hue: 150/360, saturation: 0.40, brightness: 0.62)  // entrate
    static let neg = Color(hue: 5/360,   saturation: 0.46, brightness: 0.62)  // uscite

    // tinte di stato desaturate (professionali, non fluo)
    static func status(_ s: BookingStatus) -> Color {
        switch s {
        case .in_attesa:  return Color(hue: 40/360,  saturation: 0.42, brightness: 0.68)
        case .confermata: return Color(hue: 210/360, saturation: 0.36, brightness: 0.70)
        case .in_casa:    return Color(hue: 150/360, saturation: 0.34, brightness: 0.60)
        case .partita:    return Color(hue: 220/360, saturation: 0.08, brightness: 0.60)
        case .cancellata: return Color(hue: 5/360,   saturation: 0.42, brightness: 0.60)
        }
    }
    static func payment(_ p: PayState) -> Color {
        switch p {
        case .daPagare: return Color(hue: 5/360,   saturation: 0.40, brightness: 0.60)
        case .acconto:  return Color(hue: 40/360,  saturation: 0.40, brightness: 0.66)
        case .pagato:   return Color(hue: 150/360, saturation: 0.32, brightness: 0.58)
        }
    }
}

private let itLoc = Locale(identifier: "it_IT")
private func fmt(_ pattern: String) -> DateFormatter { let f = DateFormatter(); f.locale = itLoc; f.dateFormat = pattern; return f }
private let wdFmt = fmt("EEE"), dNumFmt = fmt("d"), moFmt = fmt("MMM"), fullFmt = fmt("EEEE d MMMM")

// notti tra due date ISO
private let ymdBk: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
func nights(_ ci: String?, _ co: String?) -> Int? {
    guard let a = ci.flatMap({ ymdBk.date(from: String($0.prefix(10))) }),
          let b = co.flatMap({ ymdBk.date(from: String($0.prefix(10))) }) else { return nil }
    return max(0, Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0)
}

// ── API ──────────────────────────────────────────────────────────────────────
extension HubAPI {
    static func listPrenotazioni() async throws -> [Prenotazione] {
        try await sb.fetch("prenotazioni?select=*&order=checkin.asc.nullslast&limit=2000")
    }
    @discardableResult
    static func createPrenotazione(_ f: [String: Any?]) async throws -> Prenotazione {
        try await sb.insertReturning("prenotazioni", body: f)
    }
    static func updatePrenotazione(id: String, fields: [String: Any?]) async throws {
        var b = fields; b["updated_at"] = isoNowString()
        try await sb.mutate("prenotazioni?id=eq.\(id)", method: "PATCH", body: b)
    }
    static func deletePrenotazione(id: String) async throws {
        try await sb.mutate("prenotazioni?id=eq.\(id)", method: "DELETE")
    }
    /// Riallinea pulizie, colazioni e incassi in cassa allo stato attuale delle
    /// prenotazioni. Idempotente: la si può chiamare a ogni modifica senza
    /// creare doppioni. Silenziosa: se fallisce non blocca il salvataggio.
    static func syncCamerePSE() async {
        _ = try? await sb.rpc("sync_camere_pse")
    }
    /// Cancella la prenotazione e porta via quello che ne dipendeva: la pulizia
    /// prevista, le colazioni non servite e — se `stralciaIncasso` — l'incasso
    /// che la sincronizzazione aveva già scritto in cassa. Ritorna il riepilogo
    /// di cosa ha toccato, o nil se la funzione non risponde.
    static func annullaPrenotazione(id: String, stralciaIncasso: Bool) async -> [String: Any]? {
        guard let d = try? await sb.rpc("annulla_prenotazione",
                                        args: ["p_id": id, "p_stralcia_incasso": stralciaIncasso]),
              let j = try? JSONSerialization.jsonObject(with: d) else { return nil }
        // PostgREST incarta il ritorno scalare in un oggetto o in un array a
        // seconda della versione: si accettano tutte e due le forme.
        if let o = j as? [String: Any] { return o }
        if let a = j as? [[String: Any]] { return a.first }
        return nil
    }
}

enum PSEViewMode { case prenotazioni, tesoreria }

// segmented control coerente col tema Camere PSE (niente picker nativo grigio)
//
// `lineLimit(1)` + `fixedSize` sono obbligatori: senza, quando la riga di
// comandi non ha spazio SwiftUI comprime le etichette e le manda a capo una
// lettera per riga, rendendole illeggibili in verticale. Meglio che il
// controllo tenga la sua larghezza e sia la riga a doversi riorganizzare.
struct PSESegmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.0) { item in
                let sel = selection == item.0
                Text(item.1)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(sel ? PSE.ink : PSE.dim)
                    .padding(.horizontal, 15).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(sel ? PSE.accent.opacity(0.9) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = item.0 } }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(PSE.line, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }
}

// ── Dashboard ────────────────────────────────────────────────────────────────
struct CamerePSEDashboard: View {
    @State private var items: [Prenotazione] = []
    // Gli ospiti Educamp sono le "prenotazioni" di Via Romagna: camere condivise
    // a letto, quindi stanno in una tabella a parte e nel planning si mostrano
    // per ospite, non per stanza.
    @State private var educampOspiti: [EducampOspite] = []
    // Righe e movimenti Educamp: servono solo a ricalcolare il pagato delle
    // prenotazioni Educamp, che nessuno deve più aggiornare a mano.
    @State private var educampRighe: [EducampRiga] = []
    @State private var movimentiEducamp: [TesMovimento] = []
    @State private var loading = true
    @State private var strutturaFilter: Struttura? = nil
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var monthAnchor = { let c = Calendar.current; return c.date(from: c.dateComponents([.year, .month], from: Date()))! }()
    @State private var selected: Prenotazione? = nil
    @State private var editing: Prenotazione? = nil
    @State private var showForm = false
    @State private var viewMode: PSEViewMode = .prenotazioni
    @State private var newMovimento = false
    /// Esito dell'ultima cancellazione: si mostra in chiaro, perché tocca i conti.
    @State private var messaggio: String? = nil
    // Criteri del motore di ricerca disponibilità.
    @State private var cercaDa = Calendar.current.startOfDay(for: Date())
    @State private var cercaA = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))!
    @State private var cercaOspiti = 2
    @State private var meseRicerca = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    /// Il prossimo click sul calendario è la partenza (dopo aver scelto l'arrivo).
    @State private var scegliePartenza = false

    private var attive: [Prenotazione] { items.filter { BookingStatus.from($0.status).active } }

    // ── date helper ──
    private func day(_ s: String?) -> Date? {
        s.flatMap { ymdBk.date(from: String($0.prefix(10))) }.map { Calendar.current.startOfDay(for: $0) }
    }
    private var dayRange: [Date] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        return (0..<52).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
    private func matchesStruttura(_ b: Prenotazione) -> Bool {
        strutturaFilter == nil || b.struttura == strutturaFilter!.rawValue
    }
    // Prenotazioni attive con le date già convertite: costruita una volta in
    // load(), evita di riparsare le stringhe per ogni card della striscia
    // calendario (52 card × tutte le prenotazioni a ogni render).
    @State private var dayCache: [Assegnata] = []
    private func rebuildDayCache() {
        dayCache = items.compactMap { b in
            guard b.status != "cancellata", let ci = day(b.checkin), let co = day(b.checkout) else { return nil }
            return Assegnata(b: b, ci: ci, co: co)
        }
    }
    // camere occupate quella notte (checkin <= d < checkout)
    private func occupancy(_ d: Date) -> Int {
        dayCache.filter { matchesStruttura($0.b) && $0.ci <= d && d < $0.co }.count
    }
    private var capacity: Int {
        switch strutturaFilter { case .viaPo: return 4; case .viaRomagna: return 5; case nil: return 9 }
    }
    // prenotazioni rilevanti per il giorno (arrivo, in casa, partenza)
    private func bookingsOn(_ d: Date) -> [Prenotazione] {
        dayCache.filter { matchesStruttura($0.b) && $0.ci <= d && d <= $0.co }
            .sorted { ($0.b.checkin ?? "") < ($1.b.checkin ?? "") }
            .map { $0.b }
    }
    private func role(_ b: Prenotazione, _ d: Date) -> (String, Double) {
        if day(b.checkin) == d { return ("Arrivo", 150) }
        if day(b.checkout) == d { return ("Partenza", 30) }
        return ("In casa", 210)
    }

    // ── planning mensile ──
    private var strutture: [Struttura] { strutturaFilter.map { [$0] } ?? Struttura.allCases }
    private var monthDays: [Date] {
        let c = Calendar.current
        guard let r = c.range(of: .day, in: .month, for: monthAnchor) else { return [] }
        return r.compactMap { c.date(byAdding: .day, value: $0 - 1, to: monthAnchor) }
    }
    private func roomsFor(_ s: Struttura) -> [String] { s.rooms.filter { !$0.lowercased().contains("inter") } }
    private func firstName(_ n: String) -> String { n.split(separator: " ").first.map(String.init) ?? n }
    // Prenotazione assegnata a una camera, con le date già convertite una volta
    // sola: così le celle non riparsano le stringhe a ogni confronto.
    private struct Assegnata { let b: Prenotazione; let ci: Date; let co: Date }
    // Cache dell'assegnazione camere: struttura → indice camera → prenotazioni.
    // Ricalcolata solo quando cambiano i dati (in load), NON a ogni cella: prima
    // era un computed var richiamato ~1000 volte per render, con parsing di date
    // ogni volta — la causa principale della lentezza del planning.
    @State private var assignCache: [String: [Int: [Assegnata]]] = [:]

    // Assegna ogni prenotazione attiva a una camera del reticolo, per struttura:
    //  • camera che coincide con una camera specifica → quella camera
    //  • camera "intera/intero" → tutte le camere
    //  • camera generica o mancante (es. richiesta dal sito) → prima camera libera per quelle date (greedy)
    private func rebuildAssignment() {
        var result: [String: [Int: [Assegnata]]] = [:]
        for s in Struttura.allCases {
            let rooms = roomsFor(s)
            var occupied: [[(Date, Date)]] = Array(repeating: [], count: rooms.count)
            var byRoom: [Int: [Assegnata]] = [:]
            func overlaps(_ a: (Date, Date), _ ci: Date, _ co: Date) -> Bool { ci < a.1 && a.0 < co }
            // date convertite una volta qui, poi mai più. Le prenotazioni
            // Educamp (source "educamp") NON entrano nel reticolo per-camera:
            // le camere condivise di Via Romagna si segnano occupate dal foglio
            // Educamp (educampOccupies), e i singoli ospiti stanno nelle righe
            // Educamp del planning.
            let bs = items
                .filter { $0.status != "cancellata" && $0.struttura == s.rawValue && $0.source != "educamp" }
                .compactMap { b -> Assegnata? in
                    guard let ci = day(b.checkin), let co = day(b.checkout), ci < co else { return nil }
                    return Assegnata(b: b, ci: ci, co: co)
                }
                // A parità di arrivo entra prima il soggiorno più lungo (si prende
                // la camera che gli serve davvero), e l'id rompe i pari: senza,
                // l'ordine dipendeva da come tornavano le righe e il planning
                // rimescolava le camere a ogni ricarica.
                .sorted {
                    if $0.ci != $1.ci { return $0.ci < $1.ci }
                    if $0.co != $1.co { return $0.co > $1.co }
                    return $0.b.id < $1.b.id
                }
            for a in bs {
                let cam = (a.b.camera ?? "")
                let exact = rooms.firstIndex(of: cam)
                if cam.lowercased().contains("inter") {                       // intera struttura
                    for i in rooms.indices { occupied[i].append((a.ci, a.co)); byRoom[i, default: []].append(a) }
                } else if let e = exact, !occupied[e].contains(where: { overlaps($0, a.ci, a.co) }) {
                    occupied[e].append((a.ci, a.co)); byRoom[e, default: []].append(a)          // camera esatta se libera
                } else if let free = rooms.indices.first(where: { i in !occupied[i].contains { overlaps($0, a.ci, a.co) } }) {
                    occupied[free].append((a.ci, a.co)); byRoom[free, default: []].append(a)     // altrimenti prima libera
                } else {
                    byRoom[0, default: []].append(a)                          // tutte occupate: overbooking
                }
            }
            result[s.rawValue] = byRoom
        }
        assignCache = result
    }
    // Indice camera nel reticolo, precalcolato per non rifare firstIndex a ogni cella.
    private func roomIndex(_ s: Struttura, _ room: String) -> Int? { roomsFor(s).firstIndex(of: room) }
    // ── Occupazione Educamp delle camere di Via Romagna (dal foglio) ──────────
    // Le camere sono condivise: una stanza è occupata se un ospite Educamp
    // assegnato a quella camera è presente quel giorno. Serve a segnare
    // occupate le stanze anche senza una prenotazione per-camera.
    @State private var educampRoomCache: [String: [(ci: Date, co: Date, nome: String)]] = [:]
    private func educampGridRoom(_ cam: String?) -> String? {
        let c = (cam ?? "").lowercased()
        if c.contains("doppia") { return "Doppia senza bagno" }        // incl. "Camino → Doppia s.b."
        if c.contains("balcone con") { return "Balcone con bagno (ragazzi)" }
        if c.contains("balcone senza") { return "Balcone senza bagno" }
        if c.contains("camino") { return "Stanza Camino" }
        return nil
    }
    private func rebuildEducampRooms() {
        var m: [String: [(ci: Date, co: Date, nome: String)]] = [:]
        for o in educampOspiti {
            guard let room = educampGridRoom(o.camera), let ci = day(o.checkin), let co = day(o.checkout) else { continue }
            m[room, default: []].append((ci, co, firstName(o.ospite)))
        }
        educampRoomCache = m
    }
    private func educampOccupies(_ s: Struttura, _ room: String, _ d: Date) -> Bool {
        guard s == .viaRomagna else { return false }
        return (educampRoomCache[room] ?? []).contains { $0.ci <= d && d < $0.co }
    }
    private func bookingFor(_ s: Struttura, _ room: String, _ d: Date) -> Prenotazione? {
        guard let idx = roomIndex(s, room) else { return nil }
        return (assignCache[s.rawValue]?[idx] ?? []).first { $0.ci <= d && d < $0.co }?.b
    }
    private func freeInGrid(_ s: Struttura, _ d: Date) -> Int {
        roomsFor(s).filter { bookingFor(s, $0, d) == nil && !educampOccupies(s, $0, d) }.count
    }
    private func isToday(_ s: String?) -> Bool { s.map { String($0.prefix(10)) } == ymdBk.string(from: Date()) }
    private var incassato: Int { items.filter { $0.status != "cancellata" }.map { $0.paid_cents }.reduce(0, +) }
    private var daIncassare: Int { attive.map { max(0, $0.amount_cents - $0.paid_cents) }.reduce(0, +) }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if viewMode == .tesoreria {
                    TesoreriaView(prenotazioni: items, newTrigger: $newMovimento)
                } else {
                    strutturaChips
                    if loading {
                        HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 40)
                    } else {
                        // Il planning per primo: è la vista che si guarda entrando,
                        // e cambia col filtro casa qui sopra.
                        planningSection
                        disponibilitaSection
                        kpiBar
                        calendarStrip
                        daySection
                        PrenotazioniTabella(items: items, struttura: strutturaFilter) { b in
                            withAnimation(.easeInOut(duration: 0.2)) { selected = b }
                        }
                        giorniLiberiSection
                    }
                }
                Spacer(minLength: 0)
            }
            .blur(radius: selected != nil ? 2 : 0).disabled(selected != nil)

            if selected != nil {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                BookingDrawer(
                    booking: Binding(get: { selected ?? items.first! }, set: { selected = $0 }),
                    onStatus: { s in Task { await setStatus(selected!, s) } },
                    onPay: { cents in Task { await setPaid(selected!, cents) } },
                    onEdit: { editing = selected; selected = nil; showForm = true },
                    onAnnulla: { stralcia in Task { await annulla(selected!, stralcia: stralcia) } },
                    onDelete: { Task { await remove(selected!) } },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 430).transition(.move(edge: .trailing))
            }
        }
        .task { await load() }
        // La pagina caricava una volta sola all'apertura: le prenotazioni che
        // arrivavano intanto dalle OTA o dal sito non si vedevano finché non si
        // riavviava l'app, e i «giorni liberi per camera» restavano fermi.
        // Adesso si ricarica quando si torna sulla finestra e ogni cinque minuti,
        // in silenzio.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load(primoAvvio: false) }
        }
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
            Task { await load(primoAvvio: false) }
        }
        // Il grafico guarda il mese mostrato e la struttura filtrata: se cambiano,
        // i suoi dati vanno rifatti (le celle invece si ricalcolano da sole).
        .onChange(of: monthAnchor) { _, _ in rebuildStats() }
        .onChange(of: strutturaFilter) { _, _ in rebuildStats() }
        .sheet(isPresented: $showForm, onDismiss: { editing = nil }) {
            BookingForm(existing: editing) { await syncAndReload() }
        }
        .alert("Prenotazione cancellata", isPresented: Binding(get: { messaggio != nil }, set: { if !$0 { messaggio = nil } })) {
            Button("Ho capito") { messaggio = nil }
        } message: {
            Text(messaggio ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PSESegmented(items: [(PSEViewMode.prenotazioni, "Prenotazioni"), (PSEViewMode.tesoreria, "Tesoreria")], selection: $viewMode)
            Spacer()
            Button {
                if viewMode == .prenotazioni { editing = nil; showForm = true } else { newMovimento = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text(viewMode == .prenotazioni ? "Nuova prenotazione" : "Nuovo movimento").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(PSE.ink).padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(PSE.warn.opacity(0.95)))
            }.buttonStyle(.plain)
        }
    }

    private var kpiBar: some View {
        HStack(spacing: 12) {
            kpi("IN CASA", "\(items.filter { $0.status == "in_casa" }.count)")
            kpi("CHECK-IN OGGI", "\(attive.filter { isToday($0.checkin) }.count)")
            // Il check-out di oggi è l'informazione operativa del mattino: dice
            // quante camere si liberano e quante pulizie ci sono da fare.
            kpi("CHECK-OUT OGGI", "\(attive.filter { isToday($0.checkout) }.count)")
            kpi("INCASSATO", eur(incassato))
            kpi("DA INCASSARE", eur(daIncassare))
        }
    }
    private func kpi(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    private var strutturaChips: some View {
        HStack {
            PSESegmented(items: [(nil, "Tutte"), (.viaPo, "Via Po"), (.viaRomagna, "Via Romagna")] as [(Struttura?, String)], selection: $strutturaFilter)
            Spacer()
        }
    }

    // ── barra calendario scorrevole ──
    private var calendarStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(dayRange, id: \.self) { d in dayCard(d) }
                }
                .padding(.vertical, 2).padding(.horizontal, 1)
            }
            .onAppear { proxy.scrollTo(Calendar.current.startOfDay(for: Date()), anchor: .leading) }
        }
    }
    private func dayCard(_ d: Date) -> some View {
        let occ = occupancy(d)
        let isSel = Calendar.current.isDate(d, inSameDayAs: selectedDay)
        let isToday = Calendar.current.isDateInToday(d)
        let frac = capacity > 0 ? min(1, CGFloat(occ) / CGFloat(capacity)) : 0
        return Button { withAnimation(.easeOut(duration: 0.15)) { selectedDay = d } } label: {
            VStack(spacing: 4) {
                Text(wdFmt.string(from: d).uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(isSel ? PSE.ink : PSE.faint)
                Text(dNumFmt.string(from: d)).font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSel ? PSE.ink : PSE.text).monospacedDigit()
                Text(moFmt.string(from: d).uppercased()).font(.system(size: 7.5, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(PSE.faint)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(PSE.accent.opacity(0.85)).frame(width: g.size.width * frac)
                    }
                }.frame(height: 3)
                Text(occ > 0 ? "\(occ)/\(capacity)" : "libero").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(occ > 0 ? PSE.dim : PSE.faint.opacity(0.7))
            }
            .frame(width: 58)
            .padding(.vertical, 9).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSel ? PSE.accent.opacity(0.16) : PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                isSel ? PSE.accent.opacity(0.7) : (isToday ? PSE.accent.opacity(0.45) : PSE.line),
                lineWidth: (isSel || isToday) ? 1.2 : 1))
        }
        .buttonStyle(.plain)
        .id(d)
    }

    // ── prenotazioni del giorno selezionato ──
    private var daySection: some View {
        let list = bookingsOn(selectedDay)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(fullFmt.string(from: selectedDay).capitalized).font(.system(size: 13.5, weight: .bold)).foregroundStyle(PSE.ink)
                Text("· \(list.count) prenotazioni").font(.system(size: 11)).foregroundStyle(PSE.faint)
                Spacer()
                if Calendar.current.isDateInToday(selectedDay) == false {
                    Button("Oggi") { withAnimation { selectedDay = Calendar.current.startOfDay(for: Date()) } }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.accent)
                }
            }
            if list.isEmpty {
                EmptyStateCard(icon: "moon.zzz", text: "Nessuna prenotazione per questo giorno.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                        dayRow(b, selectedDay)
                        if i < list.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    private func dayRow(_ b: Prenotazione, _ d: Date) -> some View {
        let st = BookingStatus.from(b.status)
        let toConfirm = st == .in_attesa
        let str = Struttura.from(b.struttura)
        let pay = payState(amount: b.amount_cents, paid: b.paid_cents)
        let (roleLabel, _) = role(b, d)
        return Button { withAnimation(.easeInOut(duration: 0.2)) { selected = b } } label: {
            HStack(spacing: 14) {
                // ruolo del giorno (arrivo/in casa/partenza)
                Text(roleLabel.uppercased()).font(.system(size: 8, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(PSE.dim).frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.guest_name).font(.system(size: 13, weight: .semibold)).foregroundStyle(PSE.ink).lineLimit(1)
                    Text([str.label, b.camera].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(PSE.dim).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(prettyDate(b.checkin)) → \(prettyDate(b.checkout))")
                    .font(.system(size: 10.5)).foregroundStyle(PSE.faint).frame(width: 170, alignment: .leading)
                Text(eur(b.amount_cents)).font(.system(size: 13, weight: .bold)).foregroundStyle(PSE.text)
                    .monospacedDigit().frame(width: 70, alignment: .trailing)
                dot(pay.label, PSE.payment(pay))
                statusBadge(st).frame(width: 132, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(toConfirm ? PSE.warn.opacity(0.09) : Color.clear)
            .overlay(alignment: .leading) { Rectangle().fill(toConfirm ? PSE.warn : Color.clear).frame(width: 3) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    // badge sobrio: pallino tinta desaturata + testo neutro
    private func dot(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(.system(size: 10.5, weight: .medium)).foregroundStyle(PSE.text).lineLimit(1)
        }
    }
    // badge stato ben visibile: pill piena; "in attesa" (da confermare) in arancio, con enfasi
    private func statusBadge(_ st: BookingStatus) -> some View {
        let toConfirm = st == .in_attesa
        let c = toConfirm ? PSE.warn : PSE.status(st)
        return HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(st.label).font(.system(size: 11, weight: toConfirm ? .bold : .semibold)).foregroundStyle(c).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4.5)
        .background(Capsule().fill(c.opacity(toConfirm ? 0.20 : 0.13)))
        .overlay(Capsule().strokeBorder(c.opacity(toConfirm ? 0.65 : 0.28), lineWidth: 1))
    }

    // ── planning mensile: camere (righe) × giorni (colonne) ──
    // Le prenotazioni si disegnano come barre continue sopra il reticolo, non
    // come celle ripetute: il nome si legge una volta sola e a colpo d'occhio si
    // vede dove comincia e dove finisce ogni soggiorno.
    private enum GRow: Hashable {
        case header, title(Struttura), room(Struttura, String), free(Struttura)
    }
    private var gridRows: [GRow] {
        var r: [GRow] = [.header]
        for s in strutture {
            r.append(.title(s))
            for rm in roomsFor(s) { r.append(.room(s, rm)) }
            r.append(.free(s))
        }
        return r
    }
    private var rowH: CGFloat { 29 }
    private var labelW: CGFloat { 208 }
    // Larghezza colonna: si adatta alla finestra così il mese ci sta tutto senza
    // scorrere (entro limiti leggibili). La aggiorna adattaDayW().
    @State private var dayW: CGFloat = 34
    private var gridW: CGFloat { CGFloat(monthDays.count) * dayW }
    private func adattaDayW(_ total: CGFloat) {
        let n = CGFloat(max(1, monthDays.count))
        let w = min(48, max(30, ((total - labelW - 2) / n).rounded(.down)))
        if abs(w - dayW) > 0.5 { dayW = w }
    }
    private var gLine: Color { Color.white.opacity(0.055) }
    // Tinte per canale: colore solo dove c'è qualcuno. Le celle libere restano
    // vuote (prima erano verdine e facevano rumore), così l'occupato risalta.
    private func sourceColor(_ s: String?) -> Color {
        switch s {
        case "booking": return Color(hue: 42/360,  saturation: 0.62, brightness: 0.80)
        case "airbnb":  return Color(hue: 8/360,   saturation: 0.58, brightness: 0.78)
        default:        return Color(hue: 206/360, saturation: 0.52, brightness: 0.80)
        }
    }
    private var educampColor: Color { Color(hue: 168/360, saturation: 0.46, brightness: 0.72) }
    private func strutturaColor(_ s: Struttura) -> Color {
        Color(hue: s.hue/360, saturation: 0.42, brightness: 0.74)
    }
    private func isWeekend(_ d: Date) -> Bool { Calendar.current.isDateInWeekend(d) }
    /// Sfondo della colonna: giorno selezionato > oggi > weekend > niente.
    private func colonnaTint(_ d: Date) -> Color {
        let c = Calendar.current
        if c.isDate(d, inSameDayAs: selectedDay) { return PSE.accent.opacity(0.20) }
        if c.isDateInToday(d) { return PSE.accent.opacity(0.10) }
        return isWeekend(d) ? Color.white.opacity(0.030) : Color.clear
    }

    // ── barre del planning ───────────────────────────────────────────────────
    private struct Segmento: Identifiable {
        let id: String
        let start: Int, len: Int
        let color: Color
        let label: String
        let booking: Prenotazione?
        let apertoPrima: Bool, apertoDopo: Bool
        /// Testo del tooltip quando la barra non è una prenotazione (Educamp).
        var nota: String? = nil
        // Due soggiorni nella stessa camera e negli stessi giorni esistono
        // davvero (doppia prenotazione, o camera sbagliata arrivata dall'OTA):
        // si dividono la riga in corsie invece di coprirsi a vicenda.
        var corsia = 0, corsie = 1
        /// Solo i soggiorni che si accavallano davvero, non tutta la riga.
        var conflitto = false
        var fine: Int { start + len }
    }
    /// Soggiorni della camera intersecati col mese mostrato, come segmenti di
    /// colonne contigue (start = indice del primo giorno, len = notti visibili).
    private func segmenti(_ s: Struttura, _ rm: String) -> [Segmento] {
        let days = monthDays
        guard let first = days.first, let idx = roomIndex(s, rm) else { return [] }
        let cal = Calendar.current, n = days.count
        var out: [Segmento] = []
        var occupato = [Bool](repeating: false, count: n)
        for a in (assignCache[s.rawValue]?[idx] ?? []) {
            let s0 = cal.dateComponents([.day], from: first, to: a.ci).day ?? 0
            let e0 = cal.dateComponents([.day], from: first, to: a.co).day ?? 0
            let a0 = max(0, s0), b0 = min(n, e0)
            guard b0 > a0 else { continue }
            for i in a0..<b0 { occupato[i] = true }
            out.append(Segmento(id: a.b.id, start: a0, len: b0 - a0, color: sourceColor(a.b.source),
                                label: firstName(a.b.guest_name), booking: a.b,
                                apertoPrima: s0 < 0, apertoDopo: e0 > n))
        }
        // Camere condivise Educamp: una barra sola con quante persone ci sono
        // dentro, invece di una riga per ospite (erano venti righe di rumore).
        if s == .viaRomagna, let occ = educampRoomCache[rm], !occ.isEmpty {
            // Chi c'è dentro, giorno per giorno. La barra si spezza quando la
            // compagnia cambia: se no una doppia con un ricambio il 29 direbbe
            // «Educamp · 4» per tutto il mese, e nella stanza sono in due.
            let perGiorno: [[String]] = days.enumerated().map { (i, d) in
                occupato[i] ? [] : occ.filter { $0.ci <= d && d < $0.co }.map { $0.nome }.sorted()
            }
            var i = 0
            while i < n {
                guard !perGiorno[i].isEmpty else { i += 1; continue }
                var j = i
                while j + 1 < n && perGiorno[j + 1] == perGiorno[i] { j += 1 }
                let nomi = perGiorno[i]
                out.append(Segmento(id: "edu|\(rm)|\(i)", start: i, len: j - i + 1, color: educampColor,
                                    label: nomi.count <= 2 ? nomi.joined(separator: " · ") : "Educamp · \(nomi.count)",
                                    booking: nil, apertoPrima: false, apertoDopo: false,
                                    nota: "Educamp · \(nomi.count) in camera: " + nomi.joined(separator: ", ")))
                i = j + 1
            }
        }
        return inCorsie(out)
    }
    /// Distribuisce i segmenti sovrapposti su più corsie (la prima libera, come
    /// un calendario): così una doppia prenotazione si vede tutta invece di
    /// sparire sotto l'altra barra.
    private func inCorsie(_ segs: [Segmento]) -> [Segmento] {
        var out = segs.sorted { ($0.start, $0.len) < ($1.start, $1.len) }
        var ultima: [Int] = []                     // ultima colonna occupata per corsia
        for i in out.indices {
            let c = ultima.firstIndex { $0 <= out[i].start } ?? ultima.count
            if c == ultima.count { ultima.append(0) }
            ultima[c] = out[i].fine
            out[i].corsia = c
        }
        let n = max(1, ultima.count)
        for i in out.indices {
            out[i].corsie = n
            // il bordo rosso va su chi si accavalla, non su tutta la riga
            out[i].conflitto = out.indices.contains { j in
                j != i && out[j].start < out[i].fine && out[i].start < out[j].fine
            }
        }
        return out
    }

    private var planningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("PLANNING · \(fmt("MMMM yyyy").string(from: monthAnchor).uppercased())")
                    .font(.system(size: 13.5, weight: .bold)).foregroundStyle(PSE.ink)
                Spacer()
                HStack(spacing: 12) {
                    legendItem(sourceColor(nil), "Diretta"); legendItem(sourceColor("booking"), "Booking")
                    legendItem(sourceColor("airbnb"), "Airbnb")
                    if strutture.contains(.viaRomagna) { legendItem(educampColor, "Educamp") }
                }
                Button { withAnimation(.easeOut(duration: 0.15)) { andaAOggi() } } label: {
                    Text("Oggi").font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.dim)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(PSE.surface))
                        .overlay(Capsule().strokeBorder(PSE.line, lineWidth: 1))
                }.buttonStyle(.plain)
                HStack(spacing: 8) {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(PSE.dim)
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundStyle(PSE.dim)
                }.font(.system(size: 12, weight: .bold))
            }
            // Grafico e reticolo condividono la stessa griglia di colonne: la
            // barra del giorno sta esattamente sopra la sua colonna di camere.
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    chartGutter
                    ForEach(gridRows, id: \.self) { leftCell($0) }
                }
                .frame(width: labelW)
                .overlay(Rectangle().fill(PSE.line).frame(width: 1), alignment: .trailing)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        chartRow
                        ForEach(gridRows, id: \.self) { gridRow($0) }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { adattaDayW(g.size.width) }
                    .onChange(of: g.size.width) { _, w in adattaDayW(w) }
            })
        }
    }
    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5).fill(c.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(c.opacity(0.6), lineWidth: 1))
                .frame(width: 14, height: 10)
            Text(t).font(.system(size: 10)).foregroundStyle(PSE.faint)
        }
    }
    private func andaAOggi() {
        let c = Calendar.current
        selectedDay = c.startOfDay(for: Date())
        monthAnchor = c.date(from: c.dateComponents([.year, .month], from: Date())) ?? monthAnchor
        rebuildStats()
    }

    // ── grafico occupazione interattivo ──────────────────────────────────────
    // Passando col mouse su una barra il pannello a sinistra racconta il giorno;
    // cliccandola si seleziona il giorno (evidenzia la colonna del reticolo e
    // aggiorna l'elenco prenotazioni qui sopra).
    private enum PSEMetric: Hashable { case camere, ricavi }
    private struct PSEDayStat: Identifiable {
        let id: Int              // giorno del mese
        let date: Date
        let occ: Int, cap: Int, occPo: Int, occRo: Int
        let ricavo: Int          // centesimi, quota per notte delle prenotazioni in corso
        let arrivi: Int, partenze: Int
        var frac: Double { cap > 0 ? Double(occ) / Double(cap) : 0 }
    }
    @State private var chartMetric: PSEMetric = .camere
    @State private var hoverDay: Int? = nil
    @State private var stats: [PSEDayStat] = []
    private var chartH: CGFloat { 104 }
    // altezza utile delle barre: tolti padding, etichetta del valore e pallino
    // "tutto pieno" che stanno sopra la barra.
    private var plotH: CGFloat { chartH - 31 }

    private func rebuildStats() {
        let cal = Calendar.current
        stats = monthDays.enumerated().map { (_, d) in
            var po = 0, ro = 0, cap = 0
            for s in strutture {
                let rooms = roomsFor(s)
                cap += rooms.count
                let n = rooms.filter { bookingFor(s, $0, d) != nil || educampOccupies(s, $0, d) }.count
                if s == .viaPo { po = n } else { ro = n }
            }
            var ric = 0, arr = 0, par = 0
            for a in dayCache where matchesStruttura(a.b) {
                if a.ci <= d && d < a.co {
                    let notti = max(1, cal.dateComponents([.day], from: a.ci, to: a.co).day ?? 1)
                    ric += a.b.amount_cents / notti
                }
                if a.ci == d { arr += 1 }
                if a.co == d { par += 1 }
            }
            return PSEDayStat(id: cal.component(.day, from: d), date: d, occ: po + ro, cap: cap,
                              occPo: po, occRo: ro, ricavo: ric, arrivi: arr, partenze: par)
        }
    }
    private var mediaFrac: Double {
        guard !stats.isEmpty else { return 0 }
        return stats.map(\.frac).reduce(0, +) / Double(stats.count)
    }

    private var chartGutter: some View {
        let hovered = hoverDay.flatMap { id in stats.first { $0.id == id } }
        let sel = stats.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) }
        let mostrato = hovered ?? sel
        return VStack(alignment: .leading, spacing: 3) {
            Text(chartMetric == .camere ? "OCCUPAZIONE" : "RICAVI PER NOTTE")
                .font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
            if let g = mostrato {
                Text(fmt("EEEE d").string(from: g.date).capitalized)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(g.occ)/\(g.cap)").font(.system(size: 17, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                    Text("camere · \(Int((g.frac * 100).rounded()))%").font(.system(size: 10)).foregroundStyle(PSE.dim)
                }
                Text("\(eur(g.ricavo)) · \(g.arrivi) arrivi · \(g.partenze) partenze")
                    .font(.system(size: 10)).foregroundStyle(PSE.faint).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int((mediaFrac * 100).rounded()))%").font(.system(size: 20, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                    Text("media del mese").font(.system(size: 10)).foregroundStyle(PSE.dim)
                }
                Text("\(stats.reduce(0) { $0 + $1.occ }) notti vendute · \(eur(stats.reduce(0) { $0 + $1.ricavo }))")
                    .font(.system(size: 10)).foregroundStyle(PSE.faint).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                metricPill("Camere", .camere); metricPill("Ricavi", .ricavi)
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 9)
        .frame(width: labelW, height: chartH, alignment: .topLeading)
        .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
    }
    private func metricPill(_ t: String, _ m: PSEMetric) -> some View {
        let on = chartMetric == m
        return Text(t).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(on ? PSE.ink : PSE.faint)
            .padding(.horizontal, 9).padding(.vertical, 3.5)
            .background(Capsule().fill(on ? PSE.accent.opacity(0.85) : PSE.surface))
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { chartMetric = m } }
    }

    private var chartRow: some View {
        let maxRic = max(1, stats.map(\.ricavo).max() ?? 1)
        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) { ForEach(stats) { st in chartColumn(st, maxRic) } }
            if chartMetric == .camere && mediaFrac > 0.02 {
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: gridW, y: 0)) }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(PSE.accent.opacity(0.5))
                    .frame(width: gridW, height: 1)
                    .offset(y: -(plotH * CGFloat(mediaFrac) + 7))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: gridW, height: chartH, alignment: .bottomLeading)
        .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
    }
    private func chartColumn(_ st: PSEDayStat, _ maxRic: Int) -> some View {
        let hov = hoverDay == st.id
        let selezionato = Calendar.current.isDate(st.date, inSameDayAs: selectedDay)
        let pieno = st.cap > 0 && st.occ >= st.cap
        let hPo = plotH * CGFloat(st.cap > 0 ? Double(st.occPo) / Double(st.cap) : 0)
        let hRo = plotH * CGFloat(st.cap > 0 ? Double(st.occRo) / Double(st.cap) : 0)
        let hRic = plotH * CGFloat(min(1, Double(st.ricavo) / Double(maxRic)))
        let barW = max(6, dayW - 9)
        return VStack(spacing: 0) {
            Text(hov || selezionato ? (chartMetric == .camere ? "\(st.occ)" : eur(st.ricavo)) : " ")
                .font(.system(size: 8.5, weight: .bold)).monospacedDigit().foregroundStyle(PSE.ink)
                .lineLimit(1).minimumScaleFactor(0.55).frame(height: 11)
            Circle().fill(pieno ? PSE.warn : Color.clear).frame(width: 4, height: 4).padding(.bottom, 2)
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                if chartMetric == .camere {
                    if hRo > 0.5 { Rectangle().fill(strutturaColor(.viaRomagna).opacity(hov ? 1 : 0.8)).frame(height: hRo) }
                    if hPo > 0.5 { Rectangle().fill(strutturaColor(.viaPo).opacity(hov ? 1 : 0.8)).frame(height: hPo) }
                } else if hRic > 0.5 {
                    Rectangle().fill(PSE.pos.opacity(hov ? 1 : 0.75)).frame(height: hRic)
                }
            }
            .frame(width: barW)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.vertical, 7)
        .frame(width: dayW, height: chartH)
        .background(colonnaTint(st.date))
        .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { inside in hoverDay = inside ? st.id : (hoverDay == st.id ? nil : hoverDay) }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selectedDay = st.date } }
    }

    // ── Riepilogo giorni liberi per camera ──────────────────────────────────
    // Il planning dice giorno per giorno chi c'è; questo dice il contrario, cioè
    // dove si può ancora vendere. Stesse assegnazioni del reticolo, così le due
    // viste non possono discordare. Mese mostrato + il successivo.
    // ══ DISPONIBILITÀ ════════════════════════════════════════════════════════
    // «C'è posto?» al telefono era una domanda a cui si rispondeva leggendo il
    // reticolo e contando le colonne. Qui c'è la risposta diretta: cosa è libero
    // stanotte, e cosa è libero per le date che chiede il cliente.

    /// Posti letto per camera. Non si possono dedurre dallo storico (le righe
    /// Educamp hanno un ospite per letto e falsano il massimo), quindi stanno
    /// scritti qui e si vedono in chiaro nella sezione: se un numero è sbagliato
    /// si corregge in una riga.
    private func posti(_ camera: String) -> Int {
        switch camera {
        case "Stanza 1 · Camera Queen": return 2
        case "Stanza 2 · Standard": return 2
        case "Stanza 3 · Camera King": return 3
        case "Stanza 4 · Ampia Matrimoniale": return 3
        case "Doppia senza bagno": return 2
        case "Balcone senza bagno": return 3
        case "Stanza Camino": return 3
        case "Balcone con bagno (ragazzi)": return 3
        case "Mansarda": return 4
        default: return 2
        }
    }
    /// Libera tutte le notti da `da` (compresa) fino alla notte prima di `a`.
    private func liberaTra(_ s: Struttura, _ rm: String, _ da: Date, _ a: Date) -> Bool {
        let c = Calendar.current
        var d = c.startOfDay(for: da)
        let fine = c.startOfDay(for: a)
        while d < fine {
            if bookingFor(s, rm, d) != nil || educampOccupies(s, rm, d) { return false }
            guard let n = c.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return true
    }
    /// Prima notte occupata a partire da `da`: dice fino a quando si può tenere
    /// libera la camera, che è la seconda domanda dopo «è libera?».
    private func liberaFinoA(_ s: Struttura, _ rm: String, da: Date) -> Date? {
        let c = Calendar.current
        var d = c.startOfDay(for: da)
        for _ in 0..<400 {
            guard let n = c.date(byAdding: .day, value: 1, to: d) else { return nil }
            if bookingFor(s, rm, n) != nil || educampOccupies(s, rm, n) { return n }
            d = n
        }
        return nil
    }
    private struct CameraLibera: Identifiable {
        let id: String
        let struttura: Struttura, camera: String
        let posti: Int
        let fino: Date?          // prima notte occupata (nil = nessun limite in vista)
    }
    private func libereOggi() -> [CameraLibera] {
        let oggi = Calendar.current.startOfDay(for: Date())
        return strutture.flatMap { s in
            roomsFor(s).compactMap { rm -> CameraLibera? in
                guard bookingFor(s, rm, oggi) == nil, !educampOccupies(s, rm, oggi) else { return nil }
                return CameraLibera(id: "\(s.rawValue)|\(rm)", struttura: s, camera: rm,
                                    posti: posti(rm), fino: liberaFinoA(s, rm, da: oggi))
            }
        }
    }
    /// La partenza non può essere prima dell'arrivo: se lo diventa si sposta al
    /// giorno dopo, e si mostra quella — se no la riga in testa dice «28 → 28».
    private var partenzaEffettiva: Date {
        let c = Calendar.current
        let da = c.startOfDay(for: cercaDa)
        return max(c.startOfDay(for: cercaA), c.date(byAdding: .day, value: 1, to: da) ?? cercaA)
    }
    private func cerca() -> [CameraLibera] {
        let da = Calendar.current.startOfDay(for: cercaDa)
        let a = partenzaEffettiva
        return strutture.flatMap { s in
            roomsFor(s).compactMap { rm -> CameraLibera? in
                guard posti(rm) >= cercaOspiti, liberaTra(s, rm, da, a) else { return nil }
                return CameraLibera(id: "\(s.rawValue)|\(rm)", struttura: s, camera: rm,
                                    posti: posti(rm), fino: liberaFinoA(s, rm, da: da))
            }
        }
    }
    private var nottiCercate: Int {
        let c = Calendar.current
        return max(1, c.dateComponents([.day], from: c.startOfDay(for: cercaDa),
                                       to: partenzaEffettiva).day ?? 1)
    }
    private func plur(_ n: Int, _ uno: String, _ tanti: String) -> String {
        "\(n) \(n == 1 ? uno : tanti)"
    }

    private var disponibilitaSection: some View {
        let oggi = libereOggi()
        let trovate = cerca()
        return VStack(alignment: .leading, spacing: 10) {
            PSEPieghevole("STANZE DISPONIBILI OGGI",
                          valore: oggi.isEmpty ? "tutto pieno" : "\(oggi.count) libere",
                          colore: PSE.ink, coloreValore: oggi.isEmpty ? PSE.warn : PSE.pos,
                          nota: fullFmt.string(from: Date()).capitalized) {
                if oggi.isEmpty {
                    Text("Stanotte non c'è nessuna camera libera in \(strutture.count == 1 ? strutture[0].label : "nessuna delle due case").")
                        .font(.system(size: 11.5)).foregroundStyle(PSE.dim)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                } else {
                    elencoCamere(oggi, da: Calendar.current.startOfDay(for: Date()))
                }
            }
            ricercaBlocco(trovate)
        }
    }

    private func ricercaBlocco(_ trovate: [CameraLibera]) -> some View {
        PSEPieghevole("CERCA DISPONIBILITÀ",
                      valore: trovate.isEmpty ? "niente per queste date" : plur(trovate.count, "camera", "camere"),
                      colore: PSE.accent, coloreValore: trovate.isEmpty ? PSE.warn : PSE.pos,
                      nota: "\(prettyDate(ymdBk.string(from: cercaDa))) → \(prettyDate(ymdBk.string(from: partenzaEffettiva))) · \(plur(nottiCercate, "notte", "notti")) · \(plur(cercaOspiti, "ospite", "ospiti"))") {
            // Calendario a sinistra, risultati a destra: si sceglie e si vede
            // l'effetto senza spostare gli occhi.
            HStack(alignment: .top, spacing: 18) {
                calendarioRicerca.frame(width: 292)
                VStack(alignment: .leading, spacing: 10) {
                    criteriRicerca
                    if trovate.isEmpty {
                        Text("Per queste date e \(plur(cercaOspiti, "ospite", "ospiti")) non c'è nessuna camera libera per tutto il soggiorno. Nel calendario i giorni in arancio sono pieni: sposta l'arrivo su un giorno verde.")
                            .font(.system(size: 11.5)).foregroundStyle(PSE.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        elencoCamereCompatto(trovate)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }

    // ── Criteri: ospiti, notti e scorciatoie ─────────────────────────────────
    private var criteriRicerca: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("OSPITI").font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                HStack(spacing: 0) {
                    passo("minus") { if cercaOspiti > 1 { cercaOspiti -= 1 } }
                    Text("\(cercaOspiti)").font(.system(size: 14, weight: .bold)).foregroundStyle(PSE.ink)
                        .monospacedDigit().frame(width: 30)
                    passo("plus") { if cercaOspiti < 6 { cercaOspiti += 1 } }
                }
                .background(Capsule().fill(PSE.surface))
                .overlay(Capsule().strokeBorder(PSE.line, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("NOTTI").font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                HStack(spacing: 0) {
                    passo("minus") { if nottiCercate > 1 { cercaA = Calendar.current.date(byAdding: .day, value: -1, to: partenzaEffettiva) ?? cercaA } }
                    Text("\(nottiCercate)").font(.system(size: 14, weight: .bold)).foregroundStyle(PSE.ink)
                        .monospacedDigit().frame(width: 30)
                    passo("plus") { cercaA = Calendar.current.date(byAdding: .day, value: 1, to: partenzaEffettiva) ?? cercaA }
                }
                .background(Capsule().fill(PSE.surface))
                .overlay(Capsule().strokeBorder(PSE.line, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("SCORCIATOIE").font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                HStack(spacing: 6) {
                    scorciatoia("Stanotte") { imposta(giorniDaOggi: 0, notti: 1) }
                    scorciatoia("Domani") { imposta(giorniDaOggi: 1, notti: 1) }
                    scorciatoia("Weekend") { prossimoWeekend() }
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func passo(_ icona: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Image(systemName: icona).font(.system(size: 9, weight: .black)).foregroundStyle(PSE.dim)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func scorciatoia(_ t: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.12)) { azione() } }) {
            Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PSE.dim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(PSE.surface))
                .overlay(Capsule().strokeBorder(PSE.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func imposta(giorniDaOggi: Int, notti: Int) {
        let c = Calendar.current
        let da = c.date(byAdding: .day, value: giorniDaOggi, to: c.startOfDay(for: Date())) ?? Date()
        cercaDa = da
        cercaA = c.date(byAdding: .day, value: notti, to: da) ?? da
        meseRicerca = primoDelMese(da)
        scegliePartenza = false
    }
    /// Venerdì → domenica della settimana in corso, o della prossima se è passato.
    private func prossimoWeekend() {
        let c = Calendar.current
        var d = c.startOfDay(for: Date())
        for _ in 0..<8 {
            if c.component(.weekday, from: d) == 6 { break }      // 6 = venerdì
            d = c.date(byAdding: .day, value: 1, to: d) ?? d
        }
        cercaDa = d
        cercaA = c.date(byAdding: .day, value: 2, to: d) ?? d
        meseRicerca = primoDelMese(d)
        scegliePartenza = false
    }

    // ── Calendario della ricerca ─────────────────────────────────────────────
    // Non è un date picker: ogni giorno dice quante camere restano libere quella
    // notte (per il numero di ospiti chiesto). Così le date non si scelgono alla
    // cieca — si vede subito dov'è il buco.
    private func primoDelMese(_ d: Date) -> Date {
        let c = Calendar.current
        return c.date(from: c.dateComponents([.year, .month], from: d)) ?? d
    }
    private func libereNotte(_ d: Date) -> Int {
        strutture.reduce(0) { tot, s in
            tot + roomsFor(s).filter {
                posti($0) >= cercaOspiti && bookingFor(s, $0, d) == nil && !educampOccupies(s, $0, d)
            }.count
        }
    }
    private var giorniDelMese: [Date?] {
        let c = Calendar.current
        guard let range = c.range(of: .day, in: .month, for: meseRicerca) else { return [] }
        // Lunedì primo: weekday 1 = domenica, quindi si sposta di due.
        let primo = primoDelMese(meseRicerca)
        let vuoti = (c.component(.weekday, from: primo) + 5) % 7
        return Array(repeating: nil, count: vuoti)
            + range.map { c.date(byAdding: .day, value: $0 - 1, to: primo) }
    }
    private func tocca(_ d: Date) {
        let c = Calendar.current
        if !scegliePartenza || d <= c.startOfDay(for: cercaDa) {
            cercaDa = d
            cercaA = c.date(byAdding: .day, value: 1, to: d) ?? d
            scegliePartenza = true
        } else {
            cercaA = d
            scegliePartenza = false
        }
    }
    private var calendarioRicerca: some View {
        let c = Calendar.current
        let da = c.startOfDay(for: cercaDa), a = partenzaEffettiva
        return VStack(spacing: 8) {
            HStack {
                Button { meseRicerca = c.date(byAdding: .month, value: -1, to: meseRicerca) ?? meseRicerca } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                Text(fmt("MMMM yyyy").string(from: meseRicerca).capitalized)
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.ink)
                Spacer()
                Button { meseRicerca = c.date(byAdding: .month, value: 1, to: meseRicerca) ?? meseRicerca } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack(spacing: 2) {
                ForEach(["L", "M", "M", "G", "V", "S", "D"], id: \.self) { g in
                    Text(g).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(PSE.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(giorniDelMese.enumerated()), id: \.offset) { _, giorno in
                    if let d = giorno { cellaCalendario(d, da: da, a: a) } else { Color.clear.frame(height: 32) }
                }
            }
            Text(scegliePartenza ? "Ora clicca la partenza" : "Clicca l'arrivo, poi la partenza")
                .font(.system(size: 10)).foregroundStyle(scegliePartenza ? PSE.accent : PSE.faint)
            HStack(spacing: 10) {
                legendaCal(PSE.pos, "libere")
                legendaCal(PSE.warn, "pieno")
                legendaCal(PSE.accent, "soggiorno")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func legendaCal(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(t).font(.system(size: 9)).foregroundStyle(PSE.faint)
        }
    }
    private func cellaCalendario(_ d: Date, da: Date, a: Date) -> some View {
        let c = Calendar.current
        let libere = libereNotte(d)
        let passato = d < c.startOfDay(for: Date())
        let arrivo = c.isDate(d, inSameDayAs: da)
        let partenza = c.isDate(d, inSameDayAs: a)
        let dentro = d > da && d < a
        let oggi = c.isDateInToday(d)
        return Button { tocca(d) } label: {
            VStack(spacing: 1) {
                Text("\(c.component(.day, from: d))")
                    .font(.system(size: 11.5, weight: arrivo || partenza ? .bold : .medium))
                    .foregroundStyle(arrivo || partenza ? PSE.ink : (passato ? PSE.faint.opacity(0.6) : PSE.text))
                    .monospacedDigit()
                // Il numerino sotto è la sostanza: quante camere restano quella
                // notte per il numero di ospiti chiesto.
                Text(passato ? " " : "\(libere)")
                    .font(.system(size: 8, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(libere == 0 ? PSE.warn : PSE.pos.opacity(0.9))
            }
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(arrivo || partenza ? PSE.accent.opacity(0.85)
                          : dentro ? PSE.accent.opacity(0.20)
                          : (libere == 0 && !passato ? PSE.warn.opacity(0.12) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(oggi ? PSE.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(passato ? "Giorno passato"
              : libere == 0 ? "Nessuna camera libera per \(plur(cercaOspiti, "ospite", "ospiti"))"
              : "\(plur(libere, "camera libera", "camere libere")) per \(plur(cercaOspiti, "ospite", "ospiti"))")
    }
    /// Risultati in colonna stretta: casa, camera, posti e fin quando è libera.
    private func elencoCamereCompatto(_ righe: [CameraLibera]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(righe.enumerated()), id: \.element.id) { i, r in
                Button { editing = nil; showForm = true } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(strutturaColor(r.struttura))
                            .frame(width: 3, height: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.camera).font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(PSE.ink).lineLimit(1)
                            Text("\(r.struttura.label) · fino a \(plur(r.posti, "ospite", "ospiti"))")
                                .font(.system(size: 10)).foregroundStyle(PSE.faint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let f = r.fino {
                            let n = Calendar.current.dateComponents([.day], from: partenzaEffettiva, to: f).day ?? 0
                            Text(n > 0 ? "si può allungare di \(plur(n, "notte", "notti"))" : "poi occupata")
                                .font(.system(size: 10)).foregroundStyle(PSE.dim).lineLimit(1)
                        } else {
                            Text("nessun limite in vista").font(.system(size: 10)).foregroundStyle(PSE.pos.opacity(0.85))
                        }
                        Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(PSE.warn)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clicca per aprire una nuova prenotazione")
                if i < righe.count - 1 { Divider().overlay(PSE.line) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
    }
    /// Elenco camere libere: casa, camera, posti e fin quando resta libera.
    /// Cliccando si apre la nuova prenotazione, che è quello che si fa dopo.
    private func elencoCamere(_ righe: [CameraLibera], da: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(righe.enumerated()), id: \.element.id) { i, r in
                Button {
                    editing = nil; showForm = true
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 1.5).fill(strutturaColor(r.struttura))
                            .frame(width: 3, height: 14)
                        Text(r.struttura.label).font(.system(size: 10.5)).foregroundStyle(PSE.dim)
                            .frame(width: 96, alignment: .leading)
                        Text(r.camera).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(PSE.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text("fino a \(r.posti) ospiti").font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                            .frame(width: 110, alignment: .leading)
                        Group {
                            if let f = r.fino {
                                let n = Calendar.current.dateComponents([.day], from: da, to: f).day ?? 0
                                Text("libera \(plur(n, "notte", "notti")) · poi occupata dal \(prettyDate(ymdBk.string(from: f)))")
                                    .foregroundStyle(PSE.dim)
                            } else {
                                Text("libera senza limiti in vista").foregroundStyle(PSE.pos.opacity(0.85))
                            }
                        }
                        .font(.system(size: 10.5)).frame(width: 300, alignment: .leading).lineLimit(1)
                        Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(PSE.warn)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clicca per aprire una nuova prenotazione")
                if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
            }
        }
    }

    private func giorniLiberi(_ s: Struttura, _ room: String, mese: Date) -> [Int] {
        let c = Calendar.current
        guard let r = c.range(of: .day, in: .month, for: mese) else { return [] }
        return r.compactMap { g in
            guard let d = c.date(byAdding: .day, value: g - 1, to: mese) else { return nil }
            return (bookingFor(s, room, d) == nil && !educampOccupies(s, room, d)) ? g : nil
        }
    }
    /// [3,4,5,6,7,27,28,29,30] → "3–7, 27–30"
    private func intervalli(_ giorni: [Int]) -> String {
        guard let primo = giorni.first else { return "Nessuno" }
        var out: [String] = [], inizio = primo, prec = primo
        for g in giorni.dropFirst() {
            if g == prec + 1 { prec = g; continue }
            out.append(inizio == prec ? "\(inizio)" : "\(inizio)–\(prec)")
            inizio = g; prec = g
        }
        out.append(inizio == prec ? "\(inizio)" : "\(inizio)–\(prec)")
        return out.joined(separator: ", ")
    }
    private var meseSuccessivo: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: monthAnchor) ?? monthAnchor
    }
    private struct RigaLibera: Identifiable {
        let id: String, casa: String, camera: String
        let g1: [Int], g2: [Int]
    }
    private var righeLibere: [RigaLibera] {
        strutture.flatMap { s in
            roomsFor(s).map { rm in
                RigaLibera(id: "\(s.rawValue)|\(rm)", casa: s.label, camera: rm,
                           g1: giorniLiberi(s, rm, mese: monthAnchor),
                           g2: giorniLiberi(s, rm, mese: meseSuccessivo))
            }
        }
    }

    private var giorniLiberiSection: some View {
        let righe = righeLibere
        let m1 = fmt("MMMM").string(from: monthAnchor).capitalized
        let m2 = fmt("MMMM").string(from: meseSuccessivo).capitalized
        let tot1 = righe.reduce(0) { $0 + $1.g1.count }
        let tot2 = righe.reduce(0) { $0 + $1.g2.count }
        // Chiusa di default: è la tabella più lunga della pagina e serve solo
        // quando si cerca un buco, non a ogni apertura.
        return PSEPieghevole("GIORNI LIBERI PER CAMERA",
                             valore: "\(tot1 + tot2) notti libere",
                             colore: PSE.ink, coloreValore: PSE.pos,
                             nota: "\(m1) e \(m2)") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("CASA").frame(width: 96, alignment: .leading)
                    Text("CAMERA").frame(width: 200, alignment: .leading)
                    Text("\(m1.uppercased()) — GIORNI LIBERI").frame(maxWidth: .infinity, alignment: .leading)
                    Text("TOT").frame(width: 44, alignment: .trailing)
                    Text("\(m2.uppercased()) — GIORNI LIBERI").frame(maxWidth: .infinity, alignment: .leading)
                    Text("TOT").frame(width: 44, alignment: .trailing)
                }
                .font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
                ForEach(righe) { r in
                    HStack(spacing: 10) {
                        Text(r.casa).font(.system(size: 10.5)).foregroundStyle(PSE.dim)
                            .frame(width: 96, alignment: .leading).lineLimit(1)
                        Text(r.camera).font(.system(size: 11.5, weight: .medium)).foregroundStyle(PSE.ink)
                            .frame(width: 200, alignment: .leading).lineLimit(1)
                        liberiCella(r.g1).frame(maxWidth: .infinity, alignment: .leading)
                        totLiberi(r.g1.count).frame(width: 44, alignment: .trailing)
                        liberiCella(r.g2).frame(maxWidth: .infinity, alignment: .leading)
                        totLiberi(r.g2.count).frame(width: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    Divider().overlay(gLine).padding(.leading, 14)
                }
                HStack(spacing: 10) {
                    Text("TOTALE NOTTI LIBERE").font(.system(size: 10.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                    Spacer()
                    Text(m1).font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    Text("\(tot1)").font(.system(size: 15, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                    Text(m2).font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    Text("\(tot2)").font(.system(size: 15, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.white.opacity(0.04))
                Text("Le date seguono le assegnazioni del planning qui sopra: cambiando mese con le frecce cambiano anche queste due colonne.")
                    .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 14).padding(.top, 10)
            }
        }
    }
    @ViewBuilder private func liberiCella(_ giorni: [Int]) -> some View {
        if giorni.isEmpty {
            Text("Nessuno").font(.system(size: 11)).foregroundStyle(PSE.faint)
        } else {
            Text(intervalli(giorni)).font(.system(size: 11.5)).foregroundStyle(PSE.text).lineLimit(2)
        }
    }
    private func totLiberi(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 12.5, weight: .bold)).monospacedDigit()
            .foregroundStyle(n == 0 ? PSE.faint : PSE.pos)
    }
    private func shiftMonth(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: n, to: monthAnchor) {
            withAnimation(.easeOut(duration: 0.15)) { monthAnchor = d }
            hoverDay = nil
            rebuildStats()
        }
    }

    /// Contenitore della colonna etichette: tiene tutte le righe esattamente a
    /// labelW (prima il padding sforava la colonna e la griglia non era allineata).
    private func gutterRow<C: View>(_ bg: Color, _ inset: CGFloat, _ bordo: Bool, _ h: CGFloat? = nil,
                                    @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) { content(); Spacer(minLength: 0) }
            .padding(.leading, inset).padding(.trailing, 8)
            .frame(width: labelW, height: h ?? rowH, alignment: .leading)
            .background(bg)
            .overlay(Rectangle().fill(gLine).frame(height: bordo ? 1 : 0), alignment: .bottom)
    }

    @ViewBuilder private func leftCell(_ row: GRow) -> some View {
        switch row {
        case .header:
            gutterRow(Color.clear, 12, true) {
                Text("CAMERA").font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
            }
        case .title(let s):
            // Nome della casa + occupazione del mese: il numero che serve prima
            // ancora di leggere le righe.
            let pct = occupazioneMese(s)
            gutterRow(strutturaColor(s).opacity(0.16), 12, false) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5).fill(strutturaColor(s)).frame(width: 3, height: 12)
                    Text(s.label.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.ink)
                    Spacer(minLength: 0)
                    Text("\(pct)%").font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(PSE.ink.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
        case .room(let s, let rm):
            // La riga cresce se la camera ha soggiorni sovrapposti: l'etichetta
            // deve crescere insieme, se no il reticolo si disallinea.
            let c = corsieRoom(s, rm)
            gutterRow(Color.clear, 16, true, rowH * CGFloat(c)) {
                HStack(spacing: 5) {
                    Text(rm).font(.system(size: 11)).foregroundStyle(PSE.text).lineLimit(1).minimumScaleFactor(0.8)
                    if c > 1 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(PSE.neg)
                            .help("Questa camera ha \(c) soggiorni sovrapposti negli stessi giorni: uno dei due va spostato o è arrivato con la camera sbagliata.")
                    }
                }
            }
        case .free:
            gutterRow(PSE.surface, 16, true) {
                Text("Camere libere").font(.system(size: 9.5, weight: .heavy)).tracking(0.3).foregroundStyle(PSE.dim)
            }
        }
    }

    /// Percentuale di notti vendute nel mese mostrato, per struttura.
    private func occupazioneMese(_ s: Struttura) -> Int {
        let rooms = roomsFor(s), days = monthDays
        guard !rooms.isEmpty, !days.isEmpty else { return 0 }
        let occ = days.reduce(0) { tot, d in
            tot + rooms.filter { bookingFor(s, $0, d) != nil || educampOccupies(s, $0, d) }.count
        }
        return Int((Double(occ) / Double(rooms.count * days.count) * 100).rounded())
    }

    /// Una riga della griglia. Le camere non sono celle ripetute ma un fondo di
    /// colonne vuote con sopra le barre dei soggiorni.
    @ViewBuilder private func gridRow(_ row: GRow) -> some View {
        switch row {
        case .room(let s, let rm):
            let segs = segmenti(s, rm)
            let h = rowH * CGFloat(max(1, segs.first?.corsie ?? 1))
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) { ForEach(monthDays, id: \.self) { d in sfondoCella(d, h) } }
                ForEach(segs) { seg in barra(seg) }
            }
            .frame(width: gridW, height: h, alignment: .topLeading)
        default:
            HStack(spacing: 0) { ForEach(monthDays, id: \.self) { d in cell(row, d) } }
        }
    }
    /// Quante corsie servono a questa camera (>1 = soggiorni sovrapposti).
    private func corsieRoom(_ s: Struttura, _ rm: String) -> Int {
        max(1, segmenti(s, rm).first?.corsie ?? 1)
    }
    private func sfondoCella(_ d: Date, _ h: CGFloat) -> some View {
        Rectangle().fill(colonnaTint(d))
            .frame(width: dayW, height: h)
            .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
            .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selectedDay = d } }
    }
    private func barra(_ seg: Segmento) -> some View {
        let w = CGFloat(seg.len) * dayW - 4
        let largo = w > 82, stretto = w < 62      // una o due notti: tutto lo spazio al nome
        return Button {
            if let b = seg.booking { withAnimation(.easeInOut(duration: 0.2)) { selected = b } }
        } label: {
            HStack(spacing: 6) {
                Text(seg.label).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PSE.ink).lineLimit(1).minimumScaleFactor(0.6)
                if largo, let b = seg.booking {
                    Spacer(minLength: 0)
                    Text("\(seg.len)n · \(eur(b.amount_cents))")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(PSE.ink.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.leading, stretto ? 7 : 10).padding(.trailing, stretto ? 3 : 7)
            .frame(width: w, height: rowH - 7, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(seg.color.opacity(0.28)))
            // Bordo rosso se la camera è doppia-prenotata: il colore del canale
            // resta, ma si vede subito quale riga ha un problema.
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(seg.conflitto ? PSE.neg.opacity(0.85) : seg.color.opacity(0.45), lineWidth: 1))
            // stanghetta piena all'arrivo: dove comincia il soggiorno si vede
            // anche con la coda di occhio.
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(seg.color)
                    .frame(width: stretto ? 2 : 3).padding(.vertical, 3).padding(.leading, stretto ? 2 : 3)
                    .opacity(seg.apertoPrima ? 0 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(seg.start) * dayW + 2, y: 3.5 + CGFloat(seg.corsia) * rowH)
        .help(seg.booking.map {
            "\($0.guest_name) · \(prettyDate($0.checkin)) → \(prettyDate($0.checkout)) · \(eur($0.amount_cents))"
                + (seg.conflitto ? "\n⚠︎ Sovrapposta a un altro soggiorno nella stessa camera." : "")
        } ?? (seg.nota ?? seg.label))
    }

    @ViewBuilder private func cell(_ row: GRow, _ d: Date) -> some View {
        switch row {
        case .header:
            let cal = Calendar.current
            let today = cal.isDateInToday(d)
            let sel = cal.isDate(d, inSameDayAs: selectedDay)
            VStack(spacing: 1) {
                Text(String(wdFmt.string(from: d).prefix(1)).uppercased())
                    .font(.system(size: 7.5, weight: .heavy)).tracking(0.4)
                    .foregroundStyle(isWeekend(d) ? PSE.warn.opacity(0.8) : PSE.faint)
                Text(dNumFmt.string(from: d)).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(today ? PSE.ink : (sel ? PSE.ink : PSE.text)).monospacedDigit()
                    .frame(width: 19, height: 15)
                    .background(Capsule().fill(today ? PSE.accent.opacity(0.9) : Color.clear))
            }
            .frame(width: dayW, height: rowH)
            .background(today ? Color.clear : colonnaTint(d))
            .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
            .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selectedDay = d } }
        case .title(let s):
            Rectangle().fill(strutturaColor(s).opacity(0.16)).frame(width: dayW, height: rowH)
                .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
        case .room:
            EmptyView()          // gestita da gridRow con le barre
        case .free(let s):
            let n = freeInGrid(s, d)
            // Zero camere libere = giornata piena: si evidenzia, è l'unica cifra
            // di questa riga che cambia le decisioni.
            Text("\(n)").font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(n == 0 ? PSE.warn : PSE.text.opacity(0.85))
                .frame(width: dayW, height: rowH)
                .background(n == 0 ? PSE.warn.opacity(0.13) : PSE.surface)
                .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
                .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
        }
    }

    // azioni
    /// - Parameter primoAvvio: mostra la rotella solo all'apertura. I ricarichi
    ///   automatici (finestra riportata davanti, timer) devono passare
    ///   inosservati: far sparire la pagina ogni cinque minuti sarebbe peggio
    ///   del problema che risolvono.
    private func load(primoAvvio: Bool = true) async {
        if primoAvvio { loading = true }
        defer { if primoAvvio { loading = false } }
        do { items = try await HubAPI.listPrenotazioni() } catch { if primoAvvio { items = [] } }
        educampOspiti = (try? await HubAPI.listEducampOspiti()) ?? []
        educampRighe = (try? await HubAPI.listEducampRighe()) ?? []
        movimentiEducamp = (try? await HubAPI.listMovimenti()) ?? []
        await allineaPagatoEducamp()
        // Date convertite e assegnazione camere: calcolate una volta qui, non a
        // ogni cella. Idem la mappa di occupazione per la striscia calendario.
        rebuildAssignment()
        rebuildDayCache()
        rebuildEducampRooms()
        rebuildStats()          // dati del grafico: dipendono dalle tre cache sopra
    }
    /// Il «pagato» delle prenotazioni Educamp lo decidono i movimenti, non la
    /// mano: si ricalcola a ogni caricamento dall'abbinamento nome→incasso e si
    /// riscrive solo dove è cambiato. Prima era da aggiornare a mano, e infatti
    /// i 130 € di Yesim (24/07) sono rimasti fuori per un giorno — bastava che
    /// il movimento avesse la categoria sbagliata perché nessuno se ne accorgesse.
    /// Se per quel mese non esiste una riga Educamp col nome della prenotazione,
    /// non si tocca niente: meglio fermo che sbagliato.
    private func allineaPagatoEducamp() async {
        guard !educampRighe.isEmpty else { return }
        let saldi = await EducampPagamenti.calcola(righe: educampRighe, movimenti: movimentiEducamp).saldi
        for b in items where b.source == "educamp" && b.status != "cancellata" {
            guard let ci = b.checkin, ci.count >= 7 else { continue }
            guard let atteso = await EducampPagamenti.pagato(perNome: b.guest_name, mese: String(ci.prefix(7)),
                                                             righe: educampRighe, saldi: saldi),
                  atteso != b.paid_cents else { continue }
            try? await HubAPI.updatePrenotazione(id: b.id, fields: ["paid_cents": atteso])
            if let i = items.firstIndex(where: { $0.id == b.id }) { items[i].paid_cents = atteso }
            if var sel = selected, sel.id == b.id { sel.paid_cents = atteso; selected = sel }
        }
    }
    /// Dopo ogni modifica a una prenotazione: allinea pulizie, colazioni e
    /// incassi (sync lato DB), poi ricarica. Così conti, servizi e planning
    /// riflettono subito la modifica, senza aspettare il cron notturno.
    private func syncAndReload() async {
        await HubAPI.syncCamerePSE()
        await load()
    }
    private func setStatus(_ b: Prenotazione, _ s: BookingStatus) async {
        if let i = items.firstIndex(where: { $0.id == b.id }) { items[i].status = s.rawValue }
        if var sel = selected, sel.id == b.id { sel.status = s.rawValue; selected = sel }
        try? await HubAPI.updatePrenotazione(id: b.id, fields: ["status": s.rawValue])
        await syncAndReload()
    }
    private func setPaid(_ b: Prenotazione, _ cents: Int) async {
        if let i = items.firstIndex(where: { $0.id == b.id }) { items[i].paid_cents = cents }
        if var sel = selected, sel.id == b.id { sel.paid_cents = cents; selected = sel }
        try? await HubAPI.updatePrenotazione(id: b.id, fields: ["paid_cents": cents])
        // Colazioni e pulizie ora le gestisce sync_camere_pse() (tabelle + uscite
        // a partire da agosto); il vecchio syncColazione qui creava un doppione.
        await syncAndReload()
    }
    /// Cancellazione «vera»: la prenotazione resta in archivio ma esce dai
    /// conti. Se la funzione lato database non c'è ancora, almeno lo stato si
    /// mette a cancellata — e il messaggio lo dice, invece di far credere che
    /// sia stato ripulito tutto.
    private func annulla(_ b: Prenotazione, stralcia: Bool) async {
        let esito = await HubAPI.annullaPrenotazione(id: b.id, stralciaIncasso: stralcia)
        if esito == nil {
            try? await HubAPI.updatePrenotazione(id: b.id, fields: ["status": "cancellata"])
        }
        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
        await syncAndReload()
        messaggio = testoEsito(b, esito, stralcia: stralcia)
    }
    private func testoEsito(_ b: Prenotazione, _ e: [String: Any]?, stralcia: Bool) -> String {
        guard let e else {
            return "\(b.guest_name): stato messo a «cancellata». La pulizia e le colazioni collegate non sono state tolte — manca la funzione «annulla_prenotazione» sul database."
        }
        func n(_ k: String) -> Int { (e[k] as? Int) ?? 0 }
        var parti: [String] = []
        if n("pulizie_rimosse") > 0 { parti.append("tolta \(n("pulizie_rimosse")) pulizia prevista") }
        if n("pulizie_tenute") > 0 { parti.append("\(n("pulizie_tenute")) pulizia già fatta resta nei costi") }
        if n("colazioni_rimosse") > 0 { parti.append("tolte \(n("colazioni_rimosse")) colazioni") }
        if n("colazioni_tenute") > 0 { parti.append("\(n("colazioni_tenute")) colazioni già servite restano") }
        let str = n("incasso_stralciato_cents")
        if str > 0 { parti.append("stralciato l'incasso di \(eur(str))") }
        else if stralcia && b.paid_cents > 0 { parti.append("nessun incasso automatico da stralciare") }
        if n("movimenti_manuali_collegati") > 0 {
            parti.append("attenzione: \(n("movimenti_manuali_collegati")) movimenti inseriti a mano restano in Tesoreria, vanno tolti lì se non spettano più")
        }
        if parti.isEmpty { parti.append("non c'era nulla di collegato da ripulire") }
        return "\(b.guest_name) cancellata · " + parti.joined(separator: " · ") + "."
    }
    private func remove(_ b: Prenotazione) async {
        try? await HubAPI.deletePrenotazione(id: b.id)
        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
        items.removeAll { $0.id == b.id }
        // Le pulizie/colazioni della prenotazione spariscono in cascata (FK on
        // delete cascade); l'entrata resta col riferimento a null — la sync
        // rimette in ordine il resto.
        await syncAndReload()
    }
}

// ── Drawer dettaglio prenotazione ────────────────────────────────────────────
private struct BookingDrawer: View {
    @Binding var booking: Prenotazione
    let onStatus: (BookingStatus) -> Void
    let onPay: (Int) -> Void
    let onEdit: () -> Void
    /// true = stralcia anche l'incasso già registrato in cassa.
    let onAnnulla: (Bool) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    @State private var confermaElimina = false
    @State private var confermaAnnulla = false

    private var st: BookingStatus { .from(booking.status) }
    private var str: Struttura { .from(booking.struttura) }
    private var pay: PayState { payState(amount: booking.amount_cents, paid: booking.paid_cents) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(booking.guest_name).font(.system(size: 18, weight: .bold)).foregroundStyle(PSE.ink)
                    Text("\(str.label) · \(str.address)").font(.system(size: 11)).foregroundStyle(PSE.dim)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(PSE.faint)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 46, leading: 22, bottom: 16, trailing: 20))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    section("STATO PRENOTAZIONE") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(BookingStatus.allCases) { s in
                                let on = s == st
                                Button { onStatus(s) } label: {
                                    HStack(spacing: 5) {
                                        Circle().fill(PSE.status(s)).frame(width: 6, height: 6)
                                        Text(s.label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(on ? PSE.ink : PSE.dim)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? PSE.accent.opacity(0.18) : PSE.surface))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? PSE.accent.opacity(0.6) : PSE.line, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    section("SOGGIORNO") {
                        VStack(alignment: .leading, spacing: 8) {
                            info("bed.double.fill", booking.camera ?? "—")
                            info("calendar", "\(prettyDate(booking.checkin)) → \(prettyDate(booking.checkout))" + (nights(booking.checkin, booking.checkout).map { " · \($0) notti" } ?? ""))
                            if let g = booking.guests { info("person.2.fill", "\(g) ospiti") }
                            if let s = booking.source { info("tag.fill", s.capitalized) }
                        }
                    }
                    section("CONTATTI") {
                        VStack(alignment: .leading, spacing: 8) {
                            info("phone.fill", booking.guest_phone ?? "—")
                            info("envelope.fill", booking.guest_email ?? "—")
                        }
                    }
                    section("PAGAMENTO") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Totale").font(.system(size: 12)).foregroundStyle(PSE.dim)
                                Spacer()
                                Text(eur(booking.amount_cents)).font(.system(size: 14, weight: .bold)).foregroundStyle(PSE.ink)
                            }
                            HStack {
                                Text("Incassato").font(.system(size: 12)).foregroundStyle(PSE.dim)
                                Spacer()
                                Text(eur(booking.paid_cents)).font(.system(size: 14, weight: .bold)).foregroundStyle(PSE.text)
                            }
                            HStack {
                                Text("Saldo").font(.system(size: 12)).foregroundStyle(PSE.dim)
                                Spacer()
                                Text(eur(max(0, booking.amount_cents - booking.paid_cents)))
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(PSE.payment(pay))
                            }
                            // Sulle righe Educamp il pagato lo decidono i
                            // movimenti: segnarlo qui a mano durerebbe fino al
                            // caricamento successivo, meglio dirlo che lasciare
                            // due bottoni che si disfano da soli.
                            if booking.source == "educamp" {
                                Text("Questo importo si aggiorna da solo dai movimenti di categoria «educamp»: per farlo risultare pagato, registra l'incasso in Tesoreria col nome dell'ospite nella descrizione.")
                                    .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                            } else {
                                HStack(spacing: 8) {
                                    Button("Segna acconto 30%") { onPay(Int(Double(booking.amount_cents) * 0.3)) }
                                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(PSE.text).padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(PSE.surface)).overlay(Capsule().strokeBorder(PSE.line, lineWidth: 1))
                                    Button("Segna saldato") { onPay(booking.amount_cents) }
                                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(PSE.ink).padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(PSE.accent.opacity(0.85)))
                                }
                            }
                        }
                    }
                    if let n = booking.notes, !n.isEmpty {
                        section("NOTE") { Text(n).font(.system(size: 12)).foregroundStyle(Holo.text).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    // Azioni dentro il contenuto scorrevole: così Modifica ed
                    // elimina restano raggiungibili anche quando il drawer è più
                    // alto della finestra (prima erano in un footer fuori schermo).
                    HStack(spacing: 10) {
                        Button(action: onEdit) {
                            Label("Modifica", systemImage: "pencil").font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(PSE.ink).frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 9).fill(PSE.accent.opacity(0.85)))
                        }.buttonStyle(.plain)
                        Button { confermaElimina = true } label: {
                            Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(PSE.status(.cancellata))
                                .frame(width: 42, height: 36)
                                .background(RoundedRectangle(cornerRadius: 9).fill(PSE.surface))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PSE.line, lineWidth: 1))
                        }.buttonStyle(.plain)
                        .confirmationDialog("Eliminare la prenotazione?", isPresented: $confermaElimina) {
                            Button("Elimina", role: .destructive, action: onDelete)
                            Button("Annulla", role: .cancel) {}
                        } message: {
                            Text("\(booking.guest_name) · \(eur(booking.amount_cents)). L'operazione non si può annullare.")
                        }
                    }.padding(.top, 8)
                    // Cancellare non è eliminare: la prenotazione resta in
                    // archivio ma esce dai conti (pulizia prevista, colazioni non
                    // servite, e se serve l'incasso registrato). Il calendario OTA
                    // si sblocca da solo al giro dopo di beds24-push.
                    if st != .cancellata {
                        Button { confermaAnnulla = true } label: {
                            Label("Cancella prenotazione", systemImage: "calendar.badge.minus")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(PSE.status(.cancellata))
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 9).fill(PSE.status(.cancellata).opacity(0.13)))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PSE.status(.cancellata).opacity(0.45), lineWidth: 1))
                        }.buttonStyle(.plain)
                        .confirmationDialog("Cancellare la prenotazione?", isPresented: $confermaAnnulla) {
                            // Con dei soldi già incassati la domanda vera è una
                            // sola: li teniamo o li togliamo dai conti? Si chiede
                            // adesso, non dopo in Tesoreria quando non ci si
                            // ricorda più il perché.
                            if booking.paid_cents > 0 {
                                Button("Cancella e stralcia l'incasso", role: .destructive) { onAnnulla(true) }
                                Button("Cancella, l'incasso resta (penale)") { onAnnulla(false) }
                            } else {
                                Button("Cancella", role: .destructive) { onAnnulla(false) }
                            }
                            Button("Lascia stare", role: .cancel) {}
                        } message: {
                            Text(testoAnnulla)
                        }
                        Text("Resta in archivio tra le cancellate, ma sparisce dal planning e dai conti.")
                            .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x0c1120))
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Holo.cardBorder), alignment: .leading)
        .ignoresSafeArea()
    }
    /// Cosa succede a premere «Cancella», detto prima di premerlo.
    private var testoAnnulla: String {
        var t = "La camera torna libera e la prenotazione esce dai conti: spariscono la pulizia prevista e le colazioni non ancora servite. Quelle già fatte restano, sono costi veri. La prenotazione resta in archivio, tra le cancellate."
        if booking.paid_cents > 0 { t += "\n\nRisultano incassati \(eur(booking.paid_cents))." }
        return t
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(PSE.faint)
            content()
        }
    }
    private func info(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(PSE.faint).frame(width: 16)
            Text(text).font(.system(size: 12.5)).foregroundStyle(PSE.text).textSelection(.enabled)
        }
    }
}

// ── Form prenotazione ─────────────────────────────────────────────────────────
private struct BookingForm: View {
    let existing: Prenotazione?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var struttura = Struttura.viaPo
    @State private var camera = ""
    @State private var name = ""; @State private var phone = ""; @State private var email = ""
    @State private var checkin = Date()
    @State private var checkout = Date().addingTimeInterval(86400 * 3)
    @State private var guests = "2"
    @State private var amount = ""; @State private var paid = ""
    @State private var status = BookingStatus.in_attesa
    @State private var source = "sito"
    // Default: diretta in contante → Cassa. Bonifico → Beeper (lo scegli).
    // OTA (Booking/Airbnb) → Massimo, impostato in automatico dalla fonte.
    @State private var contoId = "cassa"
    @State private var notes = ""
    @State private var saving = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "NUOVA PRENOTAZIONE" : "MODIFICA PRENOTAZIONE")
                    .font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HoloField(label: "Ospite *", text: $name, placeholder: "Es. Mario Rossi")
                HStack(spacing: 12) { HoloField(label: "Telefono", text: $phone); HoloField(label: "Email", text: $email) }
                HStack(spacing: 12) {
                    pick("Struttura", Struttura.allCases.map { ($0.rawValue, $0.label) }, struttura.rawValue) { struttura = .from($0); camera = "" }
                    pick("Camera", [("", "—")] + struttura.rooms.map { ($0, $0) }, camera) { camera = $0 }
                }
                HStack(spacing: 12) {
                    dateField("Check-in", $checkin)
                    dateField("Check-out", $checkout)
                    HoloField(label: "Ospiti", text: $guests, placeholder: "2").frame(width: 90)
                }
                HStack(spacing: 12) {
                    HoloField(label: "Totale €", text: $amount, placeholder: "630")
                    HoloField(label: "Incassato €", text: $paid, placeholder: "0")
                }
                HStack(spacing: 12) {
                    pick("Stato", BookingStatus.allCases.map { ($0.rawValue, $0.label) }, status.rawValue) { status = .from($0) }
                    pick("Fonte", bookingSources.map { ($0, $0.capitalized) }, source) { source = $0; contoId = ($0 == "booking" || $0 == "airbnb") ? "massimo" : (contoId == "massimo" ? "cassa" : contoId) }
                    pick("Conto (soldi)", [("cassa", "Cassa (contante)"), ("beeper", "Beeper (bonifico)"), ("massimo", "Massimo (OTA)")], contoId) { contoId = $0 }
                }
                HoloField(label: "Note", text: $notes)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : "Salva prenotazione").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain).disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 680)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard let e = existing else { return }
        struttura = .from(e.struttura); camera = e.camera ?? ""
        name = e.guest_name; phone = e.guest_phone ?? ""; email = e.guest_email ?? ""
        if let c = e.checkin.flatMap({ ymdBk.date(from: String($0.prefix(10))) }) { checkin = c }
        if let c = e.checkout.flatMap({ ymdBk.date(from: String($0.prefix(10))) }) { checkout = c }
        guests = e.guests.map(String.init) ?? ""
        amount = String(e.amount_cents / 100); paid = String(e.paid_cents / 100)
        status = .from(e.status); source = e.source ?? "sito"; contoId = e.conto_id ?? "cassa"; notes = e.notes ?? ""
    }
    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let body: [String: Any?] = [
            "struttura": struttura.rawValue, "camera": s(camera),
            "guest_name": name.trimmingCharacters(in: .whitespaces), "guest_phone": s(phone), "guest_email": s(email),
            "checkin": ymdBk.string(from: checkin), "checkout": ymdBk.string(from: checkout),
            "guests": Int(guests), "amount_cents": (Int(amount) ?? 0) * 100, "paid_cents": (Int(paid) ?? 0) * 100,
            "status": status.rawValue, "source": source, "conto_id": contoId, "notes": s(notes),
        ]
        do {
            if let e = existing { try await HubAPI.updatePrenotazione(id: e.id, fields: body) }
            else { try await HubAPI.createPrenotazione(body) }
            await onSaved(); dismiss()
        } catch { saving = false }
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
}
