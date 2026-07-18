import SwiftUI

@MainActor
final class GZIbizaModel: ObservableObject {
    @Published var leads: [RELead] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        do { leads = try await HubAPI.listReLeads(); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Mutazione ottimistica + PATCH: la card si sposta subito sotto il dito.
    func setStage(_ id: String, _ stage: LeadStage) async {
        guard let i = leads.firstIndex(where: { $0.id == id }) else { return }
        leads[i].stage = stage.rawValue
        try? await HubAPI.setReLeadStage(id: id, stage: stage.rawValue)
    }
}

// ─── Dash GZ Ibiza: pipeline lead + conversazioni WhatsApp ───────────────────
struct GZIbizaDashboard: View {
    @StateObject private var model = GZIbizaModel()
    @State private var search = ""
    @State private var fonte: LeadSource?
    @State private var mostraAgente = false

    private var filtered: [RELead] {
        model.leads.filter { l in
            let okFonte = fonte == nil || l.source == fonte!.rawValue
            guard okFonte else { return false }
            guard !search.isEmpty else { return true }
            return [l.name, l.email ?? "", l.phone ?? "", l.zone ?? "", l.notes ?? ""]
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
                        onDrop: { id in Task { await model.setStage(id, stage) } })
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
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(stage.color).frame(width: 7, height: 7)
                Text(stage.label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1)
                    .foregroundStyle(Holo.subDim)
                Spacer()
                Text("\(items.count)").font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Holo.labelDim)
            }
            .padding(.horizontal, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(items) { l in
                        GZLeadCard(lead: l).draggable(l.id)
                    }
                }
            }
        }
        .frame(width: 250)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(targeted ? stage.color.opacity(0.1) : Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? stage.color.opacity(0.6) : Color.white.opacity(0.05), lineWidth: 1))
        .dropDestination(for: String.self) { ids, _ in
            ids.forEach(onDrop); return true
        } isTargeted: { targeted = $0 }
    }
}

// ─── Card lead, con badge fonte ──────────────────────────────────────────────
private struct GZLeadCard: View {
    let lead: RELead

    var body: some View {
        let src = LeadSource.from(lead.source)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(lead.name).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Holo.titleText).lineLimit(1)
                Spacer(minLength: 4)
                // Badge fonte: sito, WhatsApp, chiamata…
                HStack(spacing: 3) {
                    Image(systemName: src.icon).font(.system(size: 7.5))
                    Text(src.label).font(.system(size: 8, weight: .heavy))
                }
                .foregroundStyle(src.color)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(src.color.opacity(0.14)))
            }

            if let z = lead.zone, !z.isEmpty {
                Label(z, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 10)).foregroundStyle(Holo.subDim).lineLimit(1)
            }
            if let b = LeadFmt.budget(lead.budget_min, lead.budget_max) {
                Text(b).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Holo.hsl(150, 70, 65))
            }
            if let n = lead.notes, !n.isEmpty {
                Text(n).font(.system(size: 9.5)).foregroundStyle(Holo.labelDim).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
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
