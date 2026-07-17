import SwiftUI

// ============================================================================
// CRM immobiliare — sezione Leads
// Pipeline kanban delle richieste che arrivano da Sito/Social/Chiamate/
// WhatsApp/Email/Idealista, con stati di avanzamento e drawer di dettaglio.
// ============================================================================

// ── Modello ─────────────────────────────────────────────────────────────────
struct RELead: Identifiable, Decodable, Equatable {
    let id: String
    var name: String
    var phone: String?
    var email: String?
    var source: String
    var stage: String
    var interest: String?
    var property_type: String?
    var zone: String?
    var budget_min: Int?
    var budget_max: Int?
    var bedrooms: Int?
    var notes: String?
    var assigned_to: String?
    var idealista_ref: String?
    var last_contact_at: String?
    var created_at: String?
}

// ── Fonti richiesta ──────────────────────────────────────────────────────────
enum LeadSource: String, CaseIterable, Identifiable {
    case sito, social, chiamata, whatsapp, email, idealista
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sito: return "Sito"
        case .social: return "Social"
        case .chiamata: return "Chiamata"
        case .whatsapp: return "WhatsApp"
        case .email: return "Email"
        case .idealista: return "Idealista"
        }
    }
    var icon: String {
        switch self {
        case .sito: return "globe"
        case .social: return "bubble.left.and.bubble.right.fill"
        case .chiamata: return "phone.fill"
        case .whatsapp: return "message.fill"
        case .email: return "envelope.fill"
        case .idealista: return "house.fill"
        }
    }
    var hue: Double {
        switch self {
        case .sito: return 210
        case .social: return 320
        case .chiamata: return 150
        case .whatsapp: return 140
        case .email: return 30
        case .idealista: return 175
        }
    }
    var color: Color { Holo.hsl(hue, 78, 62) }
    static func from(_ raw: String?) -> LeadSource { LeadSource(rawValue: raw ?? "") ?? .sito }
}

// ── Stati pipeline ───────────────────────────────────────────────────────────
enum LeadStage: String, CaseIterable, Identifiable {
    case nuovo, contattato, qualificato, visita, proposta, trattativa, vinto, perso
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nuovo: return "Nuovo"
        case .contattato: return "Contattato"
        case .qualificato: return "Qualificato"
        case .visita: return "Visita"
        case .proposta: return "Proposta"
        case .trattativa: return "Trattativa"
        case .vinto: return "Chiuso vinto"
        case .perso: return "Chiuso perso"
        }
    }
    var hue: Double {
        switch self {
        case .nuovo: return 220
        case .contattato: return 205
        case .qualificato: return 190
        case .visita: return 45
        case .proposta: return 165
        case .trattativa: return 270
        case .vinto: return 145
        case .perso: return 5
        }
    }
    var color: Color { Holo.hsl(hue, 80, 62) }
    var isClosed: Bool { self == .vinto || self == .perso }
    static func from(_ raw: String?) -> LeadStage { LeadStage(rawValue: raw ?? "") ?? .nuovo }
}

enum LeadInterest: String, CaseIterable, Identifiable {
    case acquisto, affitto, vendita
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

let propertyTypes = ["Appartamento", "Villa", "Attico", "Casale", "Terreno", "Commerciale"]

// ── API ──────────────────────────────────────────────────────────────────────
extension HubAPI {
    static func listReLeads() async throws -> [RELead] {
        try await sb.fetch("re_leads?select=*&order=created_at.desc&limit=2000")
    }
    @discardableResult
    static func createReLead(_ fields: [String: Any?]) async throws -> RELead {
        try await sb.insertReturning("re_leads", body: fields)
    }
    static func updateReLead(id: String, fields: [String: Any?]) async throws {
        var body = fields; body["updated_at"] = isoNowString()
        try await sb.mutate("re_leads?id=eq.\(id)", method: "PATCH", body: body)
    }
    static func setReLeadStage(id: String, stage: String) async throws {
        try await sb.mutate("re_leads?id=eq.\(id)", method: "PATCH",
                            body: ["stage": stage, "last_contact_at": isoNowString(), "updated_at": isoNowString()])
    }
    static func deleteReLead(id: String) async throws {
        try await sb.mutate("re_leads?id=eq.\(id)", method: "DELETE")
    }
}

// ── Formattazione budget ─────────────────────────────────────────────────────
enum LeadFmt {
    static let grouped: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.maximumFractionDigits = 0; return f
    }()
    static func euro(_ n: Int) -> String { "€" + (grouped.string(from: NSNumber(value: n)) ?? "\(n)") }
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "€%.1fM", Double(n)/1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if n >= 1_000 { return "€\(n/1000)k" }
        return euro(n)
    }
    static func budget(_ lo: Int?, _ hi: Int?) -> String? {
        switch (lo, hi) {
        case let (l?, h?): return "\(compact(l)) – \(compact(h))"
        case let (l?, nil): return "da \(compact(l))"
        case let (nil, h?): return "fino a \(compact(h))"
        default: return nil
        }
    }
}

