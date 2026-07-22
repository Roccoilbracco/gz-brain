import SwiftUI

// ============================================================================
// NCREATIVE — Social Media.
// La domanda a cui risponde questa schermata: «com'è andata ieri?».
// I dati arrivano dal sync notturno (Edge Function `social-sync`) oppure a mano
// finché le API Meta non sono approvate: la UI è identica nei due casi, cambia
// solo la colonna `source`.
// ============================================================================

// ── Entità ───────────────────────────────────────────────────────────────────

struct NCSocialAccount: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var role: String                 // own | competitor
    var platform: String
    var handle: String
    var external_id: String?
    var page_id: String?
    var ad_account_id: String?
    var active: Bool
    var notes: String?
    let created_at: String?

    var isCompetitor: Bool { role == "competitor" }
    var atHandle: String { handle.hasPrefix("@") ? handle : "@\(handle)" }
}

struct NCSocialDay: Identifiable, Decodable, Equatable {
    let id: String
    var account_id: String
    var date: String
    var followers: Int?
    var posts: Int?
    var likes: Int
    var comments: Int
    var messages: Int
    var reach: Int?
    var impressions: Int?
    var profile_views: Int?
    var source: String

    var engagement: Int { likes + comments }
}

struct NCAdsDay: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var date: String
    var campaign: String?
    var spend_cents: Int
    var impressions: Int
    var clicks: Int
    var results: Int
    var likes: Int
    var comments: Int
    var messages: Int
    var source: String
}

struct NCInsight: Identifiable, Decodable, Equatable {
    let id: String
    var client_id: String?
    var kind: String                 // suggestion | audit
    var period: String?
    var date: String?
    var title: String?
    var body: String?
    var pinned: Bool
    let created_at: String?
}

// ── API ──────────────────────────────────────────────────────────────────────

extension HubAPI {
    static func ncSocialAccounts() async throws -> [NCSocialAccount] {
        try await sb.fetch("nc_social_accounts?select=*&order=role.asc,handle.asc&limit=2000")
    }
    /// Ultimi 60 giorni: bastano per il confronto con la media e per l'audit del mese.
    static func ncSocialDays() async throws -> [NCSocialDay] {
        let from = ncDayString(Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date())
        return try await sb.fetch("nc_social_daily?select=*&date=gte.\(from)&order=date.desc&limit=5000")
    }
    static func ncAdsDays() async throws -> [NCAdsDay] {
        let from = ncDayString(Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date())
        return try await sb.fetch("nc_ads_daily?select=*&date=gte.\(from)&order=date.desc&limit=5000")
    }
    static func ncInsights() async throws -> [NCInsight] {
        try await sb.fetch("nc_insights?select=*&order=created_at.desc&limit=500")
    }
}

@MainActor
final class NCSocialModel: ObservableObject {
    @Published var accounts: [NCSocialAccount] = []
    @Published var days: [NCSocialDay] = []
    @Published var ads: [NCAdsDay] = []
    @Published var insights: [NCInsight] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true
        do {
            async let a = HubAPI.ncSocialAccounts()
            async let d = HubAPI.ncSocialDays()
            async let s = HubAPI.ncAdsDays()
            async let i = HubAPI.ncInsights()
            let (x, y, z, w) = try await (a, d, s, i)
            accounts = x; days = y; ads = z; insights = w
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    func account(_ id: String) -> NCSocialAccount? { accounts.first { $0.id == id } }
    func ownAccounts(client: String?) -> [NCSocialAccount] {
        accounts.filter { $0.role == "own" && $0.active && (client == nil || $0.client_id == client) }
    }
    func competitors(of client: String?) -> [NCSocialAccount] {
        accounts.filter { $0.role == "competitor" && $0.active && $0.client_id == client }
    }
    func day(_ accountId: String, _ date: String) -> NCSocialDay? {
        days.first { $0.account_id == accountId && $0.date == date }
    }
    /// Media giornaliera dell'engagement nelle ultime `n` giornate registrate,
    /// escluso il giorno mostrato: serve a dire «meglio o peggio del solito».
    func avgEngagement(_ accountId: String, before date: String, days n: Int = 7) -> Int {
        let past = days.filter { $0.account_id == accountId && $0.date < date }
            .sorted { $0.date > $1.date }.prefix(n)
        guard !past.isEmpty else { return 0 }
        return past.reduce(0) { $0 + $1.engagement } / past.count
    }
    func adsFor(client: String?, date: String) -> [NCAdsDay] {
        ads.filter { $0.date == date && (client == nil || $0.client_id == client) }
    }

    func delete(_ table: String, id: String) async {
        switch table {
        case "nc_social_accounts": accounts.removeAll { $0.id == id }
        case "nc_social_daily": days.removeAll { $0.id == id }
        case "nc_ads_daily": ads.removeAll { $0.id == id }
        case "nc_insights": insights.removeAll { $0.id == id }
        default: break
        }
        try? await HubAPI.ncDelete(table, id: id)
    }
}

// ── Vista ────────────────────────────────────────────────────────────────────

enum NCSocialTab: String, CaseIterable, Identifiable {
    case daily, competitors, insights, accounts
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: return "Daily"
        case .competitors: return "Competitors"
        case .insights: return "Suggestions & audits"
        case .accounts: return "Accounts"
        }
    }
}

