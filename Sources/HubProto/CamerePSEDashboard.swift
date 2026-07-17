import SwiftUI

// ============================================================================
// Camere PSE — pannello controllo prenotazioni (Es Vedra · Via Romagna)
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
    case esVedra = "es-vedra", viaRomagna = "via-romagna"
    var id: String { rawValue }
    var label: String { self == .esVedra ? "Es Vedra" : "Via Romagna" }
    var address: String { self == .esVedra ? "Via Po 13" : "Via Romagna 41" }
    var hue: Double { self == .esVedra ? 200 : 280 }
    var rooms: [String] {
        self == .esVedra
        ? ["Camera 1 · Ingresso indip.", "Camera 2 · Doppia luminosa", "Camera 3 · Doppia spaziosa", "Camera 4 · Parete blu", "Intera struttura"]
        : ["Doppia con camino", "Doppia con balcone", "Doppia angolo studio", "Doppia balcone e bagno", "Doppia 5", "Doppia 6", "Intero appartamento"]
    }
    static func from(_ s: String?) -> Struttura { Struttura(rawValue: s ?? "") ?? .esVedra }
}

let bookingSources = ["sito", "whatsapp", "booking", "telefono", "email"]

enum PayState { case daPagare, acconto, pagato
    var label: String { switch self { case .daPagare: return "Da pagare"; case .acconto: return "Acconto"; case .pagato: return "Saldato" } }
    var hue: Double { switch self { case .daPagare: return 5; case .acconto: return 45; case .pagato: return 150 } }
}
func payState(amount: Int, paid: Int) -> PayState {
    if paid <= 0 { return .daPagare }
    return paid >= amount ? .pagato : .acconto
}

// cents → "€X"
func eur(_ cents: Int) -> String { LeadFmt.euro(cents / 100) }

// ── Tema sobrio e professionale (poco colore, tinte desaturate) ──
enum PSE {
    static let ink = Holo.titleText                                   // testo forte
    static let text = Color(red: 210/255, green: 220/255, blue: 236/255)
    static let dim = Color(red: 190/255, green: 202/255, blue: 224/255).opacity(0.62)
    static let faint = Color(red: 150/255, green: 165/255, blue: 190/255).opacity(0.55)
    static let line = Color.white.opacity(0.09)
    static let surface = Color.white.opacity(0.035)
    static let accent = Color(red: 0.44, green: 0.56, blue: 0.74)     // slate blue sobrio
    static let panel = Color(hex: 0x0f141e)

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
}