// ── Vista principale: pipeline kanban ────────────────────────────────────────
struct LeadsHubView: View {
    @State private var leads: [RELead] = []
    @State private var loading = true
    @State private var search = ""
    @State private var sourceFilter: LeadSource? = nil
    @State private var selected: RELead? = nil
    @State private var editing: RELead? = nil      // form (nuovo o modifica)
    @State private var showNew = false

    private var filtered: [RELead] {
        leads.filter { l in
            (sourceFilter == nil || l.source == sourceFilter!.rawValue) &&
            (search.isEmpty || [l.name, l.email, l.phone, l.zone, l.assigned_to]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    private func inStage(_ s: LeadStage) -> [RELead] { filtered.filter { $0.stage == s.rawValue } }

    private var pipelineValue: Int {
        leads.filter { !LeadStage.from($0.stage).isClosed }
             .compactMap { $0.budget_max ?? $0.budget_min }.reduce(0, +)
    }
    private var nuoviCount: Int { leads.filter { $0.stage == LeadStage.nuovo.rawValue }.count }
    private var vintiCount: Int { leads.filter { $0.stage == LeadStage.vinto.rawValue }.count }
    private var conversion: Int {
        let closed = leads.filter { LeadStage.from($0.stage).isClosed }.count
        guard closed > 0 else { return 0 }
        return Int((Double(vintiCount) / Double(closed) * 100).rounded())
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 16) {
                header
                kpiBar
                filterRow
                if loading {
                    Spacer(); HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }; Spacer()
                } else {
                    board
                }
            }
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 24, trailing: 30))
            .blur(radius: selected != nil ? 2 : 0)
            .disabled(selected != nil)

