import SwiftUI

// ============================================================================
// Registro Proprietà (immobili) + storico operazioni.
// Una proprietà può essere venduta/affittata/traspasata più volte nel tempo:
// ogni operazione è una riga in proprieta_storico (timeline).
// ============================================================================

// ── Modelli ──────────────────────────────────────────────────────────────────
struct Proprieta: Decodable, Identifiable {
    let id: String
    var title: String
    var reference: String?
    var address: String?
    var zone: String?
    var city: String?
    var category: String?
    var property_type: String?
    var bedrooms: Int?
    var bathrooms: Int?
    var size_sqm: Int?
    var price: Int?
    var status: String
    var notes: String?
    let created_at: String?
    var proprieta_storico: [ProprietaStorico]?
}

struct ProprietaStorico: Decodable, Identifiable {
    let id: String
    var event_type: String?
    var event_date: String?
    var price: Int?
    var counterparty: String?
    var agent: String?
    var notes: String?
    let created_at: String?
}

enum PropertyStatus: String, CaseIterable, Identifiable {
    case disponibile, riservata, venduta, affittata, ritirata
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var hue: Double {
        switch self {
        case .disponibile: return 150
        case .riservata: return 45
        case .venduta: return 210
        case .affittata: return 190
        case .ritirata: return 5
        }
    }
    static func from(_ s: String?) -> PropertyStatus { PropertyStatus(rawValue: s ?? "") ?? .disponibile }
}

enum StoricoEvent: String, CaseIterable, Identifiable {
    case acquisizione, vendita, affitto, traspaso, variazione_prezzo, ritiro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .variazione_prezzo: return "Variazione prezzo"
        default: return rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .acquisizione: return "plus.circle.fill"
        case .vendita: return "eurosign.circle.fill"
        case .affitto: return "key.fill"
        case .traspaso: return "arrow.left.arrow.right.circle.fill"
        case .variazione_prezzo: return "tag.fill"
        case .ritiro: return "xmark.circle.fill"
        }
    }
    var hue: Double {
        switch self {
        case .acquisizione: return 190
        case .vendita: return 210
        case .affitto: return 150
        case .traspaso: return 280
        case .variazione_prezzo: return 45
        case .ritiro: return 5
        }
    }
    static func from(_ s: String?) -> StoricoEvent { StoricoEvent(rawValue: s ?? "") ?? .vendita }
}

// data ISO "yyyy-MM-dd" → "dd MMM yyyy"
private let ymdIn: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "it_IT"); return f }()
private let ymdOut: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd MMM yyyy"; f.locale = Locale(identifier: "it_IT"); return f }()
func prettyDate(_ s: String?) -> String {
    guard let s, let d = ymdIn.date(from: String(s.prefix(10))) else { return s ?? "—" }
    return ymdOut.string(from: d)
}

// ── API ──────────────────────────────────────────────────────────────────────
extension HubAPI {
    static func listProprieta() async throws -> [Proprieta] {
        try await sb.fetch("proprieta?select=*,proprieta_storico(id)&order=created_at.desc&limit=2000")
    }
    static func getProprieta(id: String) async throws -> Proprieta? {
        let rows: [Proprieta] = try await sb.fetch("proprieta?select=*,proprieta_storico(*)&id=eq.\(id)")
        return rows.first
    }
    @discardableResult
    static func createProprieta(_ fields: [String: Any?]) async throws -> Proprieta {
        try await sb.insertReturning("proprieta", body: fields)
    }
    static func updateProprieta(id: String, fields: [String: Any?]) async throws {
        var body = fields; body["updated_at"] = isoNowString()
        try await sb.mutate("proprieta?id=eq.\(id)", method: "PATCH", body: body)
    }
    static func deleteProprieta(id: String) async throws {
        try await sb.mutate("proprieta?id=eq.\(id)", method: "DELETE")
    }
    static func addStorico(_ fields: [String: Any?]) async throws {
        try await sb.mutate("proprieta_storico", method: "POST", body: fields)
    }
    static func deleteStorico(id: String) async throws {
        try await sb.mutate("proprieta_storico?id=eq.\(id)", method: "DELETE")
    }
}

// ── Lista proprietà (griglia card) ───────────────────────────────────────────
struct ProprietaView: View {
    @State private var items: [Proprieta] = []
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var search = ""
    @State private var showAdd = false

