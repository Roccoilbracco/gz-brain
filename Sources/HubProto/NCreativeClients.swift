import SwiftUI

// ============================================================================
// NCREATIVE — Clients: anagrafica, contratto (retainer + servizi), storico
// fatturato. Il cliente nasce come `lead` e diventa `active` quando firma.
// ============================================================================

struct NCClientsView: View {
    @ObservedObject var model: NCModel
    @State private var search = ""
    @State private var filtro: NCClientStatus?
    @State private var mostraForm = false
    @State private var inModifica: NCClient?

    private var filtered: [NCClient] {
        model.clients.filter { c in
            if let f = filtro, c.status != f.rawValue { return false }
            guard !search.isEmpty else { return true }
            return [c.name, c.contact_name ?? "", c.email ?? "", c.instagram ?? "", c.notes ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatTile(label: "Clients", value: model.clients.count)
                StatTile(label: "Active", value: model.activeClients.count)
                StatTile(label: "MRR", testo: ncEuro(model.mrrCents))
                StatTile(label: "Avg. retainer",
                         testo: ncEuro(model.activeClients.isEmpty ? 0 : model.mrrCents / model.activeClients.count))
            }

            SectionCard(title: "Clients", count: filtered.count, icon: "person.2") {
                HStack(spacing: 6) {
                    FilterChip(label: "All", selected: filtro == nil) { filtro = nil }
                    ForEach(NCClientStatus.allCases) { s in
                        FilterChip(label: s.label, selected: filtro == s) { filtro = filtro == s ? nil : s }
                    }
                    HoloSearchField(placeholder: "Search client…", text: $search, width: 150)
                    GhostButton(label: "New client", icon: "plus") { inModifica = nil; mostraForm = true }
                }
            } content: {
                if filtered.isEmpty {
                    NCEmpty(text: model.clients.isEmpty ? "No clients yet — add the first one." : "No match.")
                } else {
                    VStack(spacing: 5) {
                        NCHeaderRow(cols: [("Client", nil), ("Contact", 150), ("Services", 150),
                                           ("Retainer", 90), ("Since", 80), ("Status", 74)])
                        ForEach(filtered) { c in
                            NCRow(action: { inModifica = c; mostraForm = true }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(UI.ink).lineLimit(1)
                                    if let ig = ncClean(c.instagram) {
                                        Text(ig.hasPrefix("@") ? ig : "@\(ig)")
                                            .font(.system(size: 10)).foregroundStyle(UI.faint).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ncClean(c.contact_name) ?? "—")
                                        .font(.system(size: 11.5)).foregroundStyle(UI.text).lineLimit(1)
                                    if let m = ncClean(c.email) {
                                        Text(m).font(.system(size: 10)).foregroundStyle(UI.faint).lineLimit(1)
                                    }
                                }
                                .frame(width: 150, alignment: .leading)

                                Text(c.services.isEmpty ? "—" : c.services.joined(separator: " · "))
                                    .font(.system(size: 10.5)).foregroundStyle(UI.dim)
                                    .frame(width: 150, alignment: .leading).lineLimit(2)

                                Text(c.retainer_cents > 0 ? "\(ncEuro(c.retainer_cents))/mo" : "—")
                                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(c.retainer_cents > 0 ? UI.ink : UI.faint)
                                    .frame(width: 90, alignment: .leading)

                                Text(ncShortDate(c.start_date))
                                    .font(.system(size: 11)).foregroundStyle(UI.dim)
                                    .frame(width: 80, alignment: .leading)

                                let st = NCClientStatus.from(c.status)
                                StatusPill(label: st.label, tint: st.color)
                                    .frame(width: 74, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $mostraForm, onDismiss: { inModifica = nil }) {
            NCClientForm(existing: inModifica, model: model)
        }
    }
}

// ── Form cliente ─────────────────────────────────────────────────────────────

struct NCClientForm: View {
    let existing: NCClient?
    @ObservedObject var model: NCModel

    @State private var name = ""
    @State private var contact = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var instagram = ""
    @State private var website = ""
    @State private var status = NCClientStatus.lead.rawValue
    @State private var retainer = ""
    @State private var services: [String] = []
    @State private var source = ""
    @State private var notes = ""
    @State private var startDate = Date()
    @State private var hasStart = false

    /// Il tasto elimina compare solo in modifica.
    private var eliminazione: (() async -> Void)? {
        guard let c = existing else { return nil }
        return { await model.delete("nc_clients", id: c.id); await model.load() }
    }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New client" : "Edit client",
            canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
            onDelete: eliminazione,
            onSave: salva
        ) {
            HStack(spacing: 12) {
                NCField(label: "Client / brand", text: $name, hint: "e.g. Bloom Studio")
                NCField(label: "Contact person", text: $contact, hint: "Name")
            }
            HStack(spacing: 12) {
                NCField(label: "Email", text: $email, hint: "name@brand.com")
                NCField(label: "Phone", text: $phone, hint: "+34 …")
            }
            HStack(spacing: 12) {
                NCField(label: "Instagram", text: $instagram, hint: "@handle")
                NCField(label: "Website", text: $website, hint: "brand.com")
            }
            NCChips(label: "Status", options: NCClientStatus.allCases.map { ($0.rawValue, $0.label) },
                    selection: $status)
            NCMultiChips(label: "Services", options: NC_SERVICES, selection: $services)
            HStack(spacing: 12) {
                NCMoneyField(label: "Monthly retainer", text: $retainer)
                NCField(label: "Source", text: $source, hint: "referral, instagram…")
            }
            NCDateField(label: "Client since", date: $startDate, enabled: $hasStart)
            NCTextArea(label: "Notes", text: $notes)
        }
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let c = existing else { return }
        name = c.name; contact = c.contact_name ?? ""; email = c.email ?? ""
        phone = c.phone ?? ""; instagram = c.instagram ?? ""; website = c.website ?? ""
        status = c.status; services = c.services; source = c.source ?? ""; notes = c.notes ?? ""
        retainer = c.retainer_cents > 0 ? String(format: "%.2f", Double(c.retainer_cents) / 100) : ""
        if let d = ncParseDate(c.start_date) { startDate = d; hasStart = true }
    }

    private func salva() async throws {
        let fields: [String: Any?] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "contact_name": ncBlank(contact), "email": ncBlank(email), "phone": ncBlank(phone),
            "instagram": ncBlank(instagram), "website": ncBlank(website),
            "status": status, "retainer_cents": ncCents(retainer), "services": services,
            "start_date": hasStart ? ncDayString(startDate) : nil,
            "source": ncBlank(source), "notes": ncBlank(notes),
            "updated_at": isoNowString(),
        ]
        if let c = existing { try await HubAPI.ncUpdate("nc_clients", id: c.id, fields) }
        else { try await HubAPI.ncInsert("nc_clients", fields) }
        await model.load()
    }
}
