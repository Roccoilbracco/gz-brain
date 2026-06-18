import SwiftUI

private let SHORT_LABELS: [String: String] = [
    "da_contattare": "Da cont.", "call_fissata": "Call fis.", "call_effettuata": "Call eff.",
    "demo_fissata": "Demo fis.", "demo_effettuata": "Demo eff.", "proposta_inviata": "Proposta",
    "negoziazione": "Nego.", "chiuso_vinto": "Cliente",
]
private let HOT_STATUSES: Set<String> = ["demo_fissata", "demo_effettuata", "proposta_inviata", "negoziazione"]

private func stageHue(_ s: String) -> Double {
    if s == "chiuso_vinto" { return 152 }
    if HOT_STATUSES.contains(s) { return 25 }
    return 217
}

private func timelineKind(_ a: LeadActivity) -> (hue: Double, tag: String) {
    if a.event_type == "status_change" {
        let to = a.to_value ?? ""
        if to == "chiuso_vinto" { return (152, "Stato") }
        if to == "perso" { return (0, "Stato") }
        if HOT_STATUSES.contains(to) { return (25, "Stato") }
        return (217, "Stato")
    }
    if a.event_type.contains("note") { return (217, "Nota") }
    return (270, a.event_type.replacingOccurrences(of: "_", with: " "))
}

// ─── Pagina dettaglio lead (port di LeadPage.tsx) ───
struct LeadPageView: View {
    let slug: String
    let leadId: String