    private var filtered: [Proprieta] {
        items.filter { p in
            search.isEmpty || [p.title, p.reference, p.zone, p.city, p.address]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("PROPRIETÀ").font(.system(size: 19, weight: .heavy)).tracking(5)
                        .foregroundStyle(Holo.titleText)
                        .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                    Spacer()
                    HoloSearchField(placeholder: "Cerca immobile…", text: $search)
                    MenuPillButton(label: "Aggiungi proprietà", icon: "plus") { showAdd = true }
                }

                if let errorMsg {
                    GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.top, 8)
                } else if filtered.isEmpty {
                    EmptyStateCard(icon: "house", text: search.isEmpty
                        ? "Nessuna proprietà.\nAggiungine una con “+ Aggiungi proprietà”."
                        : "Nessuna proprietà trovata.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { p in PropertyCard(p: p) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 54, leading: 30, bottom: 34, trailing: 30))
        }
        .task { await load() }
        .sheet(isPresented: $showAdd) { ProprietaFormView(existing: nil) { await load() } }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { items = try await HubAPI.listProprieta() }
        catch let e { errorMsg = e.localizedDescription }
    }
}

private struct PropertyCard: View {
    let p: Proprieta
    @State private var hover = false
    private var st: PropertyStatus { .from(p.status) }
    private var storicoCount: Int { p.proprieta_storico?.count ?? 0 }

