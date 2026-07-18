import SwiftUI

// ============================================================================
// Wallis 57 — dashboard di progetto
// Sezione "Richieste web": le solicitudes inviate dal form del sito wallis57
// (tabella public.solicitudes_web su Supabase) arrivano qui come "nuevo".
// Board kanban con drag&drop lungo la pipeline (stile sezione Leads).
// ============================================================================

// ── Modello (rispecchia public.solicitudes_web) ──────────────────────────────
struct Solicitud: Identifiable, Decodable, Equatable {
    let id: String
    var nombre: String
    var apellido: String?
    var telefono: String?
    var email: String
    var mensaje: String?
    var estado: String
    var origen: String?
    var sitio: String?
    var notas: String?
    let created_at: String?

    var nombreCompleto: String {
        [nombre, apellido ?? ""].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// ── Stati pipeline (il form entra come "nuevo") ──────────────────────────────
enum SolEstado: String, CaseIterable, Identifiable {
    case nuevo, contactado, qualificato, visita, proposta, trattativa, vinto, perso
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nuevo: return "Nuovo"
        case .contactado: return "Contattato"
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
        case .nuevo: return 220
        case .contactado: return 205
        case .qualificato: return 190
        case .visita: return 45
        case .proposta: return 165
        case .trattativa: return 270
        case .vinto: return 145
        case .perso: return 5
        }
    }
    /// Stesse tinte desaturate della pipeline lead: le due board si leggono uguali.
    var color: Color {
        switch self {
        case .nuevo:      return UI.accent
        case .contactado, .qualificato, .visita, .proposta, .trattativa: return UI.tint(.corso)
        case .vinto:      return UI.tint(.ok)
        case .perso:      return UI.tint(.stop)
        }
    }
    var isClosed: Bool { self == .vinto || self == .perso }
    static func from(_ raw: String?) -> SolEstado { SolEstado(rawValue: raw ?? "") ?? .nuevo }
}

// ── API ──────────────────────────────────────────────────────────────────────
extension HubAPI {
    static func listSolicitudesWeb(sitio: String = "wallis-57") async throws -> [Solicitud] {
        try await sb.fetch("solicitudes_web?select=*&sitio=eq.\(sitio)&order=created_at.desc&limit=1000")
    }
    static func setSolicitudEstado(id: String, estado: String) async throws {
        try await sb.mutate("solicitudes_web?id=eq.\(id)", method: "PATCH", body: ["estado": estado])
    }
    static func setSolicitudNotas(id: String, notas: String?) async throws {
        try await sb.mutate("solicitudes_web?id=eq.\(id)", method: "PATCH", body: ["notas": notas])
    }
    @discardableResult
    static func createSolicitud(_ fields: [String: Any?]) async throws -> Solicitud {
        try await sb.insertReturning("solicitudes_web", body: fields)
    }
    static func updateSolicitud(id: String, fields: [String: Any?]) async throws {
        try await sb.mutate("solicitudes_web?id=eq.\(id)", method: "PATCH", body: fields)
    }
    static func deleteSolicitud(id: String) async throws {
        try await sb.mutate("solicitudes_web?id=eq.\(id)", method: "DELETE")
    }
}

// ── Model osservabile ─────────────────────────────────────────────────────────
@MainActor
final class WallisModel: ObservableObject {
    @Published var items: [Solicitud] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true
        do { items = try await HubAPI.listSolicitudesWeb(); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    func setEstadoById(_ id: String, _ e: SolEstado) async {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].estado != e.rawValue else { return }
        items[i].estado = e.rawValue
        try? await HubAPI.setSolicitudEstado(id: id, estado: e.rawValue)
    }
    func setNotas(_ id: String, _ notas: String) async {
        let v = notas.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].notas = v.isEmpty ? nil : v }
        try? await HubAPI.setSolicitudNotas(id: id, notas: v.isEmpty ? nil : v)
    }
    func remove(_ s: Solicitud) async {
        items.removeAll { $0.id == s.id }
        try? await HubAPI.deleteSolicitud(id: s.id)
    }
}

// ── Dashboard ─────────────────────────────────────────────────────────────────
struct WallisDashboard: View {
    @StateObject private var model = WallisModel()
    @State private var search = ""
    @State private var selected: Solicitud?
    @State private var mostraAgente = false
    @State private var fonte: LeadSource?
    @State private var mostraForm = false
    @State private var inModifica: Solicitud?     // nil = nuova richiesta

