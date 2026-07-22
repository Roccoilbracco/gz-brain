import SwiftUI

// ============================================================================
// NCREATIVE — dashboard di progetto (slug `ncreative`).
// Cinque sezioni: Overview · Clients · Pipeline · Content · Finance.
// ============================================================================

enum NCTab: String, CaseIterable, Identifiable {
    case overview, clients, pipeline, content, finance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: return "Overview"
        case .clients: return "Clients"
        case .pipeline: return "Pipeline"
        case .content: return "Content"
        case .finance: return "Finance"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .clients: return "person.2"
        case .pipeline: return "chart.bar.doc.horizontal"
        case .content: return "calendar"
        case .finance: return "eurosign.circle"
        }
    }
}

struct NCreativeDashboard: View {
    @StateObject private var model = NCModel()
    @State private var tab: NCTab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabBar

            if model.loading && model.clients.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 60)
            } else if let err = model.error {
                SectionCard(title: "Connection error") {
                    Text(err).font(.system(size: 12)).foregroundStyle(UI.tint(.stop))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                switch tab {
                case .overview: NCOverviewView(model: model)
                case .clients: NCClientsView(model: model)
                case .pipeline: NCPipelineView(model: model)
                case .content: NCContentView(model: model)
                case .finance: NCFinanceView(model: model)
                }
            }
        }
        .task { await model.load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NCREATIVE")
                    .font(.system(size: 20, weight: .semibold)).tracking(1.5).foregroundStyle(UI.ink)
                Text("Social media marketing agency — clients, pipeline, content and books")
                    .font(.system(size: 11.5)).foregroundStyle(UI.faint)
            }
            Spacer()
            GhostButton(label: "Refresh", icon: "arrow.clockwise") { Task { await model.load() } }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(NCTab.allCases) { t in
                FilterChip(label: t.label, icon: t.icon, selected: tab == t) { tab = t }
            }
            Spacer(minLength: 0)
        }
    }
}

// ── Overview ─────────────────────────────────────────────────────────────────

struct NCOverviewView: View {
    @ObservedObject var model: NCModel

    private var month: String { ncMonthKey(Date()) }

