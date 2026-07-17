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
    var color: Color { Holo.hsl(hue, 80, 62) }
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

    private var filtered: [Solicitud] {
        guard !search.isEmpty else { return model.items }
        return model.items.filter {
            [$0.nombreCompleto, $0.email, $0.telefono ?? "", $0.mensaje ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private func inStage(_ s: SolEstado) -> [Solicitud] { filtered.filter { $0.estado == s.rawValue } }
    private func count(_ e: SolEstado) -> Int { model.items.filter { $0.estado == e.rawValue }.count }
    private var inLavorazione: Int {
        model.items.filter { let e = SolEstado.from($0.estado); return e != .nuevo && !e.isClosed }.count
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 16) {
                header
                statRow
                searchRow
                if model.loading {
                    HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 40)
                } else if let err = model.error {
                    GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else {
                    board
                }
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
                    onNotas: { txt in Task { await model.setNotas(sel.id, txt) } },
                    onDelete: {
                        Task { await model.remove(sel) }
                        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
                    },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 430)
                .transition(.move(edge: .trailing))
            }
        }
        .task { await model.load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RICHIESTE WEB")
                    .font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                Text("Pipeline richieste — form del sito wallis57.com")
                    .font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
            Spacer()
            Button { Task { await model.load() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Holo.labelDim).padding(8)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }.buttonStyle(.plain)
        }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            statCard("NUOVE", count(.nuevo), hue: 220, glow: count(.nuevo) > 0)
            statCard("IN LAVORAZIONE", inLavorazione, hue: 190, glow: false)
            statCard("VINTE", count(.vinto), hue: 145, glow: false)
            statCard("TOTALI", model.items.count, hue: 270, glow: false)
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

    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Csb.secFg)
                TextField("Cerca nome, email, messaggio…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 240)
                    .foregroundStyle(Holo.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            Spacer()
            Text("Trascina le schede per cambiare stato")
                .font(.system(size: 10)).foregroundStyle(Holo.labelDim.opacity(0.7))
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
                    ForEach(items) { s in
                        SolCard(s: s)
                            .onTapGesture { onSelect(s) }
                            .draggable(s.id)
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

// ── Card richiesta ─────────────────────────────────────────────────────────────
private struct SolCard: View {
    let s: Solicitud
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(s.nombreCompleto.isEmpty ? "—" : s.nombreCompleto)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Holo.titleText).lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: "globe").font(.system(size: 8))
                    Text("Sito").font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(Holo.hsl(210, 78, 66))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Holo.hsl(210, 78, 66).opacity(0.14)))
            }
            if let mail = clean(s.email) {
                Text(mail).font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
            }
            if let tel = clean(s.telefono) {
                Text(tel).font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
            }
            if let msg = clean(s.mensaje) {
                Text(msg).font(.system(size: 10.5)).lineSpacing(2)
                    .foregroundStyle(Holo.text.opacity(0.8)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(fmtDate(s.created_at)).font(.system(size: 9)).foregroundStyle(Holo.labelDim.opacity(0.8))
                Spacer()
                if let n = s.notas, !n.isEmpty {
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
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(Holo.titleText)
                    Text(estado.label.uppercased())
                        .font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
                        .foregroundStyle(estado.color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(estado.color.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(estado.color.opacity(0.5), lineWidth: 1))
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
                            ForEach(SolEstado.allCases) { e in
                                let on = e == estado
                                Button { onStage(e) } label: {
                                    Text(e.label).font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(on ? Color(hex: 0x0b1220) : e.color)
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
                                if notas.isEmpty {
                                    Text("Aggiungi una nota…").font(.system(size: 12)).foregroundStyle(Csb.secFg)
                                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 0)).allowsHitTesting(false)
                                }
                                TextEditor(text: $notas)
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
                                    onNotas(notas)
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

            // azioni
            HStack(spacing: 10) {
                if let mail = clean(s.email) {
                    Link(destination: URL(string: "mailto:\(mail)")!) {
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
        .onAppear { notas = s.notas ?? "" }
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