struct NCSocialView: View {
    @ObservedObject var model: NCModel
    @StateObject private var social = NCSocialModel()
    @State private var tab: NCSocialTab = .daily
    @State private var giorno = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var mostraLog = false
    @State private var mostraAccount = false
    @State private var accountInModifica: NCSocialAccount?

    private var key: String { ncDayString(giorno) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(NCSocialTab.allCases) { t in
                    FilterChip(label: t.label, selected: tab == t) { tab = t }
                }
                Spacer()
                GhostButton(label: "Log metrics", icon: "square.and.pencil") { mostraLog = true }
                GhostButton(label: "Refresh", icon: "arrow.clockwise") { Task { await social.load() } }
            }

            if social.loading && social.accounts.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 50)
            } else if let e = social.error {
                SectionCard(title: "Error") {
                    Text(e).font(.system(size: 12)).foregroundStyle(UI.tint(.stop))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if social.accounts.isEmpty {
                setupCard
            } else {
                switch tab {
                case .daily: dailyView
                case .competitors: competitorsView
                case .insights: insightsView
                case .accounts: accountsView
                }
            }
        }
        .task { await social.load() }
        .sheet(isPresented: $mostraLog) {
            NCSocialLogForm(social: social, clients: model.clients, day: giorno)
        }
        .sheet(isPresented: $mostraAccount, onDismiss: { accountInModifica = nil }) {
            NCSocialAccountForm(existing: accountInModifica, social: social, clients: model.clients)
        }
    }

    private var setupCard: some View {
        SectionCard(title: "Set up the social module", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add one account per client, plus the competitors you want to benchmark against. Until the Meta app is approved you can log the daily numbers by hand — the dashboard works the same either way.")
                    .font(.system(size: 12)).foregroundStyle(UI.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                GhostButton(label: "Add first account", icon: "plus") {
                    accountInModifica = nil; mostraAccount = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ── Giornaliera ──
    private var dailyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                navBtn("chevron.left") { shift(-1) }
                Text(ncLongDate(key))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.ink)
                    .frame(width: 170, alignment: .center)
                navBtn("chevron.right") { shift(1) }
                GhostButton(label: "Yesterday") {
                    giorno = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                }
                Spacer()
            }

            let own = social.ownAccounts(client: nil)
            let righe = own.compactMap { social.day($0.id, key) }
            let ads = social.adsFor(client: nil, date: key)

            HStack(spacing: 10) {
                StatTile(label: "Likes", value: righe.reduce(0) { $0 + $1.likes })
                StatTile(label: "Comments", value: righe.reduce(0) { $0 + $1.comments })
                StatTile(label: "Messages", value: righe.reduce(0) { $0 + $1.messages }, evidenzia: true)
                StatTile(label: "Ads spend", testo: ncEuro(ads.reduce(0) { $0 + $1.spend_cents }))
                StatTile(label: "Accounts covered", testo: "\(righe.count)/\(own.count)")
            }

            SectionCard(title: "Client highlights", count: own.count, icon: "star") {
                if own.isEmpty {
                    NCEmpty(text: "No client accounts yet.")
                } else {
                    VStack(spacing: 5) {
                        NCHeaderRow(cols: [("Client", nil), ("Account", 140), ("Followers", 90),
                                           ("Likes", 70), ("Comments", 80), ("Messages", 80), ("vs 7d avg", 90)])
                        ForEach(own) { acc in
                            let d = social.day(acc.id, key)
                            let avg = social.avgEngagement(acc.id, before: key)
                            NCRow(action: { mostraLog = true }) {
                                Text(model.clientName(acc.client_id))
                                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                HStack(spacing: 4) {
                                    Image(systemName: NCPlatform.from(acc.platform).icon)
                                        .font(.system(size: 9)).foregroundStyle(UI.faint)
                                    Text(acc.atHandle).font(.system(size: 11)).foregroundStyle(UI.dim)
                                        .lineLimit(1)
                                }
                                .frame(width: 140, alignment: .leading)
                                numero(d?.followers, width: 90)
                                numero(d?.likes, width: 70)
                                numero(d?.comments, width: 80)
                                numero(d?.messages, width: 80)
                                delta(d?.engagement, avg).frame(width: 90, alignment: .leading)
                            }
                        }
                    }
                }
            }

            SectionCard(title: "Paid campaigns", count: ads.count, icon: "megaphone") {
                if ads.isEmpty {
                    NCEmpty(text: "No ads logged for this day.")
                } else {
                    VStack(spacing: 5) {
                        NCHeaderRow(cols: [("Client", nil), ("Campaign", 160), ("Spend", 90),
                                           ("Likes", 70), ("Comments", 80), ("Messages", 80), ("Results", 80)])
                        ForEach(ads) { a in
                            NCRow(action: { mostraLog = true }) {
                                Text(model.clientName(a.client_id))
                                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                Text(ncClean(a.campaign) ?? "—").font(.system(size: 11.5))
                                    .foregroundStyle(UI.text).frame(width: 160, alignment: .leading).lineLimit(1)
                                Text(ncEuro(a.spend_cents)).font(.system(size: 11.5, weight: .semibold))
                                    .monospacedDigit().foregroundStyle(UI.ink)
                                    .frame(width: 90, alignment: .leading)
                                numero(a.likes, width: 70)
                                numero(a.comments, width: 80)
                                numero(a.messages, width: 80)
                                numero(a.results, width: 80)
                            }
                        }
                    }
                }
            }

            let sugg = social.insights.filter { $0.kind == "suggestion" }.prefix(4)
            if !sugg.isEmpty {
                SectionCard(title: "Suggestions", count: sugg.count, icon: "lightbulb") {
                    VStack(spacing: 8) {
                        ForEach(Array(sugg)) { s in
                            NCInsightCard(insight: s, client: model.clientName(s.client_id))
                        }
                    }
                }
            }
        }
    }

    // ── Competitor ──
    private var competitorsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.clients.filter { c in !social.ownAccounts(client: c.id).isEmpty }) { c in
                let own = social.ownAccounts(client: c.id)
                let comps = social.competitors(of: c.id)
                SectionCard(title: c.name, count: comps.count, icon: "person.2.slash") {
                    GhostButton(label: "Add competitor", icon: "plus") {
                        accountInModifica = nil; mostraAccount = true
                    }
                } content: {
                    VStack(spacing: 5) {
                        NCHeaderRow(cols: [("Account", nil), ("Followers", 100), ("Likes", 80),
                                           ("Comments", 90), ("Engagement", 100)])
                        ForEach(own + comps) { acc in
                            let d = social.day(acc.id, key)
                            HStack(spacing: 10) {
                                HStack(spacing: 5) {
                                    if !acc.isCompetitor {
                                        Text("US").font(.system(size: 8, weight: .black))
                                            .foregroundStyle(UI.accent)
                                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                                            .background(Capsule().fill(UI.accent.opacity(0.15)))
                                    }
                                    Text(acc.atHandle)
                                        .font(.system(size: 12, weight: acc.isCompetitor ? .regular : .semibold))
                                        .foregroundStyle(acc.isCompetitor ? UI.text : UI.ink).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                numero(d?.followers, width: 100)
                                numero(d?.likes, width: 80)
                                numero(d?.comments, width: 90)
                                numero(d?.engagement, width: 100)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(acc.isCompetitor ? UI.surface : UI.accent.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
                        }
                        if comps.isEmpty {
                            NCEmpty(text: "No competitors mapped for \(c.name) yet.")
                        }
                    }
                }
            }
            if model.clients.isEmpty {
                NCEmpty(text: "Add clients first, then map their competitors.")
            }
        }
    }

    // ── Suggerimenti e audit ──
    private var insightsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard(title: "Monthly audits",
                        count: social.insights.filter { $0.kind == "audit" }.count, icon: "doc.text.magnifyingglass") {
                let audits = social.insights.filter { $0.kind == "audit" }
                if audits.isEmpty {
                    NCEmpty(text: "No audits yet. They are generated monthly from the daily data, one per client.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(audits) { a in
                            NCInsightCard(insight: a, client: model.clientName(a.client_id), expandable: true)
                        }
                    }
                }
            }
            SectionCard(title: "All suggestions",
                        count: social.insights.filter { $0.kind == "suggestion" }.count, icon: "lightbulb") {
                let sugg = social.insights.filter { $0.kind == "suggestion" }
                if sugg.isEmpty {
                    NCEmpty(text: "No suggestions yet.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(sugg) { s in
                            NCInsightCard(insight: s, client: model.clientName(s.client_id))
                        }
                    }
                }
            }
        }
    }

    // ── Account ──
    private var accountsView: some View {
        SectionCard(title: "Tracked accounts", count: social.accounts.count, icon: "at") {
            GhostButton(label: "Add account", icon: "plus") { accountInModifica = nil; mostraAccount = true }
        } content: {
            VStack(spacing: 5) {
                NCHeaderRow(cols: [("Handle", nil), ("Client", 160), ("Platform", 110),
                                   ("Role", 100), ("IDs", 150)])
                ForEach(social.accounts) { a in
                    NCRow(action: { accountInModifica = a; mostraAccount = true }) {
                        Text(a.atHandle).font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.ink).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(model.clientName(a.client_id)).font(.system(size: 11.5))
                            .foregroundStyle(UI.text).frame(width: 160, alignment: .leading).lineLimit(1)
                        Label(NCPlatform.from(a.platform).label, systemImage: NCPlatform.from(a.platform).icon)
                            .font(.system(size: 11)).foregroundStyle(UI.dim)
                            .frame(width: 110, alignment: .leading)
                        StatusPill(label: a.isCompetitor ? "Competitor" : "Client",
                                   tint: a.isCompetitor ? UI.tint(.neutro) : UI.accent)
                            .frame(width: 100, alignment: .leading)
                        Text(ncClean(a.external_id) == nil ? "manual" : "linked")
                            .font(.system(size: 10.5)).foregroundStyle(UI.faint)
                            .frame(width: 150, alignment: .leading)
                    }
                }
                if social.accounts.isEmpty { NCEmpty(text: "No accounts yet.") }
            }
        }
    }

    // ── Pezzi comuni ──
    private func numero(_ v: Int?, width: CGFloat) -> some View {
        Text(v.map { "\($0)" } ?? "—")
            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(v == nil ? UI.faint : UI.ink)
            .frame(width: width, alignment: .leading)
    }

    /// Scostamento dell'engagement rispetto alla media: verde sopra, rosso sotto.
    private func delta(_ v: Int?, _ avg: Int) -> some View {
        Group {
            if let v, avg > 0 {
                let pct = Int((Double(v - avg) / Double(avg) * 100).rounded())
                Text(pct >= 0 ? "+\(pct)%" : "\(pct)%")
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(pct >= 0 ? UI.tint(.ok) : UI.tint(.stop))
            } else {
                Text("—").font(.system(size: 11.5)).foregroundStyle(UI.faint)
            }
        }
    }

    private func navBtn(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(UI.text)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    private func shift(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: n, to: giorno) { giorno = d }
    }
}