    private var filtered: [Solicitud] {
        model.items.filter { s in
            let okFonte = fonte == nil || LeadSource.from(s.origen) == fonte!
            guard okFonte else { return false }
            guard !search.isEmpty else { return true }
            return [s.nombreCompleto, s.email, s.telefono ?? "", s.mensaje ?? "", s.notas ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private func inStage(_ s: SolEstado) -> [Solicitud] { filtered.filter { $0.estado == s.rawValue } }
    private func count(_ e: SolEstado) -> Int { model.items.filter { $0.estado == e.rawValue }.count }
    private var inLavorazione: Int {
        model.items.filter { let e = SolEstado.from($0.estado); return e != .nuevo && !e.isClosed }.count
    }
    private var daWhatsApp: Int {
        model.items.filter { LeadSource.from($0.origen) == .whatsapp }.count
    }
    /// Vinte sul totale delle chiuse: le richieste ancora aperte non contano.
    private var conversione: Int {
        let chiuse = model.items.filter { SolEstado.from($0.estado).isClosed }.count
        guard chiuse > 0 else { return 0 }
        return Int((Double(count(.vinto)) / Double(chiuse) * 100).rounded())
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 14) {
                header
                statRow

                SectionCard(title: "Richieste web", count: model.items.count, icon: "square.stack.3d.up") {
                    filtri
                } content: {
                    if model.loading {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 40)
                    } else if let err = model.error {
                        Text("Errore: \(err)").font(.system(size: 12)).foregroundStyle(UI.tint(.stop))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else {
                        board
                    }
                }

                WhatsAppSection(slug: "wallis-57")
            }
            .blur(radius: selected != nil ? 2 : 0)
            .disabled(selected != nil)

            if let sel = selected {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                SolDrawerView(
                    s: sel,
                    onStage: { e in
                        Task { await model.setEstadoById(sel.id, e) }
                        if var s = selected { s.estado = e.rawValue; selected = s }
                    },
                    onNotas: { txt in
                        Task { await model.setNotas(sel.id, txt) }
                        if var s = selected { s.notas = txt; selected = s }
                    },
                    onDelete: {
                        Task { await model.remove(sel) }
                        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
                    },
                    onEdit: {
                        inModifica = sel
                        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
                        mostraForm = true
                    },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 430)
                .transition(.move(edge: .trailing))
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $mostraAgente) {
            AgenteSheet(slug: "wallis-57") { mostraAgente = false }
        }
        .sheet(isPresented: $mostraForm, onDismiss: { inModifica = nil }) {
            SolFormView(existing: inModifica) { await model.load() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Wallis 57")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(UI.ink)
                Text("Richieste dal form di wallis57.com e conversazioni WhatsApp")
                    .font(.system(size: 11.5)).foregroundStyle(UI.faint)
            }
            Spacer()
            GhostButton(label: "Nuova richiesta", icon: "plus") { inModifica = nil; mostraForm = true }
            GhostButton(label: "Agente", icon: "gearshape.2") { mostraAgente = true }
            GhostButton(label: "Aggiorna", icon: "arrow.clockwise") { Task { await model.load() } }
        }
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            StatTile(label: "Nuove", value: count(.nuevo), evidenzia: true)
            StatTile(label: "In lavorazione", value: inLavorazione)
            StatTile(label: "Da WhatsApp", value: daWhatsApp)
            StatTile(label: "Vinte", value: count(.vinto))
            StatTile(label: "Totali", value: model.items.count)
            StatTile(label: "Conversione", testo: conversione > 0 ? "\(conversione)%" : "—")
        }
    }

    /// Stessa riga filtri della dash GZ Ibiza: chip per fonte + ricerca.
    private var filtri: some View {
        HStack(spacing: 6) {
            FilterChip(label: "Tutte", selected: fonte == nil) { fonte = nil }
            ForEach(LeadSource.attive) { s in
                FilterChip(label: s.label, icon: s.icon, selected: fonte == s) {
                    fonte = fonte == s ? nil : s
                }
            }
            HoloSearchField(placeholder: "Cerca richiesta…", text: $search, width: 150)
        }
    }

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(SolEstado.allCases) { stage in
                    SolStageColumn(
                        stage: stage,
                        items: inStage(stage),
                        onDrop: { id in Task { await model.setEstadoById(id, stage) } },
                        onSelect: { s in withAnimation(.easeInOut(duration: 0.2)) { selected = s } }
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// ── Colonna pipeline ─────────────────────────────────────────────────────────
private struct SolStageColumn: View {
    let stage: SolEstado
    let items: [Solicitud]
    let onDrop: (String) -> Void
    let onSelect: (Solicitud) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(stage.color).frame(width: 6, height: 6)
                Text(stage.label.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.9)
                    .foregroundStyle(UI.dim)
                Spacer(minLength: 4)
                Text("\(items.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(items.isEmpty ? UI.faint : UI.text)
            }
            .padding(.horizontal, 2)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(items) { s in
                        SolCard(s: s)
                            .onTapGesture { onSelect(s) }
                            .draggable(s.id)
                    }
                    if items.isEmpty {
                        Text("Nessuna richiesta").font(.system(size: 10.5)).foregroundStyle(UI.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                .padding(2)
            }
        }
        .frame(width: 236)
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

// ── Card richiesta ─────────────────────────────────────────────────────────────
private struct SolCard: View {
    let s: Solicitud
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(s.nombreCompleto.isEmpty ? "—" : s.nombreCompleto)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UI.ink).lineLimit(1)
                Spacer(minLength: 4)
                // Badge fonte letto da `origen`: sito, WhatsApp, chiamata…
                // (prima era un pill "Sito" fisso, che nascondeva la provenienza)
                let src = LeadSource.from(s.origen)
                Image(systemName: src.icon).font(.system(size: 9)).foregroundStyle(UI.faint)
                    .help(src.label)
            }
            if let mail = clean(s.email) {
                Text(mail).font(.system(size: 10.5)).foregroundStyle(UI.faint).lineLimit(1)
            }
            if let tel = clean(s.telefono) {
                Text(tel).font(.system(size: 10.5)).foregroundStyle(UI.faint).lineLimit(1)
            }
            if let msg = clean(s.mensaje) {
                Text(msg).font(.system(size: 10.5)).lineSpacing(2)
                    .foregroundStyle(UI.text.opacity(0.8)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(fmtDate(s.created_at)).font(.system(size: 9)).foregroundStyle(UI.faint.opacity(0.8))
                Spacer()
                if let n = s.notas, !n.isEmpty {
                    Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(UI.faint)
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

    private func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

// ── Drawer laterale: dettaglio richiesta + note ────────────────────────────────
private struct SolDrawerView: View {
    let s: Solicitud
    let onStage: (SolEstado) -> Void
    let onNotas: (String) -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    @State private var notas: String = ""
    @State private var savedFlash = false
    private var estado: SolEstado { .from(s.estado) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.nombreCompleto.isEmpty ? "—" : s.nombreCompleto)
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(UI.ink)
                    HStack(spacing: 6) {
                        Text(estado.label.uppercased())
                            .font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
                            .foregroundStyle(estado.color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(estado.color.opacity(0.16)))
                            .overlay(Capsule().strokeBorder(estado.color.opacity(0.5), lineWidth: 1))
                        // fonte: da dove è arrivata la richiesta (sito, WhatsApp, …)
                        let src = LeadSource.from(s.origen)
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
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.dim)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 46, leading: 22, bottom: 16, trailing: 20))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    section("PIPELINE") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(SolEstado.allCases) { e in
                                let on = e == estado
                                Button { onStage(e) } label: {
                                    Text(e.label).font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(on ? UI.ink : e.color)
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? e.color : e.color.opacity(0.12)))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(e.color.opacity(on ? 0 : 0.35), lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    section("CONTATTI") {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow("envelope.fill", clean(s.email) ?? "—")
                            infoRow("phone.fill", clean(s.telefono) ?? "—")
                            infoRow("calendar", fmtDate(s.created_at))
                        }
                    }
                    if let msg = clean(s.mensaje) {
                        section("RICHIESTA") {
                            Text(msg).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(UI.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section("NOTE") {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                                if notas.isEmpty {
                                    Text("Aggiungi una nota…").font(.system(size: 12)).foregroundStyle(UI.dim)
                                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 0)).allowsHitTesting(false)
                                }
                                TextEditor(text: $notas)
                                    .font(.system(size: 12.5)).foregroundStyle(UI.text)
                                    .scrollContentBackground(.hidden).background(Color.clear)
                                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                                    .frame(minHeight: 110)
                            }
                            HStack {
                                if savedFlash {
                                    Label("Salvato", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(UI.tint(.ok))
                                }
                                Spacer()
                                Button {
                                    onNotas(notas)
                                    savedFlash = true
                                    Task { try? await Task.sleep(nanoseconds: 1_600_000_000); savedFlash = false }
                                } label: {
                                    Text("Salva nota").font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(UI.ink)
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(Capsule().fill(UI.accent))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }

            // azioni
            HStack(spacing: 10) {
                if let tel = clean(s.telefono), let url = waURL(tel) {
                    Link(destination: url) {
                        Label("WhatsApp", systemImage: "message.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.ink).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                if let mail = clean(s.email), let mailURL = URL(string: "mailto:\(mail)") {
                    Link(destination: mailURL) {
                        Label("Rispondi", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.ink).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                GhostButton(label: "Modifica", icon: "pencil", action: onEdit)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(UI.tint(.stop))
                        .frame(width: 42, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(UI.tint(.stop).opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.tint(.stop).opacity(0.4), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 12, leading: 22, bottom: 18, trailing: 22))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UI.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(UI.line), alignment: .leading)
        .ignoresSafeArea()
        .onAppear { notas = s.notas ?? "" }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(UI.dim)
            content()
        }
    }
    private func infoRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(UI.dim).frame(width: 16)
            Text(text).font(.system(size: 12.5)).foregroundStyle(UI.text).textSelection(.enabled)
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

// ── Data ISO → "17 lug · 23:21" ────────────────────────────────────────────────
private func fmtDate(_ s: String?) -> String {
    guard let s else { return "" }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) ?? iso2.date(from: s) {
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM · HH:mm"
        return f.string(from: d)
    }
    return String(s.prefix(16)).replacingOccurrences(of: "T", with: " ")
}

// ── Form nuova / modifica richiesta ──────────────────────────────────────────
// Gemello di LeadFormView per il CRM immobiliare: qui i campi sono quelli del
// form del sito, gli unici che solicitudes_web conosce.
struct SolFormView: View {
    let existing: Solicitud?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var nombre = ""; @State private var apellido = ""
    @State private var email = ""; @State private var telefono = ""
    @State private var mensaje = ""; @State private var notas = ""
    @State private var estado = SolEstado.nuevo
    @State private var origen = LeadSource.sito
    @State private var saving = false
    @State private var errore: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Nuova richiesta" : "Modifica richiesta")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.ink)
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 12) { campo("Nome", $nombre, "Es. Laura"); campo("Cognome", $apellido, "Martín") }
                    HStack(spacing: 12) { campo("Email", $email, "nome@email.com"); campo("Telefono", $telefono, "+34 …") }
                    scelta("Fonte", LeadSource.attive.map { ($0.rawValue, $0.label) }, origen.rawValue) { origen = .from($0) }
                    scelta("Stato", SolEstado.allCases.map { ($0.rawValue, $0.label) }, estado.rawValue) { estado = .from($0) }
                    campoLungo("Richiesta", $mensaje)
                    campoLungo("Note interne", $notas)
                    if let e = errore {
                        Text(e).font(.system(size: 11)).foregroundStyle(UI.tint(.stop))
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }

            HStack(spacing: 10) {
                Spacer()
                GhostButton(label: "Annulla") { dismiss() }
                Button { salva() } label: {
                    Text(saving ? "Salvataggio…" : "Salva")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.ink)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(UI.accent.opacity(0.9)))
                }
                .buttonStyle(.plain)
                // L'email è obbligatoria in solicitudes_web: senza, l'insert fallisce
                .disabled(saving || nombre.trimmingCharacters(in: .whitespaces).isEmpty
                          || email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 20, trailing: 24))
        }
        .frame(width: 560, height: 620)
        .background(UI.panel)
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let s = existing else { return }
        nombre = s.nombre; apellido = s.apellido ?? ""
        email = s.email; telefono = s.telefono ?? ""
        mensaje = s.mensaje ?? ""; notas = s.notas ?? ""
        estado = .from(s.estado); origen = .from(s.origen)
    }

    private func salva() {
        saving = true; errore = nil
        let campi: [String: Any?] = [
            "nombre": nombre.trimmingCharacters(in: .whitespaces),
            "apellido": vuotoNil(apellido), "email": email.trimmingCharacters(in: .whitespaces),
            "telefono": vuotoNil(telefono), "mensaje": vuotoNil(mensaje), "notas": vuotoNil(notas),
            "estado": estado.rawValue, "origen": origen.rawValue, "sitio": "wallis-57",
        ]
        Task {
            do {
                if let s = existing { try await HubAPI.updateSolicitud(id: s.id, fields: campi) }
                else { try await HubAPI.createSolicitud(campi) }
                await onSaved()
                dismiss()
            } catch {
                errore = error.localizedDescription
                saving = false
            }
        }
    }
    private func vuotoNil(_ s: String) -> String? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines); return v.isEmpty ? nil : v
    }

    private func campo(_ label: String, _ text: Binding<String>, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.faint)
            TextField(hint, text: text)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UI.text)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func campoLungo(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.faint)
            TextEditor(text: text)
                .font(.system(size: 12.5)).foregroundStyle(UI.text)
                .scrollContentBackground(.hidden).background(Color.clear)
                .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                .frame(height: 70)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }
    private func scelta(_ label: String, _ opts: [(String, String)], _ sel: String,
                        _ onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.faint)
            HStack(spacing: 5) {
                ForEach(opts, id: \.0) { o in
                    FilterChip(label: o.1, selected: o.0 == sel) { onPick(o.0) }
                }
            }
        }
    }
}