    /// Ultimi 6 mesi, dal più vecchio: (chiave "yyyy-MM", etichetta "Jul").
    private var lastMonths: [(key: String, label: String)] {
        let cal = Calendar.current
        return (0..<6).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .month, value: -back, to: Date()) else { return nil }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM"
            return (ncMonthKey(d), f.string(from: d))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatTile(label: "MRR", testo: ncEuro(model.mrrCents))
                StatTile(label: "Collected this month", testo: ncEuro(model.collectedCents(month: month)))
                StatTile(label: "Expenses this month", testo: ncEuro(model.spentCents(month: month)))
                StatTile(label: "Profit this month", testo: ncEuro(model.profitCents(month: month)))
            }
            HStack(spacing: 10) {
                StatTile(label: "Outstanding", testo: ncEuro(model.outstandingCents))
                StatTile(label: "Active clients", value: model.activeClients.count)
                StatTile(label: "Open deals", value: model.openDeals.count, evidenzia: true)
                StatTile(label: "Pipeline value", testo: ncEuro(model.pipelineCents))
            }

            SectionCard(title: "Collected vs expenses", icon: "chart.bar") {
                NCMonthlyBars(
                    months: lastMonths,
                    inCents: { model.collectedCents(month: $0) },
                    outCents: { model.spentCents(month: $0) }
                )
            }

            HStack(alignment: .top, spacing: 14) {
                SectionCard(title: "Next 7 days", count: model.upcomingContent().count, icon: "calendar") {
                    let items = model.upcomingContent()
                    if items.isEmpty {
                        NCEmpty(text: "Nothing scheduled — good time to plan.")
                    } else {
                        VStack(spacing: 6) {
                            ForEach(items.prefix(6)) { c in
                                HStack(spacing: 8) {
                                    Text(ncShortDate(c.publish_date))
                                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(UI.dim).frame(width: 46, alignment: .leading)
                                    Text(NCPlatform.from(c.platform).short)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(UI.faint).frame(width: 22, alignment: .leading)
                                    Text(c.title).font(.system(size: 12)).foregroundStyle(UI.text).lineLimit(1)
                                    Spacer(minLength: 6)
                                    StatusPill(label: NCContentStatus.from(c.status).label,
                                               tint: NCContentStatus.from(c.status).color)
                                }
                            }
                        }
                    }
                }

                SectionCard(title: "Unpaid invoices",
                            count: model.invoices.filter { $0.status == "sent" }.count,
                            icon: "exclamationmark.circle") {
                    let unpaid = model.invoices.filter { $0.status == "sent" }
                        .sorted { ($0.due_date ?? "") < ($1.due_date ?? "") }
                    if unpaid.isEmpty {
                        NCEmpty(text: "Everything is paid up.")
                    } else {
                        VStack(spacing: 6) {
                            ForEach(unpaid.prefix(6)) { f in
                                HStack(spacing: 8) {
                                    Text(model.clientName(f.client_id))
                                        .font(.system(size: 12)).foregroundStyle(UI.text).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(ncEuro(f.totalCents))
                                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(UI.ink)
                                    StatusPill(label: f.isOverdue ? "Overdue" : "Due \(ncShortDate(f.due_date))",
                                               tint: f.isOverdue ? UI.tint(.stop) : UI.tint(.attesa))
                                }
                            }
                        }
                    }
                }
            }

            SectionCard(title: "Top clients by revenue", icon: "trophy") {
                let rows = model.revenueByClient()
                if rows.isEmpty {
                    NCEmpty(text: "No paid invoices yet.")
                } else {
                    let max = rows.first?.cents ?? 1
                    VStack(spacing: 7) {
                        ForEach(rows.prefix(6), id: \.client.id) { r in
                            HStack(spacing: 10) {
                                Text(r.client.name).font(.system(size: 12)).foregroundStyle(UI.text)
                                    .frame(width: 150, alignment: .leading).lineLimit(1)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(UI.surface)
                                        Capsule().fill(UI.accent.opacity(0.75))
                                            .frame(width: geo.size.width * CGFloat(r.cents) / CGFloat(max))
                                    }
                                }
                                .frame(height: 7)
                                Text(ncEuro(r.cents)).font(.system(size: 11.5, weight: .semibold))
                                    .monospacedDigit().foregroundStyle(UI.ink)
                                    .frame(width: 90, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Barre affiancate incassi/spese per mese.
struct NCMonthlyBars: View {
    let months: [(key: String, label: String)]
    let inCents: (String) -> Int
    let outCents: (String) -> Int

    private var peak: Int {
        let v = months.flatMap { [inCents($0.key), outCents($0.key)] }.max() ?? 0
        return Swift.max(v, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(months, id: \.key) { m in
                    VStack(spacing: 6) {
                        HStack(alignment: .bottom, spacing: 4) {
                            bar(inCents(m.key), color: UI.accent)
                            bar(outCents(m.key), color: UI.tint(.attesa))
                        }
                        .frame(height: 90)
                        Text(m.label.uppercased())
                            .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(UI.faint)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 14) {
                legend("Collected", UI.accent)
                legend("Expenses", UI.tint(.attesa))
                Spacer()
                Text("Peak \(ncEuro(peak))").font(.system(size: 9.5)).foregroundStyle(UI.faint)
            }
        }
    }

    private func bar(_ cents: Int, color: Color) -> some View {
        // altezza minima 2pt: un mese a zero resta comunque leggibile come riga
        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.8))
            .frame(width: 16, height: Swift.max(2, 90 * CGFloat(cents) / CGFloat(peak)))
            .help(ncEuro(cents))
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.8)).frame(width: 9, height: 9)
            Text(label).font(.system(size: 10)).foregroundStyle(UI.dim)
        }
    }
}