// ── Card suggerimento / audit ────────────────────────────────────────────────

private struct NCInsightCard: View {
    let insight: NCInsight
    let client: String
    var expandable = false
    @State private var aperto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: insight.kind == "audit" ? "doc.text.magnifyingglass" : "lightbulb")
                    .font(.system(size: 10)).foregroundStyle(UI.accent)
                Text(ncClean(insight.title) ?? (insight.kind == "audit" ? "Audit" : "Suggestion"))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink)
                Text(client).font(.system(size: 10.5)).foregroundStyle(UI.faint)
                Spacer(minLength: 6)
                Text(ncClean(insight.period) ?? ncShortDate(insight.date ?? insight.created_at))
                    .font(.system(size: 10)).foregroundStyle(UI.faint)
                if expandable {
                    Button(aperto ? "Close" : "Read") { aperto.toggle() }
                        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(UI.accent)
                }
            }
            if let b = ncClean(insight.body) {
                Text(b).font(.system(size: 11.5)).lineSpacing(3).foregroundStyle(UI.text)
                    .lineLimit(expandable && !aperto ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.line, lineWidth: 1))
    }
}

// ── Form account / competitor ────────────────────────────────────────────────

struct NCSocialAccountForm: View {
    let existing: NCSocialAccount?
    @ObservedObject var social: NCSocialModel
    let clients: [NCClient]