// ── Dashboard ────────────────────────────────────────────────────────────────
struct CamerePSEDashboard: View {
    @State private var items: [Prenotazione] = []
    @State private var loading = true
    @State private var strutturaFilter: Struttura? = nil
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var monthAnchor = { let c = Calendar.current; return c.date(from: c.dateComponents([.year, .month], from: Date()))! }()
    @State private var selected: Prenotazione? = nil
    @State private var editing: Prenotazione? = nil
    @State private var showForm = false

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
    // camere occupate quella notte (checkin <= d < checkout)
    private func occupancy(_ d: Date) -> Int {
        items.filter { b in
            guard b.status != "cancellata", matchesStruttura(b), let ci = day(b.checkin), let co = day(b.checkout) else { return false }
            return ci <= d && d < co
        }.count
    }
    private var capacity: Int {
        switch strutturaFilter { case .esVedra: return 4; case .viaRomagna: return 6; case nil: return 10 }
    }
    // prenotazioni rilevanti per il giorno (arrivo, in casa, partenza)
    private func bookingsOn(_ d: Date) -> [Prenotazione] {
        items.filter { b in
            guard b.status != "cancellata", matchesStruttura(b), let ci = day(b.checkin), let co = day(b.checkout) else { return false }
            return ci <= d && d <= co
        }.sorted { ($0.checkin ?? "") < ($1.checkin ?? "") }
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
    private func bookingFor(_ s: Struttura, _ room: String, _ d: Date) -> Prenotazione? {
        items.first { b in
            guard b.status != "cancellata", b.struttura == s.rawValue,
                  let ci = day(b.checkin), let co = day(b.checkout), ci <= d, d < co else { return false }
            if let cam = b.camera { return cam == room || cam.lowercased().contains("inter") }
            return false
        }
    }
    private func freeInGrid(_ s: Struttura, _ d: Date) -> Int { roomsFor(s).filter { bookingFor(s, $0, d) == nil }.count }
    private func isToday(_ s: String?) -> Bool { s.map { String($0.prefix(10)) } == ymdBk.string(from: Date()) }
    private var incassato: Int { items.filter { $0.status != "cancellata" }.map { $0.paid_cents }.reduce(0, +) }
    private var daIncassare: Int { attive.map { max(0, $0.amount_cents - $0.paid_cents) }.reduce(0, +) }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 16) {
                header
                kpiBar
                strutturaChips
                if loading {
                    HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 40)
                } else {
                    calendarStrip
                    daySection
                    planningSection
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
                    onDelete: { Task { await remove(selected!) } },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 430).transition(.move(edge: .trailing))
            }
        }
        .task { await load() }
        .sheet(isPresented: $showForm, onDismiss: { editing = nil }) {
            BookingForm(existing: editing) { await load() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("PRENOTAZIONI").font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(PSE.ink)
                Text("Camere PSE · Porto Sant'Elpidio").font(.system(size: 11)).foregroundStyle(PSE.dim)
            }
            Spacer()
            Button { editing = nil; showForm = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("Nuova prenotazione").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(PSE.ink).padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(PSE.accent.opacity(0.9)))
            }.buttonStyle(.plain)
        }
    }

    private var kpiBar: some View {
        HStack(spacing: 12) {
            kpi("IN CASA", "\(items.filter { $0.status == "in_casa" }.count)")
            kpi("CHECK-IN OGGI", "\(attive.filter { isToday($0.checkin) }.count)")
            kpi("ATTIVE", "\(attive.count)")
            kpi("INCASSATO", eur(incassato))
            kpi("DA INCASSARE", eur(daIncassare))
        }
    }
    private func kpi(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    private var strutturaChips: some View {
        HStack(spacing: 7) {
            chip(strutturaFilter == nil, "Tutte") { strutturaFilter = nil }
            ForEach(Struttura.allCases) { s in
                chip(strutturaFilter == s, s.label) { strutturaFilter = strutturaFilter == s ? nil : s }
            }
            Spacer()
        }
    }
    private func chip(_ on: Bool, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { act() } } label: {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? PSE.ink : PSE.dim)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(on ? PSE.accent.opacity(0.85) : PSE.surface))
                .overlay(Capsule().strokeBorder(on ? .clear : PSE.line, lineWidth: 1))
        }.buttonStyle(.plain)
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
                dot(st.label, PSE.status(st)).frame(width: 96, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
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

    // ── planning mensile: camere (righe) × giorni (colonne) ──
    private enum GRow: Hashable { case header, title(Struttura), room(Struttura, String), free(Struttura) }
    private var gridRows: [GRow] {
        var r: [GRow] = [.header]
        for s in strutture { r.append(.title(s)); for rm in roomsFor(s) { r.append(.room(s, rm)) }; r.append(.free(s)) }
        return r
    }
    private var rowH: CGFloat { 27 }
    private var dayW: CGFloat { 34 }
    private var labelW: CGFloat { 210 }
    private var occFill: Color { Color(hue: 5/360, saturation: 0.34, brightness: 0.48).opacity(0.34) }
    private var freeFill: Color { Color(hue: 150/360, saturation: 0.30, brightness: 0.42).opacity(0.20) }
    private var gLine: Color { Color.white.opacity(0.06) }

    private var planningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("PLANNING · \(fmt("MMMM yyyy").string(from: monthAnchor).uppercased())")
                    .font(.system(size: 13.5, weight: .bold)).foregroundStyle(PSE.ink)
                HStack(spacing: 10) {
                    legendItem(freeFill, "Libera"); legendItem(occFill, "Occupata")
                }
                Spacer()
                HStack(spacing: 6) {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(PSE.dim)
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundStyle(PSE.dim)
                }.font(.system(size: 12, weight: .bold))
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) { ForEach(gridRows, id: \.self) { leftCell($0) } }.frame(width: labelW)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(gridRows, id: \.self) { row in
                            HStack(spacing: 0) { ForEach(monthDays, id: \.self) { d in cell(row, d) } }
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(PSE.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 12, height: 10); Text(t).font(.system(size: 10)).foregroundStyle(PSE.faint) }
    }
    private func shiftMonth(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: n, to: monthAnchor) { withAnimation(.easeOut(duration: 0.15)) { monthAnchor = d } }
    }

    @ViewBuilder private func leftCell(_ row: GRow) -> some View {
        switch row {
        case .header:
            Text("CAMERA").font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                .frame(width: labelW, height: rowH, alignment: .leading).padding(.leading, 12)
                .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
        case .title(let s):
            Text(s.label.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.5).foregroundStyle(PSE.ink)
                .frame(width: labelW, height: rowH, alignment: .leading).padding(.leading, 12)
                .background(PSE.accent.opacity(0.14))
        case .room(_, let rm):
            Text(rm).font(.system(size: 10.5)).foregroundStyle(PSE.text).lineLimit(1)
                .frame(width: labelW, height: rowH, alignment: .leading).padding(.leading, 14)
                .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
        case .free:
            Text("Camere libere").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(PSE.dim)
                .frame(width: labelW, height: rowH, alignment: .leading).padding(.leading, 14)
                .background(PSE.surface)
                .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
        }
    }

    @ViewBuilder private func cell(_ row: GRow, _ d: Date) -> some View {
        switch row {
        case .header:
            let today = Calendar.current.isDateInToday(d)
            VStack(spacing: 0) {
                Text(String(wdFmt.string(from: d).prefix(1)).uppercased()).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(PSE.faint)
                Text(dNumFmt.string(from: d)).font(.system(size: 11, weight: .bold)).foregroundStyle(today ? PSE.accent : PSE.text).monospacedDigit()
            }
            .frame(width: dayW, height: rowH)
            .background(today ? PSE.accent.opacity(0.14) : Color.clear)
            .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
            .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
        case .title:
            Rectangle().fill(PSE.accent.opacity(0.14)).frame(width: dayW, height: rowH)
                .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
        case .room(let s, let rm):
            let b = bookingFor(s, rm, d)
            Button {
                if let b { withAnimation(.easeInOut(duration: 0.2)) { selected = b } }
                else { withAnimation(.easeOut(duration: 0.15)) { selectedDay = d } }
            } label: {
                Text(b.map { firstName($0.guest_name) } ?? "")
                    .font(.system(size: 8.5, weight: .medium)).foregroundStyle(PSE.text).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: dayW, height: rowH)
                    .background(b != nil ? occFill : freeFill)
                    .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
                    .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        case .free(let s):
            let n = freeInGrid(s, d)
            Text("\(n)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                .foregroundStyle(n == 0 ? PSE.faint : PSE.text)
                .frame(width: dayW, height: rowH)
                .background(PSE.surface)
                .overlay(Rectangle().fill(gLine).frame(width: 1), alignment: .trailing)
                .overlay(Rectangle().fill(gLine).frame(height: 1), alignment: .bottom)
        }
    }

    // azioni
    private func load() async {
        loading = true; defer { loading = false }
        do { items = try await HubAPI.listPrenotazioni() } catch { items = [] }
    }
    private func setStatus(_ b: Prenotazione, _ s: BookingStatus) async {
        if let i = items.firstIndex(where: { $0.id == b.id }) { items[i].status = s.rawValue }
        if var sel = selected, sel.id == b.id { sel.status = s.rawValue; selected = sel }
        try? await HubAPI.updatePrenotazione(id: b.id, fields: ["status": s.rawValue])
    }
    private func setPaid(_ b: Prenotazione, _ cents: Int) async {
        if let i = items.firstIndex(where: { $0.id == b.id }) { items[i].paid_cents = cents }
        if var sel = selected, sel.id == b.id { sel.paid_cents = cents; selected = sel }
        try? await HubAPI.updatePrenotazione(id: b.id, fields: ["paid_cents": cents])
    }
    private func remove(_ b: Prenotazione) async {
        try? await HubAPI.deletePrenotazione(id: b.id)
        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
        items.removeAll { $0.id == b.id }
    }
}

