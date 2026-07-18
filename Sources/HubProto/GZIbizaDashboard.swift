import SwiftUI

@MainActor
final class GZIbizaModel: ObservableObject {
    @Published var leads: [RELead] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true
        do { leads = try await HubAPI.listReLeads(); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Mutazione ottimistica + PATCH: la card si sposta subito sotto il dito.
    /// Se lo stadio non cambia (drop nella stessa colonna) non tocchiamo il DB.
    func setStage(_ id: String, _ stage: LeadStage) async {
        guard let i = leads.firstIndex(where: { $0.id == id }), leads[i].stage != stage.rawValue else { return }
        leads[i].stage = stage.rawValue
        try? await HubAPI.setReLeadStage(id: id, stage: stage.rawValue)
    }

    func setNotes(_ id: String, _ notes: String) async {
        let v = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = leads.firstIndex(where: { $0.id == id }) { leads[i].notes = v.isEmpty ? nil : v }
        try? await HubAPI.updateReLead(id: id, fields: ["notes": v.isEmpty ? nil : v])
    }

    func remove(_ id: String) async {
        leads.removeAll { $0.id == id }
        try? await HubAPI.deleteReLead(id: id)
    }
}

// ─── Dash GZ Ibiza: pipeline lead + conversazioni WhatsApp ───────────────────
struct GZIbizaDashboard: View {
    @StateObject private var model = GZIbizaModel()
    @State private var search = ""
    @State private var fonte: LeadSource?
    @State private var mostraAgente = false
    @State private var selected: RELead?

    private var filtered: [RELead] {
        model.leads.filter { l in
            let okFonte = fonte == nil || l.source == fonte!.rawValue
            guard okFonte else { return false }
            guard !search.isEmpty else { return true }
            return [l.name, l.email ?? "", l.phone ?? "", l.zone ?? "", l.notes ?? "", l.request_message ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private func inStage(_ s: LeadStage) -> [RELead] { filtered.filter { $0.stage == s.rawValue } }
    private func count(_ s: LeadStage) -> Int { model.leads.filter { $0.stage == s.rawValue }.count }
    private var inLavorazione: Int {
        model.leads.filter { let s = LeadStage.from($0.stage); return s != .nuovo && !s.isClosed }.count
    }
    private var daWhatsApp: Int { model.leads.filter { $0.source == LeadSource.whatsapp.rawValue }.count }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 16) {
                header
                statRow
                filtri

                if model.loading {
                    HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 40)
                } else if let e = model.error {
                    GlassCard { Text("Errore: \(e)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else {
                    board
                }

                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 4)

                WhatsAppSection(slug: "gz-ibiza")
            }
            .blur(radius: selected != nil ? 2 : 0)
            .disabled(selected != nil)

            if let sel = selected {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                GZLeadDrawerView(
                    lead: sel,
                    onStage: { s in
                        Task { await model.setStage(sel.id, s) }
                        if var l = selected { l.stage = s.rawValue; selected = l }
                    },
                    onNotes: { txt in
                        Task { await model.setNotes(sel.id, txt) }
                        if var l = selected { l.notes = txt; selected = l }
                    },
                    onDelete: {
                        Task { await model.remove(sel.id) }
                        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
                    },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 430)
                .transition(.move(edge: .trailing))
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $mostraAgente) {
            AgenteSheet(slug: "gz-ibiza") { mostraAgente = false }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GZ IBIZA")
                    .font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                Text("Pipeline lead e conversazioni WhatsApp")
                    .font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
            Spacer()
            AgenteButton { mostraAgente = true }
            Button { Task { await model.load() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Holo.labelDim).padding(8)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }.buttonStyle(.plain)
        }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            statCard("NUOVI", count(.nuovo), hue: 220, glow: count(.nuovo) > 0)
            statCard("IN LAVORAZIONE", inLavorazione, hue: 190, glow: false)
            statCard("DA WHATSAPP", daWhatsApp, hue: 140, glow: false)
            statCard("VINTI", count(.vinto), hue: 145, glow: false)
            statCard("TOTALI", model.leads.count, hue: 270, glow: false)
        }
    }

