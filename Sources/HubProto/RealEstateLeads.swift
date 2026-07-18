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
    var category: String?
    var property_type: String?
    var zone: String?
    var budget_min: Int?
    var budget_max: Int?
    var bedrooms: Int?
    var notes: String?              // note interne (drawer, agente)
    var request_message: String?    // testo scritto dal cliente nel form del sito
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
    /// La fonte si distingue dall'icona, non dal colore: sei tinte sature una
    /// accanto all'altra rendevano la pagina un arcobaleno senza aggiungere
    /// informazione. Resta un grigio-blu uniforme.
    var color: Color { UI.tint(.neutro) }
    static func from(_ raw: String?) -> LeadSource { LeadSource(rawValue: raw ?? "") ?? .sito }

    /// I canali davvero collegati oggi: form del sito e agente WhatsApp.
    /// Gli altri restano nel modello (i dati storici possono averli) ma non si
    /// mostrano: filtrare per un canale che non esiste dà sempre zero risultati
    /// e fa sembrare rotta la pagina. Quando un canale entra in funzione, si
    /// aggiunge qui e compare ovunque.
    static let attive: [LeadSource] = [.sito, .whatsapp]
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
    /// Tinte desaturate della stessa famiglia: la pipeline si legge dalla
    /// posizione, il colore serve solo a separare "in corso" da "chiuso".
    var color: Color {
        switch self {
        case .nuovo:      return UI.accent
        case .contattato, .qualificato, .visita, .proposta, .trattativa: return UI.tint(.corso)
        case .vinto:      return UI.tint(.ok)
        case .perso:      return UI.tint(.stop)
        }
    }
    var isClosed: Bool { self == .vinto || self == .perso }
    static func from(_ raw: String?) -> LeadStage { LeadStage(rawValue: raw ?? "") ?? .nuovo }
}

enum LeadInterest: String, CaseIterable, Identifiable {
    case affitto, vendita, traspaso
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum LeadCategory: String, CaseIterable, Identifiable {
    case residenziale, commerciale
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

let propertyTypes = ["Appartamento", "Villa", "Attico", "Casale", "Terreno", "Commerciale"]

// ── API ──────────────────────────────────────────────────────────────────────
extension HubAPI {
    static func listReLeads() async throws -> [RELead] {
        try await sb.fetch("re_leads?select=*&order=created_at.desc&limit=2000")
    }
    static func reLeadsTotal() async throws -> Int {
        try await sb.count("re_leads?select=id")
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
    /// Separatore delle migliaia scritto a mano: il formato italiano non
    /// raggruppa i numeri di quattro cifre, e accanto a "€80.000" comparivano
    /// "€2666". Così il raggruppamento è sempre lo stesso.
    static func euro(_ n: Int) -> String {
        var cifre = ""
        for (i, c) in String(abs(n)).reversed().enumerated() {
            if i > 0 && i % 3 == 0 { cifre.append(".") }
            cifre.append(c)
        }
        return "€" + (n < 0 ? "-" : "") + String(cifre.reversed())
    }
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

// ── Form nuovo / modifica lead ───────────────────────────────────────────────
struct LeadFormView: View {
    let existing: RELead?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""; @State private var phone = ""; @State private var email = ""
    @State private var source = LeadSource.sito
    @State private var stage = LeadStage.nuovo
    @State private var interest = ""; @State private var category = ""; @State private var propertyType = ""; @State private var zone = ""
    @State private var budgetMin = ""; @State private var budgetMax = ""; @State private var bedrooms = ""
    @State private var assignedTo = ""; @State private var idealistaRef = ""; @State private var notes = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "NUOVO LEAD" : "MODIFICA LEAD")
                .font(.system(size: 15, weight: .heavy)).tracking(3).foregroundStyle(Holo.titleText)
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    field("Nome / contatto", $name, "Es. Marco Rossi")
                    HStack(spacing: 12) { field("Telefono", $phone, "+34 …"); field("Email", $email, "nome@email.com") }
                    // fonte
                    picker("Fonte", LeadSource.attive.map { ($0.rawValue, $0.label) }, source.rawValue) { source = .from($0) }
                    picker("Stato pipeline", LeadStage.allCases.map { ($0.rawValue, $0.label) }, stage.rawValue) { stage = .from($0) }
                    HStack(spacing: 12) {
                        picker("Interesse", [("", "—")] + LeadInterest.allCases.map { ($0.rawValue, $0.label) }, interest) { interest = $0 }
                        picker("Categoria", [("", "—")] + LeadCategory.allCases.map { ($0.rawValue, $0.label) }, category) { category = $0 }
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
        interest = e.interest ?? ""; category = e.category ?? ""; propertyType = e.property_type ?? ""; zone = e.zone ?? ""
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
            "interest": s(interest), "category": s(category), "property_type": s(propertyType), "zone": s(zone),
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
                HStack(spacing: 8) {
                    Text(opts.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 12.5)).foregroundStyle(Holo.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Csb.secFg)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity)
    }
}