    @State private var handle = ""
    @State private var clientId: String?
    @State private var role = "own"
    @State private var platform = NCPlatform.instagram.rawValue
    @State private var externalId = ""
    @State private var pageId = ""
    @State private var adAccountId = ""
    @State private var notes = ""

    private var eliminazione: (() async -> Void)? {
        guard let a = existing else { return nil }
        return { await social.delete("nc_social_accounts", id: a.id); await social.load() }
    }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New account" : "Edit account",
            canSave: !handle.trimmingCharacters(in: .whitespaces).isEmpty && clientId != nil,
            onDelete: eliminazione,
            onSave: salva
        ) {
            NCField(label: "Handle", text: $handle, hint: "@brand")
            NCClientPicker(label: "Client", clients: clients, clientId: $clientId, allowNone: false)
            NCChips(label: "Role", options: [("own", "Client account"), ("competitor", "Competitor")],
                    selection: $role)
            NCChips(label: "Platform", options: NCPlatform.allCases.map { ($0.rawValue, $0.label) },
                    selection: $platform)
            Text("The IDs below are only needed for the automatic sync. Leave them empty while logging numbers by hand.")
                .font(.system(size: 10.5)).foregroundStyle(UI.faint)
            HStack(spacing: 12) {
                NCField(label: "IG user id", text: $externalId, hint: "1784…")
                NCField(label: "Facebook page id", text: $pageId, hint: "1029…")
            }
            NCField(label: "Ad account id", text: $adAccountId, hint: "act_123456")
            NCTextArea(label: "Notes", text: $notes)
        }
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let a = existing else { return }
        handle = a.handle; clientId = a.client_id; role = a.role; platform = a.platform
        externalId = a.external_id ?? ""; pageId = a.page_id ?? ""
        adAccountId = a.ad_account_id ?? ""; notes = a.notes ?? ""
    }

    private func salva() async throws {
        let fields: [String: Any?] = [
            "handle": handle.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: ""),
            "client_id": clientId, "role": role, "platform": platform,
            "external_id": ncBlank(externalId), "page_id": ncBlank(pageId),
            "ad_account_id": ncBlank(adAccountId), "notes": ncBlank(notes),
        ]
        if let a = existing { try await HubAPI.ncUpdate("nc_social_accounts", id: a.id, fields) }
        else { try await HubAPI.ncInsert("nc_social_accounts", fields) }
        await social.load()
    }
}

