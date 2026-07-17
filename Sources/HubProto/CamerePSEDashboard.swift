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
    @State private var statusFilter: BookingStatus? = nil
    @State private var selected: Prenotazione? = nil
    @State private var editing: Prenotazione? = nil
    @State private var showForm = false

    private var filtered: [Prenotazione] {
        items.filter {
            (strutturaFilter == nil || $0.struttura == strutturaFilter!.rawValue) &&
            (statusFilter == nil || $0.status == statusFilter!.rawValue)
        }
    }
    private var attive: [Prenotazione] { items.filter { BookingStatus.from($0.status).active } }
    private func isToday(_ s: String?) -> Bool { s.map { String($0.prefix(10)) } == ymdBk.string(from: Date()) }
    private var incassato: Int { items.filter { $0.status != "cancellata" }.map { $0.paid_cents }.reduce(0, +) }
    private var daIncassare: Int { attive.map { max(0, $0.amount_cents - $0.paid_cents) }.reduce(0, +) }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 16) {
                header
                kpiBar
                filters
                if loading {
                    HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 40)
                } else if filtered.isEmpty {
                    EmptyStateCard(icon: "calendar", text: "Nessuna prenotazione.\nAggiungine una con “+ Nuova prenotazione”.")
                } else {
                    GlassCard {
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { i, b in
                                bookingRow(b)
                                if i < filtered.count - 1 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 16) }
                            }
                        }.padding(.vertical, 4)
                    }
                }
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
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                Text("Camere PSE · Porto Sant'Elpidio").font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
            Spacer()
            Button { editing = nil; showForm = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("Nuova prenotazione").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Color(hex: 0x0b1220)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Holo.hsl(210, 90, 66)))
            }.buttonStyle(.plain)
        }
    }

    private var kpiBar: some View {
        HStack(spacing: 12) {
            kpi("IN CASA", "\(items.filter { $0.status == "in_casa" }.count)", 150)
            kpi("CHECK-IN OGGI", "\(attive.filter { isToday($0.checkin) }.count)", 45)
            kpi("ATTIVE", "\(attive.count)", 210)
            kpi("INCASSATO", eur(incassato), 150)
            kpi("DA INCASSARE", eur(daIncassare), 30)
        }
    }
    private func kpi(_ label: String, _ value: String, _ hue: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Holo.hsl(hue, 70, 68))
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(Holo.titleText).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Holo.hsl(hue, 60, 55).opacity(0.28), lineWidth: 1))
    }

    private var filters: some View {
        HStack(spacing: 7) {
            chip(strutturaFilter == nil && statusFilter == nil, "Tutte") { strutturaFilter = nil; statusFilter = nil }
            ForEach(Struttura.allCases) { s in
                chip(strutturaFilter == s, s.label, hue: s.hue) { strutturaFilter = strutturaFilter == s ? nil : s }
            }
            Divider().frame(height: 16).overlay(Color.white.opacity(0.15))
            ForEach(BookingStatus.allCases) { st in
                chip(statusFilter == st, st.label, hue: st.hue) { statusFilter = statusFilter == st ? nil : st }
            }
            Spacer()
        }
    }
    private func chip(_ on: Bool, _ label: String, hue: Double = 210, _ act: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { act() } } label: {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color(hex: 0x0b1220) : Holo.hsl(hue, 60, 72))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(on ? Holo.hsl(hue, 75, 62) : Holo.hsl(hue, 55, 45).opacity(0.14)))
                .overlay(Capsule().strokeBorder(Holo.hsl(hue, 60, 55).opacity(on ? 0 : 0.4), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func bookingRow(_ b: Prenotazione) -> some View {
        let st = BookingStatus.from(b.status)
        let str = Struttura.from(b.struttura)
        let pay = payState(amount: b.amount_cents, paid: b.paid_cents)
        return Button { withAnimation(.easeInOut(duration: 0.2)) { selected = b } } label: {
            HStack(spacing: 14) {
                // struttura + guest
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.guest_name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Holo.titleText).lineLimit(1)
                    Text([str.label, b.camera].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
                }
                .frame(width: 220, alignment: .leading)
                // date
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(prettyDate(b.checkin)) → \(prettyDate(b.checkout))").font(.system(size: 11)).foregroundStyle(Holo.subDim)
                    if let n = nights(b.checkin, b.checkout) { Text("\(n) notti\(b.guests.map { " · \($0) osp." } ?? "")").font(.system(size: 9.5)).foregroundStyle(Csb.secFg) }
                }
                .frame(width: 190, alignment: .leading)
                Spacer(minLength: 8)
                // importo + pagamento
                VStack(alignment: .trailing, spacing: 3) {
                    Text(eur(b.amount_cents)).font(.system(size: 13.5, weight: .bold)).foregroundStyle(Holo.text).monospacedDigit()
                    badge(pay.label, pay.hue)
                }
                // stato
                badge(st.label, st.hue).frame(width: 92, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func badge(_ t: String, _ hue: Double) -> some View {
        Text(t.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
            .foregroundStyle(Holo.hsl(hue, 85, 76))
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Capsule().fill(Holo.hsl(hue, 70, 45).opacity(0.18)))
            .overlay(Capsule().strokeBorder(Holo.hsl(hue, 70, 55).opacity(0.35), lineWidth: 1))
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
                    Text(booking.guest_name).font(.system(size: 18, weight: .bold)).foregroundStyle(Holo.titleText)
                    Text("\(str.label) · \(str.address)").font(.system(size: 11)).foregroundStyle(Holo.subDim)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Csb.secFg)
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
                                    Text(s.label).font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(on ? Color(hex: 0x0b1220) : s.hue == 0 ? Holo.text : Holo.hsl(s.hue, 80, 72))
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Holo.hsl(s.hue, 75, 60) : Holo.hsl(s.hue, 60, 45).opacity(0.14)))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Holo.hsl(s.hue, 60, 55).opacity(on ? 0 : 0.35), lineWidth: 1))
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
                                Text("Totale").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                                Spacer()
                                Text(eur(booking.amount_cents)).font(.system(size: 14, weight: .bold)).foregroundStyle(Holo.text)
                            }
                            HStack {
                                Text("Incassato").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                                Spacer()
                                Text(eur(booking.paid_cents)).font(.system(size: 14, weight: .bold)).foregroundStyle(Holo.hsl(150, 70, 68))
                            }
                            HStack {
                                Text("Saldo").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                                Spacer()
                                Text(eur(max(0, booking.amount_cents - booking.paid_cents)))
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Holo.hsl(30, 80, 70))
                            }
                            HStack(spacing: 8) {
                                Button("Segna acconto 30%") { onPay(Int(Double(booking.amount_cents) * 0.3)) }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Holo.hsl(45, 80, 74)).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Holo.hsl(45, 60, 45).opacity(0.16)))
                                Button("Segna saldato") { onPay(booking.amount_cents) }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Holo.hsl(150, 80, 74)).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Holo.hsl(150, 60, 45).opacity(0.16)))
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
                        .foregroundStyle(Holo.titleText).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }.buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(Holo.hsl(5, 75, 65))
                        .frame(width: 42, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Holo.hsl(5, 70, 50).opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Holo.hsl(5, 70, 55).opacity(0.4), lineWidth: 1))
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
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Holo.hsl(210, 60, 66))
            content()
        }
    }
    private func info(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Csb.secFg).frame(width: 16)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Holo.text).textSelection(.enabled)
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
