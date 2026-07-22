import SwiftUI

// ============================================================================
// NCREATIVE — CRM dell'agenzia di social media marketing di Nikola.
// Vive nello stesso Supabase di GZ Brain, tabelle prefissate `nc_`.
// L'interfaccia di questa sezione è in inglese (il resto dell'app è in
// italiano): è la sua area, la lingua la sceglie lei.
// Importi sempre in centesimi, come tesoreria/educamp.
// ============================================================================

// ── Entità ───────────────────────────────────────────────────────────────────

struct NCClient: Identifiable, Decodable, Equatable {
    let id: String
    var name: String
    var contact_name: String?
    var email: String?
    var phone: String?
    var instagram: String?
    var website: String?
    var status: String
    var retainer_cents: Int
    var services: [String]
    var start_date: String?
    var source: String?
    var notes: String?
    let created_at: String?
}

struct NCDeal: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var title: String
    var contact_name: String?
    var email: String?
    var phone: String?
    var stage: String
    var value_cents: Int
    var recurring: Bool
    var source: String?
    var expected_close: String?
    var notes: String?
    let created_at: String?
}

struct NCCampaign: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var name: String
    var kind: String?
    var status: String
    var start_date: String?
    var end_date: String?
    var budget_cents: Int
    var notes: String?
    let created_at: String?
}

struct NCContent: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var campaign_id: String?
    var title: String
    var platform: String
    var format: String?
    var publish_date: String?
    var status: String
    var owner: String?
    var link: String?
    var notes: String?
    let created_at: String?
}

struct NCInvoice: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var number: String?
    var issue_date: String
    var due_date: String?
    var period: String?
    var description: String?
    var amount_cents: Int
    var vat_pct: Double
    var status: String
    var paid_date: String?
    var notes: String?
    let created_at: String?

    var vatCents: Int { Int((Double(amount_cents) * vat_pct / 100).rounded()) }
    var totalCents: Int { amount_cents + vatCents }
    /// Scaduta: inviata, non pagata, con la data di scadenza passata.
    var isOverdue: Bool {
        guard status == "sent", let d = ncParseDate(due_date) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }
}

/// Voce del modulo Personale: una riga qualunque sia la colonna (famiglia,
/// Giorgio, Niko) e il tipo (appuntamento, da fare, spesa, pasto, obiettivo…).
struct NCPersonalItem: Identifiable, Decodable, Equatable {
    let id: String
    var person: String
    var kind: String
    var title: String
    var notes: String?
    var day: String?
    var time_at: String?
    var slot: String?
    var done: Bool
    var priority: Int
    var repeat_rule: String?
    var notify_at: String?
    var month: String?
    let created_at: String?
}

struct NCExpense: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var date: String
    var category: String
    var vendor: String?
    var description: String?
    var amount_cents: Int
    var recurring: Bool
    var notes: String?
    let created_at: String?
}

// ── Vocabolari ───────────────────────────────────────────────────────────────

enum NCClientStatus: String, CaseIterable, Identifiable {
    case lead, active, paused, churned
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lead: return "Lead"
        case .active: return "Active"
        case .paused: return "Paused"
        case .churned: return "Churned"
        }
    }
    var color: Color {
        switch self {
        case .lead: return UI.accent
        case .active: return UI.tint(.ok)
        case .paused: return UI.tint(.attesa)
        case .churned: return UI.tint(.stop)
        }
    }
    static func from(_ raw: String?) -> NCClientStatus { NCClientStatus(rawValue: raw ?? "") ?? .lead }
}

enum NCStage: String, CaseIterable, Identifiable {
    case new, contacted, proposal, negotiation, won, lost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .new: return "New"
        case .contacted: return "Contacted"
        case .proposal: return "Proposal sent"
        case .negotiation: return "Negotiation"
        case .won: return "Won"
        case .lost: return "Lost"
        }
    }
    var color: Color {
        switch self {
        case .new: return UI.accent
        case .contacted, .proposal, .negotiation: return UI.tint(.corso)
        case .won: return UI.tint(.ok)
        case .lost: return UI.tint(.stop)
        }
    }
    var isClosed: Bool { self == .won || self == .lost }
    static func from(_ raw: String?) -> NCStage { NCStage(rawValue: raw ?? "") ?? .new }
}

