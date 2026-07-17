import SwiftUI

// ============================================================================
// Wallis 57 — dashboard di progetto
// Sezione "Richieste web": le solicitudes inviate dal form del sito wallis57
// (tabella public.solicitudes_web su Supabase) arrivano qui, le nuove come
// stato "nuevo". Stile coerente con la sezione Leads.
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

// ── Stati richiesta (il form entra come "nuevo") ─────────────────────────────
enum SolEstado: String, CaseIterable, Identifiable {
    case nuevo, contactado, cerrado, descartado
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nuevo: return "Nuevo"
        case .contactado: return "Contactado"
        case .cerrado: return "Cerrado"
        case .descartado: return "Descartado"
        }
    }
    var hue: Double {
        switch self {
        case .nuevo: return 30       // arancio caldo (spicca)
        case .contactado: return 205
        case .cerrado: return 145
        case .descartado: return 5
        }
    }
    var color: Color { Holo.hsl(hue, 82, 62) }
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
        do { items = try await HubAPI.listSolicitudesWeb() ; error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    func setEstado(_ s: Solicitud, _ e: SolEstado) async {
        if let i = items.firstIndex(where: { $0.id == s.id }) { items[i].estado = e.rawValue }
        try? await HubAPI.setSolicitudEstado(id: s.id, estado: e.rawValue)
    }
    func remove(_ s: Solicitud) async {
        items.removeAll { $0.id == s.id }
        try? await HubAPI.deleteSolicitud(id: s.id)
    }
}

// ── Dashboard ─────────────────────────────────────────────────────────────────
struct WallisDashboard: View {
    @StateObject private var model = WallisModel()
    @State private var filtro: SolEstado? = nil

    private var visibili: [Solicitud] {
        guard let f = filtro else { return model.items }
        return model.items.filter { $0.estado == f.rawValue }
    }
    private func count(_ e: SolEstado) -> Int { model.items.filter { $0.estado == e.rawValue }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statRow
            filterRow
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 40)
            } else if let err = model.error {
                GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
            } else if visibili.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(visibili) { s in SolicitudRow(s: s, model: model) }
                }
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
                    .shadow(color: Holo.hsl(30, 90, 60).opacity(0.6), radius: 9)
                Text("Wallis 57 · form del sito wallis57.com")
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
            statCard("NUOVE", count(.nuevo), hue: 30, glow: count(.nuevo) > 0)
            statCard("CONTATTATE", count(.contactado), hue: 205, glow: false)
            statCard("CHIUSE", count(.cerrado), hue: 145, glow: false)
            statCard("TOTALI", model.items.count, hue: 217, glow: false)
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

    private var filterRow: some View {
        HStack(spacing: 7) {
            chip(filtro == nil, "Tutte", 217) { filtro = nil }
            ForEach(SolEstado.allCases) { e in
                chip(filtro == e, e.label, e.hue) { filtro = filtro == e ? nil : e }
            }
            Spacer()
        }
    }

    private func chip(_ on: Bool, _ label: String, _ hue: Double, _ act: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { act() } } label: {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Holo.titleText : Holo.labelDim)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(on ? Holo.hsl(hue, 70, 45).opacity(0.55) : Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
                .overlay(Capsule().strokeBorder(on ? Holo.hsl(hue, 85, 62).opacity(0.7) : Color.white.opacity(0.1), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var emptyState: some View {
        GlassCard {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(Holo.labelDim)
                Text("Nessuna richiesta").font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.subDim)
                Text("Le richieste dal form del sito appariranno qui come 'Nuevo'.")
                    .font(.system(size: 11)).foregroundStyle(Holo.labelDim)
            }
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 34, leading: 20, bottom: 34, trailing: 20))
        }
    }
}

// ── Riga richiesta ─────────────────────────────────────────────────────────────
private struct SolicitudRow: View {
    let s: Solicitud
    @ObservedObject var model: WallisModel

    private var estado: SolEstado { .from(s.estado) }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.nombreCompleto.isEmpty ? "—" : s.nombreCompleto)
                            .font(.system(size: 14.5, weight: .bold)).foregroundStyle(Holo.titleText)
                        HStack(spacing: 12) {
                            if let mail = clean(s.email) {
                                contact("envelope.fill", mail)
                            }
                            if let tel = clean(s.telefono) {
                                contact("phone.fill", tel)
                            }
                        }
                    }
                    Spacer()
                    estadoBadge
                }

                if let msg = clean(s.mensaje) {
                    Text(msg).font(.system(size: 12)).lineSpacing(3)
                        .foregroundStyle(Holo.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Text(fmtDate(s.created_at)).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                    Spacer()
                    // avanza stato
                    Menu {
                        ForEach(SolEstado.allCases) { e in
                            Button(e.label) { Task { await model.setEstado(s, e) } }
                        }
                        Divider()
                        Button("Elimina", role: .destructive) { Task { await model.remove(s) } }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Stato").font(.system(size: 10.5, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Holo.labelDim)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain).menuStyle(.borderlessButton).fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 12, trailing: 16))
        }
    }

    private var estadoBadge: some View {
        Text(estado.label.uppercased())
            .font(.system(size: 9, weight: .heavy)).tracking(1.2)
            .foregroundStyle(estado.color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(estado.color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(estado.color.opacity(0.5), lineWidth: 1))
    }

    private func contact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Holo.labelDim)
            Text(text).font(.system(size: 11)).foregroundStyle(Holo.subDim)
        }
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