    var body: some View {
        Button { AppState.shared.route = .proprieta(id: p.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Holo.titleText).lineLimit(1)
                        if let r = p.reference, !r.isEmpty {
                            Text("Rif. \(r)").font(.system(size: 10)).foregroundStyle(Csb.tagFg)
                        }
                    }
                    Spacer(minLength: 4)
                    statusBadge
                }
                if let loc = [p.zone, p.city].compactMap({ $0 }).first {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.circle.fill").font(.system(size: 10)).foregroundStyle(Csb.secFg)
                        Text([p.zone, p.city].compactMap { $0 }.joined(separator: ", ")).font(.system(size: 11))
                            .foregroundStyle(Holo.subDim).lineLimit(1)
                    }
                }
                Text([p.category?.capitalized, p.property_type,
                      p.size_sqm.map { "\($0) m²" }, p.bedrooms.map { "\($0) cam" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
                HStack {
                    if let pr = p.price { Text(LeadFmt.euro(pr)).font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Holo.hsl(150, 70, 68)) }
                    Spacer()
                    if storicoCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 9))
                            Text("\(storicoCount)").font(.system(size: 10, weight: .bold))
                        }.foregroundStyle(Csb.avatar)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13).fill(hover ? Color.white.opacity(0.05) : Color(hex: 0x121a2c).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(st.hue == 0 ? Color.white.opacity(0.08) : Holo.hsl(st.hue, 60, 55).opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var statusBadge: some View {
        Text(st.label.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
            .foregroundStyle(Holo.hsl(st.hue, 85, 75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Holo.hsl(st.hue, 80, 60).opacity(0.5), lineWidth: 1))
    }
}

// ── Scheda proprietà: info + timeline storico ────────────────────────────────
struct ProprietaDetailView: View {
    let proprietaId: String
    @State private var p: Proprieta?
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var showEdit = false
    @State private var showAddEvent = false
    @State private var confirmDelete = false

    private var st: PropertyStatus { .from(p?.status) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { AppState.shared.clientiTab = .proprieta; AppState.shared.route = .clienti } label: {
                    Text("← PROPRIETÀ").font(.system(size: 11)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
                }.buttonStyle(.plain)

                if let errorMsg {
                    GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if let p {
                    anagrafica(p)
                    storicoSection(p)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task(id: proprietaId) { await load() }
        .sheet(isPresented: $showEdit) {
            if let p { ProprietaFormView(existing: p) { await load() } }
        }
        .sheet(isPresented: $showAddEvent) {
            StoricoFormView(proprietaId: proprietaId) { await load() }
        }
    }

    private func anagrafica(_ p: Proprieta) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "house.fill").font(.system(size: 20)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(
                        colors: [Holo.hsl(st.hue, 55, 42), Holo.hsl(st.hue, 60, 28)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Holo.hsl(st.hue, 60, 55).opacity(0.45), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(.system(size: 18, weight: .heavy)).foregroundStyle(Holo.titleText).lineLimit(1)
                    if let r = p.reference, !r.isEmpty {
                        Text("Rif. \(r)").font(.system(size: 11, weight: .medium)).foregroundStyle(Csb.tagFg)
                    }
                }
                Spacer(minLength: 12)
                StatusChip(text: st.label, hue: st.hue)
                Menu {
                    Button { showEdit = true } label: { Label("Modifica", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Csb.itemFg)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabsBg))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            divider
            defRow("INDIRIZZO", [p.address, p.zone, p.city].compactMap { $0 }.joined(separator: ", ").ifEmpty("—"))
            divider
            defRow("TIPOLOGIA", [p.category?.capitalized, p.property_type].compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
            divider
            defRow("DETTAGLI", [p.size_sqm.map { "\($0) m²" }, p.bedrooms.map { "\($0) camere" }, p.bathrooms.map { "\($0) bagni" }]
                .compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
            divider
            defRow("PREZZO ATTUALE", p.price.map { LeadFmt.euro($0) } ?? "—")
            if let n = p.notes, !n.isEmpty { divider; defRow("NOTE", n) }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Csb.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Csb.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .confirmationDialog("Eliminare la proprietà e tutto il suo storico?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { delete() }
            Button("Annulla", role: .cancel) {}
        }
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    private func defRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2)
                .foregroundStyle(Csb.secFg).frame(width: 130, alignment: .leading).padding(.top, 1)
            Text(value).font(.system(size: 13)).foregroundStyle(Holo.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18))
    }

    // timeline storico
    private func storicoSection(_ p: Proprieta) -> some View {
        let eventi = (p.proprieta_storico ?? []).sorted {
            ($0.event_date ?? "") > ($1.event_date ?? "")
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("STORICO OPERAZIONI").font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(210, 60, 66))
                Spacer()
                MenuPillButton(label: "Aggiungi evento", icon: "plus") { showAddEvent = true }
            }
            if eventi.isEmpty {
                EmptyStateCard(icon: "clock.arrow.circlepath",
                    text: "Nessuna operazione registrata.\nAggiungi acquisizione, vendita, affitto o traspaso.")
            } else {
                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(eventi.enumerated()), id: \.element.id) { i, ev in
                            storicoRow(ev, last: i == eventi.count - 1)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func storicoRow(_ ev: ProprietaStorico, last: Bool) -> some View {
        let e = StoricoEvent.from(ev.event_type)
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: e.icon).font(.system(size: 14)).foregroundStyle(Holo.hsl(e.hue, 85, 68))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Holo.hsl(e.hue, 70, 45).opacity(0.18)))
                if !last { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(e.label).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Holo.hsl(e.hue, 80, 74))
                    Text(prettyDate(ev.event_date)).font(.system(size: 10.5)).foregroundStyle(Csb.secFg)
                    Spacer()
                    if let pr = ev.price { Text(LeadFmt.euro(pr)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Holo.text) }
                }
                if ev.counterparty != nil || ev.agent != nil {
                    Text([ev.counterparty, ev.agent.map { "Agente: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Holo.subDim)
                }
                if let n = ev.notes, !n.isEmpty {
                    Text(n).font(.system(size: 11)).foregroundStyle(Holo.labelDim).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, last ? 0 : 14)
            Button { Task { try? await HubAPI.deleteStorico(id: ev.id); await load() } } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Holo.labelDim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { p = try await HubAPI.getProprieta(id: proprietaId) }
        catch let e { errorMsg = e.localizedDescription }
    }
    private func delete() {
        Task {
            do { try await HubAPI.deleteProprieta(id: proprietaId)
                await MainActor.run { AppState.shared.clientiTab = .proprieta; AppState.shared.route = .clienti }
            } catch let e { await MainActor.run { errorMsg = "Eliminazione fallita: \(e.localizedDescription)" } }
        }
    }
}

private extension String { func ifEmpty(_ f: String) -> String { isEmpty ? f : self } }

// ── Form proprietà (nuova / modifica) ────────────────────────────────────────
struct ProprietaFormView: View {
    let existing: Proprieta?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""; @State private var reference = ""
    @State private var address = ""; @State private var zone = ""; @State private var city = ""
    @State private var category = ""; @State private var propertyType = ""
    @State private var bedrooms = ""; @State private var bathrooms = ""; @State private var sqm = ""
    @State private var price = ""; @State private var status = PropertyStatus.disponibile
    @State private var notes = ""; @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "NUOVA PROPRIETÀ" : "MODIFICA PROPRIETÀ")
                    .font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HoloField(label: "Titolo *", text: $title, placeholder: "Es. Villa vista mare Es Cubells")
                HoloField(label: "Riferimento", text: $reference, placeholder: "Es. GZ-0012")
                HoloField(label: "Indirizzo", text: $address, placeholder: "Es. Carrer de …")
                HStack(spacing: 12) { HoloField(label: "Zona", text: $zone); HoloField(label: "Città", text: $city) }
                HStack(spacing: 12) {
                    holoPicker("Categoria", [("", "—")] + LeadCategory.allCases.map { ($0.rawValue, $0.label) }, category) { category = $0 }
                    holoPicker("Tipo immobile", [("", "—")] + propertyTypes.map { ($0, $0) }, propertyType) { propertyType = $0 }
                }
                HStack(spacing: 12) {
                    HoloField(label: "Camere", text: $bedrooms, placeholder: "3")
                    HoloField(label: "Bagni", text: $bathrooms, placeholder: "2")
                    HoloField(label: "Superficie m²", text: $sqm, placeholder: "180")
                }
                HStack(spacing: 12) {
                    HoloField(label: "Prezzo €", text: $price, placeholder: "1200000")
                    holoPicker("Stato", PropertyStatus.allCases.map { ($0.rawValue, $0.label) }, status.rawValue) { status = .from($0) }
                }
                HoloField(label: "Note", text: $notes)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : "Salva proprietà").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain)
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 720)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard let e = existing else { return }
        title = e.title; reference = e.reference ?? ""; address = e.address ?? ""
        zone = e.zone ?? ""; city = e.city ?? ""; category = e.category ?? ""; propertyType = e.property_type ?? ""
        bedrooms = e.bedrooms.map(String.init) ?? ""; bathrooms = e.bathrooms.map(String.init) ?? ""
        sqm = e.size_sqm.map(String.init) ?? ""; price = e.price.map(String.init) ?? ""
        status = .from(e.status); notes = e.notes ?? ""
    }
    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let body: [String: Any?] = [
            "title": title.trimmingCharacters(in: .whitespaces), "reference": s(reference),
            "address": s(address), "zone": s(zone), "city": s(city),
            "category": s(category), "property_type": s(propertyType),
            "bedrooms": Int(bedrooms), "bathrooms": Int(bathrooms), "size_sqm": Int(sqm),
            "price": Int(price), "status": status.rawValue, "notes": s(notes),
        ]
        do {
            if let e = existing { try await HubAPI.updateProprieta(id: e.id, fields: body) }
            else { try await HubAPI.createProprieta(body) }
            await onSaved(); dismiss()
        } catch { saving = false }
    }
}