enum NCPlatform: String, CaseIterable, Identifiable {
    case instagram, tiktok, youtube, linkedin, facebook, twitter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        case .linkedin: return "LinkedIn"
        case .facebook: return "Facebook"
        case .twitter: return "X"
        }
    }
    var short: String {
        switch self {
        case .instagram: return "IG"
        case .tiktok: return "TT"
        case .youtube: return "YT"
        case .linkedin: return "IN"
        case .facebook: return "FB"
        case .twitter: return "X"
        }
    }
    var icon: String {
        switch self {
        case .instagram: return "camera"
        case .tiktok: return "music.note"
        case .youtube: return "play.rectangle"
        case .linkedin: return "briefcase"
        case .facebook: return "person.2"
        case .twitter: return "at"
        }
    }
    static func from(_ raw: String?) -> NCPlatform { NCPlatform(rawValue: raw ?? "") ?? .instagram }
}

enum NCContentStatus: String, CaseIterable, Identifiable {
    case idea, draft, review, approved, scheduled, published
    var id: String { rawValue }
    var label: String {
        switch self {
        case .idea: return "Idea"
        case .draft: return "Draft"
        case .review: return "In review"
        case .approved: return "Approved"
        case .scheduled: return "Scheduled"
        case .published: return "Published"
        }
    }
    var color: Color {
        switch self {
        case .idea: return UI.tint(.neutro)
        case .draft: return UI.tint(.corso)
        case .review: return UI.tint(.attesa)
        case .approved: return UI.accent
        case .scheduled: return UI.tint(.corso)
        case .published: return UI.tint(.ok)
        }
    }
    static func from(_ raw: String?) -> NCContentStatus { NCContentStatus(rawValue: raw ?? "") ?? .idea }
}

enum NCInvoiceStatus: String, CaseIterable, Identifiable {
    case draft, sent, paid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .draft: return "Draft"
        case .sent: return "Sent"
        case .paid: return "Paid"
        }
    }
    var color: Color {
        switch self {
        case .draft: return UI.tint(.neutro)
        case .sent: return UI.tint(.attesa)
        case .paid: return UI.tint(.ok)
        }
    }
    static func from(_ raw: String?) -> NCInvoiceStatus { NCInvoiceStatus(rawValue: raw ?? "") ?? .draft }
}

enum NCExpenseCategory: String, CaseIterable, Identifiable {
    case ads, tools, freelance, salary, office, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ads: return "Ads spend"
        case .tools: return "Tools"
        case .freelance: return "Freelance"
        case .salary: return "Salary"
        case .office: return "Office"
        case .other: return "Other"
        }
    }
    var icon: String {
        switch self {
        case .ads: return "megaphone"
        case .tools: return "wrench.and.screwdriver"
        case .freelance: return "person.badge.clock"
        case .salary: return "person.text.rectangle"
        case .office: return "building.2"
        case .other: return "tray"
        }
    }
    static func from(_ raw: String?) -> NCExpenseCategory { NCExpenseCategory(rawValue: raw ?? "") ?? .other }
}

let NC_SERVICES = ["social", "ads", "content", "branding", "web", "strategy"]
let NC_FORMATS = ["reel", "post", "carousel", "story", "video", "ugc"]
let NC_CAMPAIGN_STATUSES = ["planned", "active", "on_hold", "done"]

// ── Formattazione ────────────────────────────────────────────────────────────

/// Importo in centesimi → "€1.250" (o "€1.250,00" con i decimali).
func ncEuro(_ cents: Int, decimals: Bool = false) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = "."
    f.decimalSeparator = ","
    f.minimumFractionDigits = decimals ? 2 : 0
    f.maximumFractionDigits = decimals ? 2 : 0
    let s = f.string(from: NSNumber(value: Double(cents) / 100)) ?? "0"
    return "€\(s)"
}

/// Testo digitato → centesimi. Accetta "1.250,50", "1250.50", "€1 250".
func ncCents(_ s: String) -> Int {
    var t = s.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
    // con entrambi i separatori il punto è delle migliaia
    if t.contains(",") && t.contains(".") { t = t.replacingOccurrences(of: ".", with: "") }
    t = t.replacingOccurrences(of: ",", with: ".")
    return Int(((Double(t) ?? 0) * 100).rounded())
}

private let ncISODay: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// "2026-07-22" (o un timestamptz) → Date
func ncParseDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    return ncISODay.date(from: String(s.prefix(10)))
}
func ncDayString(_ d: Date) -> String { ncISODay.string(from: d) }
func ncMonthKey(_ d: Date) -> String { String(ncISODay.string(from: d).prefix(7)) }