    @State private var lead: Lead?
    @State private var contacts: [LeadContact] = []
    @State private var notes: [LeadNote] = []
    @State private var activity: [LeadActivity] = []
    @State private var newNote = ""
    @State private var addingNote = false
    @State private var updatingStatus = false
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { AppState.shared.route = .progetto(slug: slug, tab: .dash) } label: {
                    Text("← Torna ai lead")
                        .font(.system(size: 11)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
                }
                .buttonStyle(.plain)

                if loading {
                    Text("Caricamento lead…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if let error {
                    GlassCard { Text("Errore: \(error)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if let lead {
                    headerCard(lead)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            anagraficaCard(lead)
                            contattiCard(lead)
                        }
                        VStack(spacing: 16) {
                            noteCard(lead)
                            timelineCard
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task(id: leadId) { await load() }
    }

    private func load() async {
        loading = true
        do {
            async let l = HubAPI.getLead(id: leadId)
            async let d = HubAPI.getLeadDetail(leadId: leadId)
            let (leadData, detail) = try await (l, d)
            guard let leadData else { error = "Lead non trovato"; loading = false; return }
            lead = leadData
            (contacts, notes, activity) = detail
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func changeStatus(_ newStatus: String) async {
        guard let l = lead, newStatus != l.status, !updatingStatus else { return }
        updatingStatus = true
        do {
            try await HubAPI.updateLeadStatus(l, to: newStatus)
            if let updated = try await HubAPI.getLead(id: l.id) { lead = updated }
            activity = try await HubAPI.getLeadDetail(leadId: l.id).activity
        } catch { self.error = error.localizedDescription }
        updatingStatus = false
    }

    private func addNote() async {
        guard let l = lead, !newNote.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        addingNote = true
        do {
            try await HubAPI.addLeadNote(l, body: newNote.trimmingCharacters(in: .whitespacesAndNewlines))
            newNote = ""
            let d = try await HubAPI.getLeadDetail(leadId: l.id)
            notes = d.notes
            activity = d.activity
        } catch { self.error = error.localizedDescription }
        addingNote = false
    }

    // ── Header card: titolo, badge, azioni, binario stadi ──
    private func headerCard(_ lead: Lead) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "building.2")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lead.ragione_sociale)
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Holo.titleText)
                        if let piva = lead.piva {
                            Text(piva).font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                        }
                        HStack(spacing: 6) {
                            LeadStatusBadgeView(status: lead.status)
                            if let c = lead.categoria { miniBadge(c) }
                            if let t = lead.tipo_servizio { miniBadge(t) }
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if let site = lead.siteURL {
                            actionButton("globe", "Sito") { openExternal(site) }
                        }
                        if let em = lead.emailAddr {
                            actionButton("envelope", "Email") { openExternal("mailto:\(em)") }
                        }
                        if let ph = lead.phoneNum {
                            actionButton("phone", "Chiama") { openExternal("tel:\(ph)") }
                        }
                    }
                }

                // Binario stadi: nodi cliccabili (niente select)
                HStack(spacing: 10) {
                    Text("STADIO").font(.system(size: 9, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(Holo.labelDim)
                    let track = LEAD_STATUSES.filter { $0 != "perso" }
                    let curIdx = track.firstIndex(of: lead.status) ?? -1
                    HStack(spacing: 0) {
                        ForEach(Array(track.enumerated()), id: \.element) { idx, s in
                            stageCell(s, idx: idx, curIdx: curIdx, count: track.count)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .opacity(updatingStatus ? 0.5 : 1)
                    .disabled(updatingStatus)
                    Button {
                        Task { await changeStatus("perso") }
                    } label: {
                        Text("Perso").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(lead.status == "perso" ? Color(hex: 0xffb3ad) : Holo.labelDim)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(
                                lead.status == "perso" ? Color(red: 1, green: 90/255, blue: 80/255).opacity(0.7)
                                : Color.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(updatingStatus)
                    if updatingStatus {
                        Text("Aggiornamento…").font(.system(size: 11)).foregroundStyle(Holo.labelDim)
                    }
                }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Tappa di pipeline connessa: binario riempito fino allo stadio attuale,
    /// tappa corrente col suo colore + alone, completate piene, future vuote.
    private func stageCell(_ s: String, idx: Int, curIdx: Int, count: Int) -> some View {
        let done = curIdx >= 0 && idx < curIdx
        let on = idx == curIdx
        let hue = stageHue(s)
        let track = Holo.hsl(217, 85, 60)
        let dim = Color.white.opacity(0.13)
        return Button { Task { await changeStatus(s) } } label: {
            VStack(spacing: 5) {
                ZStack {
                    // binario dietro: metà sinistra e destra, riempite se superate
                    HStack(spacing: 0) {
                        Rectangle().fill(curIdx >= idx ? track.opacity(0.85) : dim)
                            .frame(height: 2).opacity(idx == 0 ? 0 : 1)
                        Rectangle().fill(curIdx > idx ? track.opacity(0.85) : dim)
                            .frame(height: 2).opacity(idx == count - 1 ? 0 : 1)
                    }
                    Circle()
                        .fill(on ? Holo.hsl(hue, 90, 62)
                              : done ? track
                              : Color(red: 12/255, green: 19/255, blue: 40/255))
                        .frame(width: on ? 13 : 9, height: on ? 13 : 9)
                        .overlay(Circle().strokeBorder(
                            on ? Holo.hsl(hue, 90, 72) : (done ? .clear : dim), lineWidth: 1))
                        .shadow(color: on ? Holo.hsl(hue, 90, 60).opacity(0.9) : .clear, radius: 6)
                }
                .frame(height: 14)
                Text(SHORT_LABELS[s] ?? s)
                    .font(.system(size: 8.5, weight: on ? .heavy : .medium))
                    .foregroundStyle(on ? Holo.hsl(hue, 90, 76) : done ? Holo.text.opacity(0.7) : Holo.labelDim)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func miniBadge(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 8.5, weight: .heavy)).tracking(0.7)
            .foregroundStyle(Color(hex: 0xa8cdff))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color(red: 88/255, green: 166/255, blue: 1).opacity(0.5), lineWidth: 1))
    }

    private func actionButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.5)
            }
            .foregroundStyle(Color(hex: 0xcfe3ff))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().fill(Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
            .overlay(Capsule().strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // ── Anagrafica ──
    private func anagraficaCard(_ lead: Lead) -> some View {
        let validGruppo = lead.gruppo.map { $0.uppercased() != "NESSUNO" } ?? false
        let rows: [(String, String, String?)] = [
            lead.indirizzo.map { ("Indirizzo", $0, nil) },
            (lead.comune != nil || lead.provincia != nil)
                ? ("Comune", "\(lead.comune ?? "")\(lead.provincia.map { " (\($0))" } ?? "")", nil) : nil,
            lead.macroarea.map { ("Macroarea", $0, nil) },
            lead.natura_giuridica.map { ("Natura giuridica", $0, nil) },
            lead.id_arera.map { ("ID ARERA", $0, nil) },
            lead.settori.map { ("Settori", $0, nil) },
            validGruppo ? ("Gruppo", lead.gruppo!, nil) : nil,
            lead.commodity.map { ("Commodity", $0, nil) },
            lead.siteURL.map { ("Sito web", $0, $0) },
        ].compactMap { $0 }
        return sectionCard("Anagrafica") {
            if rows.isEmpty {
                Text("Nessun dato anagrafico disponibile")
                    .font(.system(size: 11)).foregroundStyle(Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.4))
            }
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.0).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Holo.labelDim)
                        .frame(width: 110, alignment: .leading)
                    if let href = row.2 {
                        Button { openExternal(href) } label: {
                            Text("\(row.1) ↗").font(.system(size: 11.5))
                                .foregroundStyle(Color(hex: 0x9ec9ff)).underline()
                                .lineLimit(1)
                        }.buttonStyle(.plain)
                    } else {
                        Text(row.1).font(.system(size: 11.5)).foregroundStyle(Holo.text)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
        }
    }

    // ── Contatti ──
    private func contattiCard(_ lead: Lead) -> some View {
        let infoRows: [(String, String)] = [
            lead.email.map { ("Email", $0) },
            lead.email_info.map { ("Email info", $0) },
            lead.email_commerciale.map { ("Email comm.", $0) },
            lead.telefono.map { ("Telefono", $0) },
            lead.telefoni.map { ("Telefoni", $0) },
            lead.whatsapp.map { ("WhatsApp", $0) },
        ].compactMap { $0 }
        return sectionCard("Contatti") {
            ForEach(infoRows, id: \.0) { row in
                HStack(spacing: 10) {
                    Text(row.0).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Holo.labelDim).frame(width: 110, alignment: .leading)
                    Text(row.1).font(.system(size: 11.5)).foregroundStyle(Holo.text)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
            if !contacts.isEmpty {
                Text("PERSONE").font(.system(size: 9, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.labelDim).padding(.top, 8)
                ForEach(contacts) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(c.full_name ?? "—").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Holo.titleText)
                            if c.is_legal_rep == true {
                                Text("RAPPR. LEGALE").font(.system(size: 7.5, weight: .heavy))
                                    .foregroundStyle(Color(hex: 0xffd9a0))
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .overlay(Capsule().strokeBorder(Color(red: 1, green: 180/255, blue: 60/255).opacity(0.6), lineWidth: 1))
                            }
                        }
                        if let role = c.role {
                            Text(role).font(.system(size: 10.5)).foregroundStyle(Holo.subDim)
                        }
                        if let li = c.linkedin_url {
                            Button { openExternal(li) } label: {
                                Text("LinkedIn ↗").font(.system(size: 10.5))
                                    .foregroundStyle(Color(hex: 0x9ec9ff)).underline()
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if infoRows.isEmpty && contacts.isEmpty {
                Text("Nessun contatto disponibile")
                    .font(.system(size: 11)).foregroundStyle(Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.4))
            }
        }
    }

    // ── Note ──
    private func noteCard(_ lead: Lead) -> some View {
        sectionCard("Note") {
            HStack(alignment: .bottom, spacing: 9) {
                TextEditor(text: $newNote)
                    .font(.system(size: 12.5))
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if newNote.isEmpty {
                            Text("Aggiungi nota…").font(.system(size: 12.5))
                                .foregroundStyle(Holo.labelDim).padding(11).allowsHitTesting(false)
                        }
                    }
                Button(addingNote ? "…" : "Aggiungi nota") { Task { await addNote() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(addingNote || newNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.bottom, 8)
            if notes.isEmpty {
                Text("Nessuna nota").font(.system(size: 11))
                    .foregroundStyle(Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.4))
            }
            ForEach(notes.reversed()) { n in
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.body).font(.system(size: 12)).foregroundStyle(Holo.text).lineSpacing(3)
                        .textSelection(.enabled)
                    Text(formatDateIT(n.created_at)).font(.system(size: 9.5))
                        .foregroundStyle(Holo.labelDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
                .padding(.vertical, 3)
            }
        }
    }

    // ── Timeline attività ──
    private var timelineCard: some View {
        sectionCard("Timeline attività") {
            if activity.isEmpty {
                Text("Nessuna attività registrata").font(.system(size: 11))
                    .foregroundStyle(Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.4))
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(activity.enumerated()), id: \.element.id) { i, a in
                    let k = timelineKind(a)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(Holo.hsl(k.hue, 90, 62))
                                .frame(width: i == 0 ? 10 : 7, height: i == 0 ? 10 : 7)
                                .shadow(color: Holo.hsl(k.hue, 90, 60).opacity(0.9), radius: i == 0 ? 5 : 3)
                            if i < activity.count - 1 {
                                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1.5)
                            }
                        }
                        .frame(width: 12)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(k.tag.uppercased())
                                    .font(.system(size: 8.5, weight: .heavy)).tracking(1)
                                    .foregroundStyle(Holo.hsl(k.hue, 90, 72))
                                Spacer()
                                Text(formatDateIT(a.created_at)).font(.system(size: 9.5))
                                    .foregroundStyle(Holo.labelDim)
                            }
                            if let from = a.from_value, let to = a.to_value {
                                HStack(spacing: 4) {
                                    Text(STATUS_LABELS[from] ?? from.replacingOccurrences(of: "_", with: " "))
                                        .font(.system(size: 11.5)).foregroundStyle(Holo.subDim)
                                    Text("→").foregroundStyle(Holo.labelDim)
                                    Text(STATUS_LABELS[to] ?? to.replacingOccurrences(of: "_", with: " "))
                                        .font(.system(size: 11.5, weight: .bold)).foregroundStyle(Holo.titleText)
                                }
                            }
                        }
                        .padding(.bottom, 14)
                    }
                }
            }
        }
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(217, 90, 70))
                    .padding(.bottom, 6)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        }
    }
}
