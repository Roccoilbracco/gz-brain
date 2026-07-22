import SwiftUI

// ============================================================================
// NCREATIVE — Content: calendario editoriale mensile + board per stato,
// e sotto le campagne per cliente.
// ============================================================================

struct NCContentView: View {
    @ObservedObject var model: NCModel
    @State private var mese = Date()
    @State private var vista = "calendar"            // calendar | board
    @State private var clienteFiltro: String?
    @State private var mostraForm = false
    @State private var inModifica: NCContent?
    @State private var giornoNuovo: Date?
    @State private var mostraCampagna = false
    @State private var campagnaInModifica: NCCampaign?

    private var meseKey: String { ncMonthKey(mese) }

    private var visibili: [NCContent] {
        model.content.filter { clienteFiltro == nil || $0.client_id == clienteFiltro }
    }
    private var delMese: [NCContent] {
        visibili.filter { ($0.publish_date ?? "").hasPrefix(meseKey) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatTile(label: "Planned this month", value: delMese.count)
                StatTile(label: "Published", value: delMese.filter { $0.status == "published" }.count)
                StatTile(label: "In review", value: visibili.filter { $0.status == "review" }.count, evidenzia: true)
                StatTile(label: "Active campaigns", value: model.campaigns.filter { $0.status == "active" }.count)
            }

            SectionCard(title: "Content calendar", count: delMese.count, icon: "calendar") {
                HStack(spacing: 6) {
                    FilterChip(label: "Calendar", icon: "calendar", selected: vista == "calendar") { vista = "calendar" }
                    FilterChip(label: "Board", icon: "square.grid.3x1.below.line.grid.1x2", selected: vista == "board") { vista = "board" }
                    clientMenu
                    GhostButton(label: "New post", icon: "plus") {
                        inModifica = nil; giornoNuovo = nil; mostraForm = true
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    if vista == "calendar" {
                        meseNav
                        NCCalendarGrid(
                            month: mese,
                            items: visibili,
                            onNew: { day in inModifica = nil; giornoNuovo = day; mostraForm = true },
                            onOpen: { c in giornoNuovo = nil; inModifica = c; mostraForm = true }
                        )
                    } else {
                        NCContentBoard(
                            items: visibili,
                            clientName: { model.clientName($0) },
                            onDrop: { id, st in Task { await model.setContentStatus(id, st) } },
                            onOpen: { c in giornoNuovo = nil; inModifica = c; mostraForm = true }
                        )
                    }
                }
            }

            SectionCard(title: "Campaigns", count: model.campaigns.count, icon: "flag") {
                GhostButton(label: "New campaign", icon: "plus") {
                    campagnaInModifica = nil; mostraCampagna = true
                }
            } content: {
                if model.campaigns.isEmpty {
                    NCEmpty(text: "No campaigns yet.")
                } else {
                    VStack(spacing: 5) {
                        NCHeaderRow(cols: [("Campaign", nil), ("Client", 160), ("Period", 150),
                                           ("Budget", 90), ("Status", 80)])
                        ForEach(model.campaigns) { c in
                            NCRow(action: { campagnaInModifica = c; mostraCampagna = true }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(UI.ink).lineLimit(1)
                                    if let k = ncClean(c.kind) {
                                        Text(k).font(.system(size: 10)).foregroundStyle(UI.faint)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(model.clientName(c.client_id))
                                    .font(.system(size: 11.5)).foregroundStyle(UI.text)
                                    .frame(width: 160, alignment: .leading).lineLimit(1)

                                Text("\(ncShortDate(c.start_date)) → \(ncShortDate(c.end_date))")
                                    .font(.system(size: 11)).foregroundStyle(UI.dim)
                                    .frame(width: 150, alignment: .leading)

                                Text(c.budget_cents > 0 ? ncEuro(c.budget_cents) : "—")
                                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(c.budget_cents > 0 ? UI.ink : UI.faint)
                                    .frame(width: 90, alignment: .leading)

                                StatusPill(label: c.status.replacingOccurrences(of: "_", with: " ").capitalized,
                                           tint: c.status == "active" ? UI.tint(.ok)
                                               : (c.status == "done" ? UI.tint(.neutro) : UI.tint(.attesa)))
                                    .frame(width: 80, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $mostraForm, onDismiss: { inModifica = nil; giornoNuovo = nil }) {
            NCContentForm(existing: inModifica, defaultDate: giornoNuovo, model: model)
        }
        .sheet(isPresented: $mostraCampagna, onDismiss: { campagnaInModifica = nil }) {
            NCCampaignForm(existing: campagnaInModifica, model: model)
        }
    }

    private var clientMenu: some View {
        Menu {
            Button("All clients") { clienteFiltro = nil }
            ForEach(model.clients) { c in Button(c.name) { clienteFiltro = c.id } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle").font(.system(size: 9))
                Text(clienteFiltro == nil ? "All clients" : model.clientName(clienteFiltro))
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(clienteFiltro == nil ? UI.dim : UI.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(clienteFiltro == nil ? UI.surface : UI.accent.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(clienteFiltro == nil ? UI.line : .clear, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var meseNav: some View {
        HStack(spacing: 8) {
            navBtn("chevron.left") { shift(-1) }
            Text(ncMonthLabel(mese))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.ink)
                .frame(width: 150, alignment: .center)
            navBtn("chevron.right") { shift(1) }
            GhostButton(label: "Today") { mese = Date() }
            Spacer(minLength: 0)
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
        if let d = Calendar.current.date(byAdding: .month, value: n, to: mese) { mese = d }
    }
}

// ── Griglia del mese ─────────────────────────────────────────────────────────

private struct NCCalendarGrid: View {
    let month: Date
    let items: [NCContent]
    let onNew: (Date) -> Void
    let onOpen: (NCContent) -> Void

    /// Settimana che parte da lunedì, con le celle vuote iniziali del mese.
    private var giorni: [Date?] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let weekday = cal.component(.weekday, from: start)          // 1 = domenica
        let offset = (weekday + 5) % 7                               // 0 = lunedì
        var out: [Date?] = Array(repeating: nil, count: offset)
        for d in range { out.append(cal.date(byAdding: .day, value: d - 1, to: start)) }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }

    private func onDay(_ d: Date) -> [NCContent] {
        let key = ncDayString(d)
        return items.filter { $0.publish_date == key }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { d in
                    Text(d.uppercased()).font(.system(size: 8.5, weight: .bold)).tracking(1)
                        .foregroundStyle(UI.faint).frame(maxWidth: .infinity)
                }
            }
            let cells = giorni
            ForEach(0..<(cells.count / 7), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { col in
                        let day = cells[row * 7 + col]
                        NCDayCell(day: day, items: day.map { onDay($0) } ?? [],
                                  onNew: onNew, onOpen: onOpen)
                    }
                }
            }
        }
    }
}

private struct NCDayCell: View {
    let day: Date?
    let items: [NCContent]
    let onNew: (Date) -> Void
    let onOpen: (NCContent) -> Void
    @State private var hover = false

    private var isToday: Bool {
        guard let day else { return false }
        return Calendar.current.isDateInToday(day)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let day {
                HStack(spacing: 4) {
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.system(size: 10.5, weight: isToday ? .bold : .medium)).monospacedDigit()
                        .foregroundStyle(isToday ? UI.accent : UI.dim)
                    Spacer(minLength: 0)
                    if hover {
                        Button { onNew(day) } label: {
                            Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(UI.faint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(items.prefix(3)) { c in
                    Button { onOpen(c) } label: {
                        HStack(spacing: 3) {
                            Circle().fill(NCContentStatus.from(c.status).color).frame(width: 4, height: 4)
                            Text(NCPlatform.from(c.platform).short)
                                .font(.system(size: 7.5, weight: .bold)).foregroundStyle(UI.faint)
                            Text(c.title).font(.system(size: 9.5)).foregroundStyle(UI.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(UI.surfaceHi))
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                if items.count > 3 {
                    Text("+\(items.count - 3) more").font(.system(size: 8.5)).foregroundStyle(UI.faint)
                        .padding(.leading, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(day == nil ? Color.clear : (hover ? UI.surfaceHi : UI.surface)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(day == nil ? Color.clear : (isToday ? UI.accent.opacity(0.5) : UI.line), lineWidth: 1))
        .onHover { hover = $0 && day != nil }
    }
}

// ── Board per stato ──────────────────────────────────────────────────────────

private struct NCContentBoard: View {
    let items: [NCContent]
    let clientName: (String?) -> String
    let onDrop: (String, NCContentStatus) -> Void
    let onOpen: (NCContent) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(NCContentStatus.allCases) { st in
                    NCContentColumn(status: st, items: items.filter { $0.status == st.rawValue },
                                    clientName: clientName, onDrop: onDrop, onOpen: onOpen)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

private struct NCContentColumn: View {
    let status: NCContentStatus
    let items: [NCContent]
    let clientName: (String?) -> String
    let onDrop: (String, NCContentStatus) -> Void
    let onOpen: (NCContent) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(status.label.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.9)
                    .foregroundStyle(UI.dim)
                Spacer(minLength: 4)
                Text("\(items.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(items.isEmpty ? UI.faint : UI.text)
            }
            .padding(.horizontal, 2)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(c.title).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(UI.ink).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(clientName(c.client_id)).font(.system(size: 10.5))
                                .foregroundStyle(UI.faint).lineLimit(1)
                            HStack(spacing: 6) {
                                Label(NCPlatform.from(c.platform).label,
                                      systemImage: NCPlatform.from(c.platform).icon)
                                    .font(.system(size: 9.5)).foregroundStyle(UI.dim)
                                Spacer(minLength: 4)
                                Text(ncShortDate(c.publish_date)).font(.system(size: 9.5))
                                    .foregroundStyle(UI.faint)
                            }
                        }
                        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panel))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { onOpen(c) }
                        .draggable(c.id)
                    }
                    if items.isEmpty {
                        Text("Empty").font(.system(size: 10.5)).foregroundStyle(UI.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                .padding(2)
            }
        }
        .frame(width: 200)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? UI.accent.opacity(0.10) : UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(targeted ? UI.accent.opacity(0.55) : UI.line, lineWidth: 1))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }; onDrop(id, status); return true
        } isTargeted: { targeted = $0 }
    }
}

// ── Form contenuto ───────────────────────────────────────────────────────────

struct NCContentForm: View {
    let existing: NCContent?
    let defaultDate: Date?
    @ObservedObject var model: NCModel

    @State private var title = ""
    @State private var clientId: String?
    @State private var campaignId: String?
    @State private var platform = NCPlatform.instagram.rawValue
    @State private var format = "post"
    @State private var status = NCContentStatus.idea.rawValue
    @State private var owner = ""
    @State private var link = ""
    @State private var notes = ""
    @State private var publish = Date()
    @State private var hasPublish = true

    private var eliminazione: (() async -> Void)? {
        guard let c = existing else { return nil }
        return { await model.delete("nc_content", id: c.id); await model.load() }
    }
    private var campagneCliente: [NCCampaign] {
        model.campaigns.filter { clientId == nil || $0.client_id == clientId }
    }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New content" : "Edit content",
            canSave: !title.trimmingCharacters(in: .whitespaces).isEmpty,
            onDelete: eliminazione,
            onSave: salva
        ) {
            NCField(label: "Title", text: $title, hint: "e.g. Reel — behind the scenes")
            NCClientPicker(label: "Client", clients: model.clients, clientId: $clientId)
            NCLabeled(label: "Campaign") {
                Menu {
                    Button("No campaign") { campaignId = nil }
                    ForEach(campagneCliente) { c in Button(c.name) { campaignId = c.id } }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.campaigns.first { $0.id == campaignId }?.name ?? "No campaign")
                            .font(.system(size: 12.5))
                            .foregroundStyle(campaignId == nil ? UI.faint : UI.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(UI.faint)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            }
            NCChips(label: "Platform", options: NCPlatform.allCases.map { ($0.rawValue, $0.label) },
                    selection: $platform)
            NCChips(label: "Format", options: NC_FORMATS.map { ($0, $0.capitalized) }, selection: $format)
            NCChips(label: "Status", options: NCContentStatus.allCases.map { ($0.rawValue, $0.label) },
                    selection: $status)
            NCDateField(label: "Publish date", date: $publish, enabled: $hasPublish)
            HStack(spacing: 12) {
                NCField(label: "Owner", text: $owner, hint: "Who makes it")
                NCField(label: "Link", text: $link, hint: "Drive, Figma, post URL…")
            }
            NCTextArea(label: "Notes / caption", text: $notes, height: 90)
        }
        .onAppear(perform: precompila)
    }

    private func precompila() {
        if let d = defaultDate { publish = d; hasPublish = true }
        guard let c = existing else { return }
        title = c.title; clientId = c.client_id; campaignId = c.campaign_id
        platform = c.platform; format = c.format ?? "post"; status = c.status
        owner = c.owner ?? ""; link = c.link ?? ""; notes = c.notes ?? ""
        if let d = ncParseDate(c.publish_date) { publish = d; hasPublish = true } else { hasPublish = false }
    }

    private func salva() async throws {
        let fields: [String: Any?] = [
            "title": title.trimmingCharacters(in: .whitespaces),
            "client_id": clientId, "campaign_id": campaignId,
            "platform": platform, "format": format, "status": status,
            "publish_date": hasPublish ? ncDayString(publish) : nil,
            "owner": ncBlank(owner), "link": ncBlank(link), "notes": ncBlank(notes),
        ]
        if let c = existing { try await HubAPI.ncUpdate("nc_content", id: c.id, fields) }
        else { try await HubAPI.ncInsert("nc_content", fields) }
        await model.load()
    }
}

// ── Form campagna ────────────────────────────────────────────────────────────

struct NCCampaignForm: View {
    let existing: NCCampaign?
    @ObservedObject var model: NCModel

    @State private var name = ""
    @State private var clientId: String?
    @State private var kind = "campaign"
    @State private var status = "active"
    @State private var budget = ""
    @State private var notes = ""
    @State private var start = Date()
    @State private var hasStart = false
    @State private var end = Date()
    @State private var hasEnd = false

    private var eliminazione: (() async -> Void)? {
        guard let c = existing else { return nil }
        return { await model.delete("nc_campaigns", id: c.id); await model.load() }
    }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New campaign" : "Edit campaign",
            canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
            onDelete: eliminazione,
            onSave: salva
        ) {
            NCField(label: "Campaign", text: $name, hint: "e.g. Summer launch")
            NCClientPicker(label: "Client", clients: model.clients, clientId: $clientId)
            NCChips(label: "Type", options: [("campaign", "Campaign"), ("retainer", "Retainer"),
                                             ("launch", "Launch"), ("one-off", "One-off")], selection: $kind)
            NCChips(label: "Status", options: NC_CAMPAIGN_STATUSES.map {
                ($0, $0.replacingOccurrences(of: "_", with: " ").capitalized)
            }, selection: $status)
            NCMoneyField(label: "Budget", text: $budget)
            NCDateField(label: "Start", date: $start, enabled: $hasStart)
            NCDateField(label: "End", date: $end, enabled: $hasEnd)
            NCTextArea(label: "Notes", text: $notes)
        }
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let c = existing else { return }
        name = c.name; clientId = c.client_id; kind = c.kind ?? "campaign"; status = c.status
        notes = c.notes ?? ""
        budget = c.budget_cents > 0 ? String(format: "%.2f", Double(c.budget_cents) / 100) : ""
        if let d = ncParseDate(c.start_date) { start = d; hasStart = true }
        if let d = ncParseDate(c.end_date) { end = d; hasEnd = true }
    }

    private func salva() async throws {
        let fields: [String: Any?] = [
            "name": name.trimmingCharacters(in: .whitespaces), "client_id": clientId,
            "kind": kind, "status": status, "budget_cents": ncCents(budget),
            "start_date": hasStart ? ncDayString(start) : nil,
            "end_date": hasEnd ? ncDayString(end) : nil,
            "notes": ncBlank(notes),
        ]
        if let c = existing { try await HubAPI.ncUpdate("nc_campaigns", id: c.id, fields) }
        else { try await HubAPI.ncInsert("nc_campaigns", fields) }
        await model.load()
    }
}