// ── Form evento storico ───────────────────────────────────────────────────────
struct StoricoFormView: View {
    let proprietaId: String
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var event = StoricoEvent.vendita
    @State private var date = Date()
    @State private var price = ""; @State private var counterparty = ""; @State private var agent = ""; @State private var notes = ""
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("NUOVO EVENTO").font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HStack(spacing: 12) {
                    holoPicker("Tipo operazione", StoricoEvent.allCases.map { ($0.rawValue, $0.label) }, event.rawValue) { event = .from($0) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DATA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact).colorScheme(.dark)
                    }.frame(width: 150)
                }
                HoloField(label: "Prezzo €", text: $price, placeholder: "Es. 1350000")
                HStack(spacing: 12) {
                    HoloField(label: "Controparte", text: $counterparty, placeholder: "Acquirente / inquilino")
                    HoloField(label: "Agente", text: $agent, placeholder: "Giorgio")
                }
                HoloField(label: "Note", text: $notes)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : "Salva evento").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain).disabled(saving)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 470)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let body: [String: Any?] = [
            "proprieta_id": proprietaId, "event_type": event.rawValue, "event_date": f.string(from: date),
            "price": Int(price), "counterparty": s(counterparty), "agent": s(agent), "notes": s(notes),
        ]
        do { try await HubAPI.addStorico(body); await onSaved(); dismiss() }
        catch { saving = false }
    }
}

// picker in stile HoloField (menu a tendina scuro)
private func holoPicker(_ label: String, _ opts: [(String, String)], _ sel: String, _ set: @escaping (String) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
        Menu {
            ForEach(opts, id: \.0) { o in Button(o.1) { set(o.0) } }
        } label: {
            HStack {
                Text(opts.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 13)).foregroundStyle(Color(hex: 0xe8f2ff))
                Spacer(); Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Holo.labelDim)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }
    .frame(maxWidth: .infinity)
}
