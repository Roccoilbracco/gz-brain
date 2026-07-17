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
    func remove(_ s: Solicitud) async {
        items.removeAll { $0.id == s.id }
        try? await HubAPI.deleteSolicitud(id: s.id)
    }
}

// ── Dashboard ─────────────────────────────────────────────────────────────────
struct WallisDashboard: View {
    @StateObject private var model = WallisModel()
    @State private var search = ""

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
                        onDelete: { s in Task { await model.remove(s) } }
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
    let onDelete: (Solicitud) -> Void
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
                        SolCard(s: s, onDelete: { onDelete(s) })
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
    let onDelete: () -> Void
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
                if hover {
                    Button { onDelete() } label: {
                        Image(systemName: "trash").font(.system(size: 9)).foregroundStyle(Holo.hsl(5, 70, 62))
                    }.buttonStyle(.plain)
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