            if selected != nil {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                LeadDrawerView(
                    lead: Binding(get: { selected ?? leads.first! }, set: { selected = $0 }),
                    onStage: { stage in Task { await changeStage(selected!, to: stage) } },
                    onEdit: { editing = selected; selected = nil; showNew = true },
                    onDelete: { Task { await remove(selected!) } },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 420)
                .transition(.move(edge: .trailing))
            }
        }
        .task { await load() }
        .sheet(isPresented: $showNew, onDismiss: { editing = nil }) {
            LeadFormView(existing: editing) { await load() }
        }
    }

    // header
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LEADS").font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                Text("Pipeline richieste — GZ Ibiza Properties")
                    .font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
            Spacer()
            Button { editing = nil; showNew = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("Nuovo lead").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Color(hex: 0x0b1220))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Holo.hsl(210, 90, 66)))
            }
            .buttonStyle(.plain)
        }
    }

    // KPI
    private var kpiBar: some View {
        HStack(spacing: 12) {
            StatTile(label: "TOTALE", value: "\(leads.count)", hue: 210)
            StatTile(label: "NUOVI", value: "\(nuoviCount)", hue: 45)
            StatTile(label: "IN VISITA", value: "\(leads.filter { $0.stage == LeadStage.visita.rawValue }.count)", hue: 165)
            StatTile(label: "VALORE PIPELINE", value: pipelineValue > 0 ? LeadFmt.compact(pipelineValue) : "—", hue: 270)
            StatTile(label: "CONVERSIONE", value: conversion > 0 ? "\(conversion)%" : "—", hue: 145)
        }
    }

    // filtri fonte + ricerca
    private var filterRow: some View {
        HStack(spacing: 8) {
            sourceChip(nil, "Tutte")
            ForEach(LeadSource.allCases) { s in sourceChip(s, s.label) }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Csb.secFg)
                TextField("Cerca nome, zona, agente…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 200)
                    .foregroundStyle(Holo.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func sourceChip(_ s: LeadSource?, _ label: String) -> some View {
        let on = sourceFilter == s
        let c = s?.color ?? Holo.hsl(210, 30, 70)
        return Button { withAnimation(.easeOut(duration: 0.15)) { sourceFilter = s } } label: {
            HStack(spacing: 5) {
                if let s { Image(systemName: s.icon).font(.system(size: 9, weight: .semibold)) }
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(on ? Color(hex: 0x0b1220) : c)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? c : c.opacity(0.12)))
            .overlay(Capsule().strokeBorder(c.opacity(on ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // board kanban
    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(LeadStage.allCases) { stage in
                    StageColumn(
                        stage: stage,
                        leads: inStage(stage),
                        onSelect: { lead in withAnimation(.easeInOut(duration: 0.2)) { selected = lead } },
                        onDropLead: { id in Task { await changeStageById(id, to: stage) } }
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }

    // azioni
    private func load() async {
        loading = true
        do { leads = try await HubAPI.listReLeads() } catch { leads = [] }
        loading = false
    }
    private func changeStage(_ lead: RELead, to stage: LeadStage) async {
        await changeStageById(lead.id, to: stage)
        if var s = selected, s.id == lead.id { s.stage = stage.rawValue; selected = s }
    }
    private func changeStageById(_ id: String, to stage: LeadStage) async {
        guard let i = leads.firstIndex(where: { $0.id == id }), leads[i].stage != stage.rawValue else { return }
        leads[i].stage = stage.rawValue
        try? await HubAPI.setReLeadStage(id: id, stage: stage.rawValue)
    }
    private func remove(_ lead: RELead) async {
        try? await HubAPI.deleteReLead(id: lead.id)
        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
        leads.removeAll { $0.id == lead.id }
    }
}

// ── Colonna pipeline ─────────────────────────────────────────────────────────
private struct StageColumn: View {
    let stage: LeadStage
    let leads: [RELead]
    let onSelect: (RELead) -> Void
    let onDropLead: (String) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(stage.color).frame(width: 8, height: 8)
                    .shadow(color: stage.color.opacity(0.8), radius: 4)
                Text(stage.label.uppercased()).font(.system(size: 10.5, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(Holo.text)
                Text("\(leads.count)").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Csb.secFg)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(leads) { lead in
                        LeadCard(lead: lead).onTapGesture { onSelect(lead) }
                            .draggable(lead.id)
                    }
                    if leads.isEmpty {
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
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }; onDropLead(id); return true
        } isTargeted: { targeted = $0 }
    }
}

// ── Card lead ────────────────────────────────────────────────────────────────
private struct LeadCard: View {
    let lead: RELead
    @State private var hover = false
    private var src: LeadSource { .from(lead.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(lead.name).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Holo.titleText).lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: src.icon).font(.system(size: 8))
                    Text(src.label).font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(src.color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(src.color.opacity(0.14)))
            }
            if lead.interest != nil || lead.property_type != nil || lead.zone != nil {
                Text([lead.interest?.capitalized, lead.property_type, lead.zone].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
            }
            if let b = LeadFmt.budget(lead.budget_min, lead.budget_max) {
                Text(b).font(.system(size: 11, weight: .semibold)).foregroundStyle(Holo.hsl(150, 70, 66))
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
}

// ── Stat tile KPI ────────────────────────────────────────────────────────────
private struct StatTile: View {
    let label: String; let value: String; let hue: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Holo.hsl(hue, 70, 68))
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(Holo.titleText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Holo.hsl(hue, 60, 55).opacity(0.28), lineWidth: 1))
    }
}

// ── Drawer dettaglio lead ────────────────────────────────────────────────────
private struct LeadDrawerView: View {
    @Binding var lead: RELead
    let onStage: (LeadStage) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    private var src: LeadSource { .from(lead.source) }
    private var stage: LeadStage { .from(lead.stage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(lead.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Holo.titleText)
                    HStack(spacing: 4) {
                        Image(systemName: src.icon).font(.system(size: 9))
                        Text(src.label).font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(src.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(src.color.opacity(0.14)))
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
                    // pipeline
                    section("PIPELINE") {
                        FlowStages(current: stage) { onStage($0) }
                    }
                    // contatti
                    section("CONTATTI") {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow("phone.fill", lead.phone ?? "—")
                            infoRow("envelope.fill", lead.email ?? "—")
                            if let a = lead.assigned_to, !a.isEmpty { infoRow("person.fill", "Agente: \(a)") }
                        }
                    }
                    // richiesta
                    section("RICHIESTA") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let i = lead.interest { infoRow("tag.fill", i.capitalized) }
                            if let p = lead.property_type { infoRow("house.fill", p) }
                            if let z = lead.zone, !z.isEmpty { infoRow("mappin.circle.fill", z) }
                            if let n = lead.bedrooms { infoRow("bed.double.fill", "\(n) camere") }
                            if let b = LeadFmt.budget(lead.budget_min, lead.budget_max) { infoRow("eurosign.circle.fill", b) }
                            if let r = lead.idealista_ref, !r.isEmpty { infoRow("link", r) }
                        }
                    }
                    if let notes = lead.notes, !notes.isEmpty {
                        section("NOTE") {
                            Text(notes).font(.system(size: 12)).foregroundStyle(Holo.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }

            // azioni
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
    private func infoRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Csb.secFg).frame(width: 16)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Holo.text).textSelection(.enabled)
        }
    }
}

// mini binario stage cliccabile
private struct FlowStages: View {
    let current: LeadStage
    let onPick: (LeadStage) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(LeadStage.allCases) { s in
                let on = s == current
                Button { onPick(s) } label: {
                    Text(s.label).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(on ? Color(hex: 0x0b1220) : s.color)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? s.color : s.color.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(s.color.opacity(on ? 0 : 0.35), lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }
}

// ── Form nuovo / modifica lead ───────────────────────────────────────────────
private struct LeadFormView: View {
    let existing: RELead?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""; @State private var phone = ""; @State private var email = ""
    @State private var source = LeadSource.sito
    @State private var stage = LeadStage.nuovo
    @State private var interest = ""; @State private var propertyType = ""; @State private var zone = ""
    @State private var budgetMin = ""; @State private var budgetMax = ""; @State private var bedrooms = ""
    @State private var assignedTo = ""; @State private var idealistaRef = ""; @State private var notes = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "NUOVO LEAD" : "MODIFICA LEAD")
                .font(.system(size: 15, weight: .heavy)).tracking(3).foregroundStyle(Holo.titleText)
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Nome / contatto", $name, "Es. Marco Rossi")
                    HStack(spacing: 12) { field("Telefono", $phone, "+34 …"); field("Email", $email, "nome@email.com") }
                    // fonte
                    picker("Fonte", LeadSource.allCases.map { ($0.rawValue, $0.label) }, source.rawValue) { source = .from($0) }
                    picker("Stato pipeline", LeadStage.allCases.map { ($0.rawValue, $0.label) }, stage.rawValue) { stage = .from($0) }
                    HStack(spacing: 12) {
                        picker("Interesse", [("", "—")] + LeadInterest.allCases.map { ($0.rawValue, $0.label) }, interest) { interest = $0 }
                        picker("Tipo immobile", [("", "—")] + propertyTypes.map { ($0, $0) }, propertyType) { propertyType = $0 }
                    }
                    HStack(spacing: 12) { field("Zona", $zone, "Es. Ibiza centro"); field("Camere", $bedrooms, "3") }
                    HStack(spacing: 12) { field("Budget min €", $budgetMin, "500000"); field("Budget max €", $budgetMax, "900000") }
                    HStack(spacing: 12) { field("Agente", $assignedTo, "Giorgio"); field("Rif. Idealista", $idealistaRef, "URL / codice") }
                    fieldMulti("Note", $notes)
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(.plain)
                    .font(.system(size: 12.5)).foregroundStyle(Csb.secFg)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button {
                    Task { await save() }
                } label: {
                    Text(saving ? "Salvo…" : "Salva").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x0b1220))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(Holo.hsl(210, 90, 66)))
                }
                .buttonStyle(.plain).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 18, trailing: 24))
        }
        .frame(width: 560, height: 640)
        .background(Color(hex: 0x0c1120))
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard let e = existing else { return }
        name = e.name; phone = e.phone ?? ""; email = e.email ?? ""
        source = .from(e.source); stage = .from(e.stage)
        interest = e.interest ?? ""; propertyType = e.property_type ?? ""; zone = e.zone ?? ""
        budgetMin = e.budget_min.map(String.init) ?? ""; budgetMax = e.budget_max.map(String.init) ?? ""
        bedrooms = e.bedrooms.map(String.init) ?? ""
        assignedTo = e.assigned_to ?? ""; idealistaRef = e.idealista_ref ?? ""; notes = e.notes ?? ""
    }

    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let body: [String: Any?] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "phone": s(phone), "email": s(email), "source": source.rawValue, "stage": stage.rawValue,
            "interest": s(interest), "property_type": s(propertyType), "zone": s(zone),
            "budget_min": Int(budgetMin), "budget_max": Int(budgetMax), "bedrooms": Int(bedrooms),
            "assigned_to": s(assignedTo), "idealista_ref": s(idealistaRef), "notes": s(notes),
        ]
        do {
            if let e = existing { try await HubAPI.updateReLead(id: e.id, fields: body) }
            else { try await HubAPI.createReLead(body) }
            await onSaved(); dismiss()
        } catch { saving = false }
    }

    // helper campi
    private func field(_ label: String, _ text: Binding<String>, _ ph: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Holo.labelDim)
            TextField(ph, text: text).textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Holo.text)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }
    private func fieldMulti(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Holo.labelDim)
            TextEditor(text: text).font(.system(size: 12.5)).foregroundStyle(Holo.text)
                .scrollContentBackground(.hidden).frame(height: 70).padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
    private func picker(_ label: String, _ opts: [(String, String)], _ sel: String, _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Holo.labelDim)
            Menu {
                ForEach(opts, id: \.0) { o in Button(o.1) { set(o.0) } }
            } label: {
                HStack {
                    Text(opts.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 12.5)).foregroundStyle(Holo.text)
                    Spacer(); Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Csb.secFg)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity)
    }
}