    private func statCard(_ label: String, _ n: Int, hue: Double, glow: Bool) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(n)").font(.system(size: 26, weight: .black))
                    .foregroundStyle(Holo.hsl(hue, 90, 70))
                    .shadow(color: glow ? Holo.hsl(hue, 90, 60).opacity(0.7) : .clear, radius: 8)
                Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.labelDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 15, bottom: 11, trailing: 15))
        }
    }

    private var filtri: some View {
        HStack(spacing: 8) {
            chipFonte(nil, "Tutte")
            ForEach(LeadSource.allCases) { s in chipFonte(s, s.label) }
            Spacer()
            HoloSearchField(placeholder: "Cerca lead…", text: $search, width: 170)
        }
    }

    private func chipFonte(_ s: LeadSource?, _ label: String) -> some View {
        let on = fonte == s
        return Button { fonte = on ? nil : s } label: {
            HStack(spacing: 4) {
                if let s { Image(systemName: s.icon).font(.system(size: 9)) }
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(on ? Color(hex: 0x0b1020) : (s?.color ?? Holo.subDim))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? (s?.color ?? Holo.hsl(210, 80, 65)) : Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder((s?.color ?? Holo.subDim).opacity(on ? 0 : 0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(LeadStage.allCases) { stage in
                    GZStageColumn(
                        stage: stage,
                        items: inStage(stage),
                        onDrop: { id in Task { await model.setStage(id, stage) } },
                        onSelect: { l in withAnimation(.easeInOut(duration: 0.2)) { selected = l } })
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// ─── Colonna pipeline ────────────────────────────────────────────────────────
private struct GZStageColumn: View {
    let stage: LeadStage
    let items: [RELead]
    let onDrop: (String) -> Void
    let onSelect: (RELead) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(stage.color).frame(width: 8, height: 8)
                    .shadow(color: stage.color.opacity(0.8), radius: 4)
                Text(stage.label.uppercased()).font(.system(size: 10.5, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(Holo.text)
                Text("\(items.count)").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Csb.secFg)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(items) { l in
                        GZLeadCard(lead: l)
                            .onTapGesture { onSelect(l) }
                            .draggable(l.id)
                    }
                    if items.isEmpty {
                        Text("—").font(.system(size: 12)).foregroundStyle(Csb.secFg.opacity(0.5))
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                }
                .padding(2)
            }
        }
        .frame(width: 250)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 13)
            .fill(targeted ? stage.color.opacity(0.10) : Color.white.opacity(0.022)))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .strokeBorder(targeted ? stage.color.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }; onDrop(id); return true
        } isTargeted: { targeted = $0 }
    }
}

// ─── Card lead, con badge fonte ──────────────────────────────────────────────
private struct GZLeadCard: View {
    let lead: RELead
    @State private var hover = false

    var body: some View {
        let src = LeadSource.from(lead.source)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(lead.name.isEmpty ? "—" : lead.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Holo.titleText).lineLimit(1)
                Spacer(minLength: 4)
                // Badge fonte: sito, WhatsApp, chiamata…
                HStack(spacing: 3) {
                    Image(systemName: src.icon).font(.system(size: 8))
                    Text(src.label).font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(src.color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(src.color.opacity(0.14)))
            }

            // Contatti: servono a colpo d'occhio per richiamare senza aprire il lead
            if let mail = clean(lead.email) {
                Text(mail).font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
                    .lineLimit(1).truncationMode(.middle)   // il dominio resta leggibile
            }
            if let tel = clean(lead.phone) {
                Text(tel).font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
            }

            if let z = clean(lead.zone) {
                Label(z, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 10)).foregroundStyle(Holo.subDim).lineLimit(1)
            }
            if let b = LeadFmt.budget(lead.budget_min, lead.budget_max) {
                Text(b).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Holo.hsl(150, 70, 65))
            }
            // Il messaggio dal form, o in mancanza le note interne
            if let msg = clean(lead.request_message) ?? clean(lead.notes) {
                Text(msg).font(.system(size: 10.5)).lineSpacing(2)
                    .foregroundStyle(Holo.text.opacity(0.8)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(fmtLeadDate(lead.created_at)).font(.system(size: 9))
                    .foregroundStyle(Holo.labelDim.opacity(0.8))
                Spacer()
                if clean(lead.notes) != nil {
                    Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(Holo.hsl(45, 70, 62))
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(hover ? Color.white.opacity(0.07) : Color(hex: 0x121a2c).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
    }

    private func clean(_ v: String?) -> String? {
        guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

// ─── Drawer laterale: dettaglio lead + note (gemello di quello Wallis) ───────
private struct GZLeadDrawerView: View {
    let lead: RELead
    let onStage: (LeadStage) -> Void
    let onNotes: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var note: String = ""
    @State private var savedFlash = false
    private var stage: LeadStage { .from(lead.stage) }
    private var src: LeadSource { .from(lead.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lead.name.isEmpty ? "—" : lead.name)
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(Holo.titleText)
                    HStack(spacing: 6) {
                        Text(stage.label.uppercased())
                            .font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
                            .foregroundStyle(stage.color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(stage.color.opacity(0.16)))
                            .overlay(Capsule().strokeBorder(stage.color.opacity(0.5), lineWidth: 1))
                        // fonte: da dove è arrivato il lead (sito, WhatsApp, …)
                        HStack(spacing: 3) {
                            Image(systemName: src.icon).font(.system(size: 8))
                            Text(src.label).font(.system(size: 9, weight: .heavy))
                        }
                        .foregroundStyle(src.color)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(src.color.opacity(0.14)))
                    }
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
                    section("PIPELINE") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(LeadStage.allCases) { s in
                                let on = s == stage
                                Button { onStage(s) } label: {
                                    Text(s.label).font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(on ? Color(hex: 0x0b1220) : s.color)
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? s.color : s.color.opacity(0.12)))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(s.color.opacity(on ? 0 : 0.35), lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    section("CONTATTI") {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow("envelope.fill", clean(lead.email) ?? "—")
                            infoRow("phone.fill", clean(lead.phone) ?? "—")
                            infoRow("calendar", fmtLeadDate(lead.created_at))
                        }
                    }
                    // Ricerca immobile: compilata dall'agente WhatsApp, vuota per i lead dal sito
                    if let d = dettagli {
                        section("RICERCA") {
                            VStack(alignment: .leading, spacing: 8) { ForEach(d, id: \.1) { infoRow($0.0, $0.1) } }
                        }
                    }
                    if let msg = clean(lead.request_message) {
                        section("RICHIESTA") {
                            Text(msg).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(Holo.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section("NOTE") {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                                if note.isEmpty {
                                    Text("Aggiungi una nota…").font(.system(size: 12)).foregroundStyle(Csb.secFg)
                                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 0)).allowsHitTesting(false)
                                }
                                TextEditor(text: $note)
                                    .font(.system(size: 12.5)).foregroundStyle(Holo.text)
                                    .scrollContentBackground(.hidden).background(Color.clear)
                                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                                    .frame(minHeight: 110)
                            }
                            HStack {
                                if savedFlash {
                                    Label("Salvato", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Holo.hsl(145, 70, 62))
                                }
                                Spacer()
                                Button {
                                    onNotes(note)
                                    savedFlash = true
                                    Task { try? await Task.sleep(nanoseconds: 1_600_000_000); savedFlash = false }
                                } label: {
                                    Text("Salva nota").font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Color(hex: 0x0b1220))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(Capsule().fill(Holo.hsl(210, 85, 66)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }

            HStack(spacing: 10) {
                if let tel = clean(lead.phone), let url = waURL(tel) {
                    Link(destination: url) {
                        Label("WhatsApp", systemImage: "message.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Holo.titleText).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                if let mail = clean(lead.email), let url = URL(string: "mailto:\(mail)") {
                    Link(destination: url) {
                        Label("Rispondi", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Holo.titleText).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
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
        .onAppear { note = lead.notes ?? "" }
    }

    /// Righe della sezione RICERCA, solo quelle valorizzate; nil se non c'è nulla da mostrare.
    private var dettagli: [(String, String)]? {
        var r: [(String, String)] = []
        if let v = clean(lead.interest) { r.append(("tag.fill", v.capitalized)) }
        if let v = clean(lead.property_type) { r.append(("house.fill", v.capitalized)) }
        if let v = clean(lead.zone) { r.append(("mappin.and.ellipse", v)) }
        if let v = LeadFmt.budget(lead.budget_min, lead.budget_max) { r.append(("eurosign.circle.fill", v)) }
        if let b = lead.bedrooms { r.append(("bed.double.fill", "\(b) camere")) }
        return r.isEmpty ? nil : r
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Holo.hsl(210, 60, 66))
            content()
        }
    }
    private func infoRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Csb.secFg).frame(width: 16)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Holo.text).textSelection(.enabled)
        }
    }
    private func clean(_ v: String?) -> String? {
        guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    /// wa.me vuole il numero senza + né separatori
    private func waURL(_ tel: String) -> URL? {
        let n = tel.filter(\.isNumber)
        return n.isEmpty ? nil : URL(string: "https://wa.me/\(n)")
    }
}

// ─── Data ISO → "18 lug · 20:48" ─────────────────────────────────────────────
private func fmtLeadDate(_ s: String?) -> String {
    guard let s else { return "—" }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) ?? iso2.date(from: s) {
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM · HH:mm"
        return f.string(from: d)
    }
    return String(s.prefix(16)).replacingOccurrences(of: "T", with: " ")
}

// ─── Bottone "Agente", accanto al refresh nelle dash ─────────────────────────
struct AgenteButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                Text("Agente").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(hover ? Color(hex: 0x0b1020) : Holo.hsl(140, 70, 65))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(hover ? Holo.hsl(140, 70, 62) : Holo.hsl(140, 70, 50).opacity(0.16)))
            .overlay(Capsule().strokeBorder(Holo.hsl(140, 70, 60).opacity(hover ? 0 : 0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Impostazioni dell'agente WhatsApp")
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
    }
}