// ── Inserimento manuale delle metriche del giorno ────────────────────────────
// Ponte finché il sync Meta non è attivo: una riga per account, più le ads.

struct NCSocialLogForm: View {
    @ObservedObject var social: NCSocialModel
    let clients: [NCClient]
    let day: Date

    @State private var giorno = Date()
    @State private var accountId: String?
    @State private var followers = ""
    @State private var likes = ""
    @State private var comments = ""
    @State private var messages = ""
    @State private var reach = ""
    // blocco ads (facoltativo)
    @State private var adsClientId: String?
    @State private var campaign = ""
    @State private var spend = ""
    @State private var adLikes = ""
    @State private var adComments = ""
    @State private var adMessages = ""
    @State private var adResults = ""

    private var accountiOrdinati: [NCSocialAccount] { social.accounts.filter(\.active) }

    var body: some View {
        NCSheet(
            title: "Log metrics",
            canSave: accountId != nil || adsClientId != nil,
            onSave: salva
        ) {
            NCLabeled(label: "Day") {
                DatePicker("", selection: $giorno, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field)
            }

            Text("ACCOUNT").font(.system(size: 9, weight: .heavy)).tracking(1.4).foregroundStyle(UI.dim)
            NCLabeled(label: "Account") {
                Menu {
                    Button("None") { accountId = nil }
                    ForEach(accountiOrdinati) { a in
                        Button("\(a.atHandle) — \(a.isCompetitor ? "competitor" : "client")") { accountId = a.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(social.account(accountId ?? "")?.atHandle ?? "Pick an account")
                            .font(.system(size: 12.5))
                            .foregroundStyle(accountId == nil ? UI.faint : UI.text)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                            .foregroundStyle(UI.faint)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                NCField(label: "Followers", text: $followers, hint: "12500")
                NCField(label: "Reach", text: $reach, hint: "8400")
            }
            HStack(spacing: 12) {
                NCField(label: "Likes", text: $likes, hint: "0")
                NCField(label: "Comments", text: $comments, hint: "0")
                NCField(label: "Messages", text: $messages, hint: "0")
            }

            Text("PAID CAMPAIGN (OPTIONAL)")
                .font(.system(size: 9, weight: .heavy)).tracking(1.4).foregroundStyle(UI.dim)
            NCClientPicker(label: "Client", clients: clients, clientId: $adsClientId)
            HStack(spacing: 12) {
                NCField(label: "Campaign", text: $campaign, hint: "Summer launch")
                NCMoneyField(label: "Spend", text: $spend)
            }
            HStack(spacing: 12) {
                NCField(label: "Likes", text: $adLikes, hint: "0")
                NCField(label: "Comments", text: $adComments, hint: "0")
                NCField(label: "Messages", text: $adMessages, hint: "0")
                NCField(label: "Results", text: $adResults, hint: "0")
            }
        }
        .onAppear { giorno = day }
    }

    private func intero(_ s: String) -> Int { Int(s.filter(\.isNumber)) ?? 0 }
    private func interoOpz(_ s: String) -> Int? {
        let v = s.filter(\.isNumber); return v.isEmpty ? nil : Int(v)
    }

    private func salva() async throws {
        let key = ncDayString(giorno)
        if let acc = accountId {
            // upsert: rilogare lo stesso giorno corregge, non duplica
            let fields: [String: Any?] = [
                "account_id": acc, "date": key,
                "followers": interoOpz(followers), "reach": interoOpz(reach),
                "likes": intero(likes), "comments": intero(comments), "messages": intero(messages),
                "source": "manual",
            ]
            try await HubAPI.ncUpsert("nc_social_daily", fields, onConflict: "account_id,date")
        }
        if let cid = adsClientId {
            let fields: [String: Any?] = [
                "client_id": cid, "date": key, "campaign": ncBlank(campaign),
                "spend_cents": ncCents(spend), "likes": intero(adLikes),
                "comments": intero(adComments), "messages": intero(adMessages),
                "results": intero(adResults), "source": "manual",
            ]
            try await HubAPI.ncInsert("nc_ads_daily", fields)
        }
        await social.load()
    }
}
