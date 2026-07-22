import SwiftUI

// ============================================================================
// NCREATIVE — Pipeline: lead in entrata e preventivi, board kanban con
// drag&drop lungo gli stadi (stessa meccanica della board Wallis).
// ============================================================================

struct NCPipelineView: View {
    @ObservedObject var model: NCModel
    @State private var search = ""
    @State private var mostraForm = false
    @State private var inModifica: NCDeal?

    private var filtered: [NCDeal] {
        model.deals.filter { d in
            guard !search.isEmpty else { return true }
            return [d.title, d.contact_name ?? "", d.email ?? "", d.phone ?? "",
                    model.clientName(d.client_id), d.notes ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private func inStage(_ s: NCStage) -> [NCDeal] { filtered.filter { $0.stage == s.rawValue } }

    private var wonThisMonth: Int {
        let m = ncMonthKey(Date())
        return model.deals.filter { $0.stage == "won" && ($0.created_at ?? "").hasPrefix(m) }
            .reduce(0) { $0 + $1.value_cents }
    }
    /// Vinte sul totale delle chiuse: le trattative aperte non contano.
    private var winRate: Int {
        let closed = model.deals.filter { NCStage.from($0.stage).isClosed }.count
        guard closed > 0 else { return 0 }
        let won = model.deals.filter { $0.stage == "won" }.count
        return Int((Double(won) / Double(closed) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatTile(label: "Open deals", value: model.openDeals.count, evidenzia: true)
                StatTile(label: "Pipeline value", testo: ncEuro(model.pipelineCents))
                StatTile(label: "Won this month", testo: ncEuro(wonThisMonth))
                StatTile(label: "Win rate", testo: winRate > 0 ? "\(winRate)%" : "—")
            }

            SectionCard(title: "Deals", count: filtered.count, icon: "chart.bar.doc.horizontal") {
                HStack(spacing: 6) {
                    HoloSearchField(placeholder: "Search deal…", text: $search, width: 150)
                    GhostButton(label: "New deal", icon: "plus") { inModifica = nil; mostraForm = true }
                }
            } content: {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(NCStage.allCases) { stage in
                            NCStageColumn(
                                stage: stage,
                                items: inStage(stage),
                                clientName: { model.clientName($0) },
                                onDrop: { id in Task { await model.setDealStage(id, stage) } },
                                onSelect: { d in inModifica = d; mostraForm = true }
                            )
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .sheet(isPresented: $mostraForm, onDismiss: { inModifica = nil }) {
            NCDealForm(existing: inModifica, model: model)
        }
    }
}

private struct NCStageColumn: View {
    let stage: NCStage
    let items: [NCDeal]
    let clientName: (String?) -> String
    let onDrop: (String) -> Void
    let onSelect: (NCDeal) -> Void
    @State private var targeted = false

    private var totale: Int { items.reduce(0) { $0 + $1.value_cents } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(stage.color).frame(width: 6, height: 6)
                Text(stage.label.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.9)
                    .foregroundStyle(UI.dim).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(items.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(items.isEmpty ? UI.faint : UI.text)
            }
            .padding(.horizontal, 2)

            Text(totale > 0 ? ncEuro(totale) : " ")
                .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(UI.faint).padding(.horizontal, 2)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(items) { d in
                        NCDealCard(deal: d, client: clientName(d.client_id))
                            .onTapGesture { onSelect(d) }
                            .draggable(d.id)
                    }
                    if items.isEmpty {
                        Text("Empty").font(.system(size: 10.5)).foregroundStyle(UI.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                .padding(2)
            }
        }
        .frame(width: 218)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(targeted ? UI.accent.opacity(0.10) : UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(targeted ? UI.accent.opacity(0.55) : UI.line, lineWidth: 1))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }; onDrop(id); return true
        } isTargeted: { targeted = $0 }
    }
}

private struct NCDealCard: View {
    let deal: NCDeal
    let client: String
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(deal.title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(UI.ink).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if client != "—" {
                Text(client).font(.system(size: 10.5)).foregroundStyle(UI.faint).lineLimit(1)
            } else if let c = ncClean(deal.contact_name) {
                Text(c).font(.system(size: 10.5)).foregroundStyle(UI.faint).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(deal.value_cents > 0 ? ncEuro(deal.value_cents) : "—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(UI.text)
                if deal.recurring {
                    Text("/mo").font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.accent)
                }
                Spacer(minLength: 4)
                if let close = ncClean(deal.expected_close) {
                    Text(ncShortDate(close)).font(.system(size: 9.5)).foregroundStyle(UI.faint)
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? UI.surfaceHi : UI.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hover = $0 }
    }
}

// ── Form deal ────────────────────────────────────────────────────────────────

struct NCDealForm: View {
    let existing: NCDeal?
    @ObservedObject var model: NCModel

    @State private var title = ""
    @State private var clientId: String?
    @State private var contact = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var stage = NCStage.new.rawValue
    @State private var value = ""
    @State private var recurring = false
    @State private var source = ""
    @State private var notes = ""
    @State private var close = Date()
    @State private var hasClose = false

    private var eliminazione: (() async -> Void)? {
        guard let d = existing else { return nil }
        return { await model.delete("nc_deals", id: d.id); await model.load() }
    }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New deal" : "Edit deal",
            canSave: !title.trimmingCharacters(in: .whitespaces).isEmpty,
            onDelete: eliminazione,
            onSave: salva
        ) {
            NCField(label: "Deal", text: $title, hint: "e.g. Instagram retainer — Bloom Studio")
            NCClientPicker(label: "Client", clients: model.clients, clientId: $clientId)
            HStack(spacing: 12) {
                NCField(label: "Contact", text: $contact, hint: "For leads with no client record")
                NCField(label: "Email", text: $email, hint: "name@brand.com")
            }
            HStack(spacing: 12) {
                NCField(label: "Phone", text: $phone, hint: "+34 …")
                NCField(label: "Source", text: $source, hint: "referral, instagram…")
            }
            NCChips(label: "Stage", options: NCStage.allCases.map { ($0.rawValue, $0.label) }, selection: $stage)
            HStack(spacing: 12) {
                NCMoneyField(label: "Value", text: $value)
                NCLabeled(label: "Billing") {
                    HStack(spacing: 6) {
                        FilterChip(label: "One-off", selected: !recurring) { recurring = false }
                        FilterChip(label: "Monthly", selected: recurring) { recurring = true }
                        Spacer(minLength: 0)
                    }
                }
            }
            NCDateField(label: "Expected close", date: $close, enabled: $hasClose)
            NCTextArea(label: "Notes", text: $notes)
        }
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let d = existing else { return }
        title = d.title; clientId = d.client_id; contact = d.contact_name ?? ""
        email = d.email ?? ""; phone = d.phone ?? ""; stage = d.stage
        recurring = d.recurring; source = d.source ?? ""; notes = d.notes ?? ""
        value = d.value_cents > 0 ? String(format: "%.2f", Double(d.value_cents) / 100) : ""
        if let c = ncParseDate(d.expected_close) { close = c; hasClose = true }
    }

    private func salva() async throws {
        let fields: [String: Any?] = [
            "title": title.trimmingCharacters(in: .whitespaces),
            "client_id": clientId, "contact_name": ncBlank(contact),
            "email": ncBlank(email), "phone": ncBlank(phone),
            "stage": stage, "value_cents": ncCents(value), "recurring": recurring,
            "source": ncBlank(source), "notes": ncBlank(notes),
            "expected_close": hasClose ? ncDayString(close) : nil,
            "updated_at": isoNowString(),
        ]
        if let d = existing { try await HubAPI.ncUpdate("nc_deals", id: d.id, fields) }
        else { try await HubAPI.ncInsert("nc_deals", fields) }
        await model.load()
    }
}