/// "2026-07-22" → "22 Jul"
func ncShortDate(_ s: String?) -> String {
    guard let d = ncParseDate(s) else { return "—" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "d MMM"
    return f.string(from: d)
}
/// "2026-07-22" → "22 Jul 2026"
func ncLongDate(_ s: String?) -> String {
    guard let d = ncParseDate(s) else { return "—" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
}
func ncMonthLabel(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "MMMM yyyy"
    return f.string(from: d)
}

func ncBlank(_ s: String) -> String? {
    let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? nil : v
}
func ncClean(_ s: String?) -> String? {
    guard let v = s?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
    return v
}

// ── API ──────────────────────────────────────────────────────────────────────

extension HubAPI {
    static func ncClients() async throws -> [NCClient] {
        try await sb.fetch("nc_clients?select=*&order=name.asc&limit=2000")
    }
    static func ncDeals() async throws -> [NCDeal] {
        try await sb.fetch("nc_deals?select=*&order=created_at.desc&limit=2000")
    }
    static func ncCampaigns() async throws -> [NCCampaign] {
        try await sb.fetch("nc_campaigns?select=*&order=start_date.desc.nullslast&limit=2000")
    }
    static func ncContent() async throws -> [NCContent] {
        try await sb.fetch("nc_content?select=*&order=publish_date.asc.nullslast&limit=3000")
    }
    static func ncInvoices() async throws -> [NCInvoice] {
        try await sb.fetch("nc_invoices?select=*&order=issue_date.desc&limit=2000")
    }
    static func ncExpenses() async throws -> [NCExpense] {
        try await sb.fetch("nc_expenses?select=*&order=date.desc&limit=3000")
    }
    static func ncPersonal() async throws -> [NCPersonalItem] {
        try await sb.fetch("nc_personal_items?select=*&order=day.asc.nullslast,priority.desc,created_at.asc&limit=3000")
    }

    /// CRUD generico sulle tabelle `nc_`: gli id sono uuid, niente da encodare.
    static func ncInsert(_ table: String, _ fields: [String: Any?]) async throws {
        try await sb.mutate(table, method: "POST", body: fields)
    }
    static func ncUpdate(_ table: String, id: String, _ fields: [String: Any?]) async throws {
        try await sb.mutate("\(table)?id=eq.\(id)", method: "PATCH", body: fields)
    }
    static func ncDelete(_ table: String, id: String) async throws {
        try await sb.mutate("\(table)?id=eq.\(id)", method: "DELETE")
    }
}

// ── Store condiviso della sezione ────────────────────────────────────────────

@MainActor
final class NCModel: ObservableObject {
    @Published var clients: [NCClient] = []
    @Published var deals: [NCDeal] = []
    @Published var campaigns: [NCCampaign] = []
    @Published var content: [NCContent] = []
    @Published var invoices: [NCInvoice] = []
    @Published var expenses: [NCExpense] = []
    @Published var personal: [NCPersonalItem] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true
        do {
            async let cl = HubAPI.ncClients()
            async let dl = HubAPI.ncDeals()
            async let cp = HubAPI.ncCampaigns()
            async let ct = HubAPI.ncContent()
            async let iv = HubAPI.ncInvoices()
            async let ex = HubAPI.ncExpenses()
            async let pr = HubAPI.ncPersonal()
            let (a, b, c, d, e, f, g) = try await (cl, dl, cp, ct, iv, ex, pr)
            clients = a; deals = b; campaigns = c; content = d
            invoices = e; expenses = f; personal = g
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func clientName(_ id: String?) -> String {
        guard let id, let c = clients.first(where: { $0.id == id }) else { return "—" }
        return c.name
    }

    /// Ottimista: sposta subito la card, poi scrive.
    func setDealStage(_ id: String, _ stage: NCStage) async {
        guard let i = deals.firstIndex(where: { $0.id == id }), deals[i].stage != stage.rawValue else { return }
        deals[i].stage = stage.rawValue
        try? await HubAPI.ncUpdate("nc_deals", id: id, ["stage": stage.rawValue, "updated_at": isoNowString()])
    }
    func setContentStatus(_ id: String, _ status: NCContentStatus) async {
        guard let i = content.firstIndex(where: { $0.id == id }), content[i].status != status.rawValue else { return }
        content[i].status = status.rawValue
        try? await HubAPI.ncUpdate("nc_content", id: id, ["status": status.rawValue])
    }
    func setInvoiceStatus(_ id: String, _ status: NCInvoiceStatus) async {
        guard let i = invoices.firstIndex(where: { $0.id == id }) else { return }
        invoices[i].status = status.rawValue
        var fields: [String: Any?] = ["status": status.rawValue, "updated_at": isoNowString()]
        if status == .paid {
            let today = ncDayString(Date())
            invoices[i].paid_date = today
            fields["paid_date"] = today
        } else {
            invoices[i].paid_date = nil
            fields["paid_date"] = nil
        }
        try? await HubAPI.ncUpdate("nc_invoices", id: id, fields)
    }

    /// Spunta/despunta una voce personale: prima l'UI, poi il salvataggio.
    func togglePersonalDone(_ id: String) async {
        guard let i = personal.firstIndex(where: { $0.id == id }) else { return }
        personal[i].done.toggle()
        try? await HubAPI.ncUpdate("nc_personal_items", id: id,
                                   ["done": personal[i].done, "updated_at": isoNowString()])
    }

    func delete(_ table: String, id: String) async {
        switch table {
        case "nc_clients": clients.removeAll { $0.id == id }
        case "nc_deals": deals.removeAll { $0.id == id }
        case "nc_campaigns": campaigns.removeAll { $0.id == id }
        case "nc_content": content.removeAll { $0.id == id }
        case "nc_invoices": invoices.removeAll { $0.id == id }
        case "nc_expenses": expenses.removeAll { $0.id == id }
        case "nc_personal_items": personal.removeAll { $0.id == id }
        default: break
        }
        try? await HubAPI.ncDelete(table, id: id)
    }

    // ── Metriche ──
    var activeClients: [NCClient] { clients.filter { $0.status == "active" } }
    /// Ricavo ricorrente mensile: somma dei retainer dei clienti attivi.
    var mrrCents: Int { activeClients.reduce(0) { $0 + $1.retainer_cents } }
    var openDeals: [NCDeal] { deals.filter { !NCStage.from($0.stage).isClosed } }
    var pipelineCents: Int { openDeals.reduce(0) { $0 + $1.value_cents } }
    /// Non incassato: tutte le fatture inviate e mai pagate.
    var outstandingCents: Int {
        invoices.filter { $0.status == "sent" }.reduce(0) { $0 + $1.totalCents }
    }
    var overdueInvoices: [NCInvoice] { invoices.filter(\.isOverdue) }

    func invoices(month: String) -> [NCInvoice] { invoices.filter { $0.issue_date.hasPrefix(month) } }
    func expenses(month: String) -> [NCExpense] { expenses.filter { $0.date.hasPrefix(month) } }
    /// Incassato nel mese: fatture pagate con data di pagamento in quel mese.
    func collectedCents(month: String) -> Int {
        invoices.filter { $0.status == "paid" && ($0.paid_date ?? "").hasPrefix(month) }
            .reduce(0) { $0 + $1.amount_cents }
    }
    func billedCents(month: String) -> Int { invoices(month: month).reduce(0) { $0 + $1.amount_cents } }
    func spentCents(month: String) -> Int { expenses(month: month).reduce(0) { $0 + $1.amount_cents } }
    func profitCents(month: String) -> Int { collectedCents(month: month) - spentCents(month: month) }

    /// Prossimo numero fattura dell'anno in corso: "2026-007".
    /// `offset` serve a numerare in sequenza più fatture create nello stesso giro.
    func nextInvoiceNumber(offset: Int = 0) -> String {
        let year = Calendar.current.component(.year, from: Date())
        let prefix = "\(year)-"
        let last = invoices.compactMap { f -> Int? in
            guard let n = f.number, n.hasPrefix(prefix) else { return nil }
            return Int(n.dropFirst(prefix.count))
        }.max() ?? 0
        return prefix + String(format: "%03d", last + 1 + offset)
    }

    /// Fatturato per cliente (imponibile, tutto lo storico) — per la classifica.
    func revenueByClient() -> [(client: NCClient, cents: Int)] {
        clients.map { c in
            (c, invoices.filter { $0.client_id == c.id && $0.status == "paid" }
                .reduce(0) { $0 + $1.amount_cents })
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
    }

    func content(on day: Date) -> [NCContent] {
        let key = ncDayString(day)
        return content.filter { $0.publish_date == key }
    }
    /// Contenuti dei prossimi `days` giorni, non ancora pubblicati.
    func upcomingContent(days: Int = 7) -> [NCContent] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: today) else { return [] }
        return content.filter {
            guard $0.status != "published", let d = ncParseDate($0.publish_date) else { return false }
            return d >= today && d <= end
        }
        .sorted { ($0.publish_date ?? "") < ($1.publish_date ?? "") }
    }
}