// ── Drawer dettaglio prenotazione ────────────────────────────────────────────
private struct BookingDrawer: View {
    @Binding var booking: Prenotazione
    let onStatus: (BookingStatus) -> Void
    let onPay: (Int) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

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
                    if let n = booking.notes, !n.isEmpty {
                        section("NOTE") { Text(n).font(.system(size: 12)).foregroundStyle(Holo.text).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }

            HStack(spacing: 10) {
                Button(action: onEdit) {
                    Label("Modifica", systemImage: "pencil").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PSE.ink).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(PSE.surface))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PSE.line, lineWidth: 1))
                }.buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(PSE.status(.cancellata))
                        .frame(width: 42, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(PSE.surface))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PSE.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 12, leading: 22, bottom: 18, trailing: 22))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x0c1120))
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Holo.cardBorder), alignment: .leading)
        .ignoresSafeArea()
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

    @State private var struttura = Struttura.esVedra
    @State private var camera = ""
    @State private var name = ""; @State private var phone = ""; @State private var email = ""
    @State private var checkin = Date()
    @State private var checkout = Date().addingTimeInterval(86400 * 3)
    @State private var guests = "2"
    @State private var amount = ""; @State private var paid = ""
    @State private var status = BookingStatus.in_attesa
    @State private var source = "sito"
    @State private var notes = ""
    @State private var saving = false

    var body: some View {
        ScrollView {
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
                    pick("Fonte", bookingSources.map { ($0, $0.capitalized) }, source) { source = $0 }
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
        status = .from(e.status); source = e.source ?? "sito"; notes = e.notes ?? ""
    }
    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let body: [String: Any?] = [
            "struttura": struttura.rawValue, "camera": s(camera),
            "guest_name": name.trimmingCharacters(in: .whitespaces), "guest_phone": s(phone), "guest_email": s(email),
            "checkin": ymdBk.string(from: checkin), "checkout": ymdBk.string(from: checkout),
            "guests": Int(guests), "amount_cents": (Int(amount) ?? 0) * 100, "paid_cents": (Int(paid) ?? 0) * 100,
            "status": status.rawValue, "source": source, "notes": s(notes),
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
