import SwiftUI

// ─── Definizione stadi pipeline (griglia 4×2 a serpentina, come ProgettoDettaglio.tsx) ───
private struct PipeCard {
    let label: String
    let mapStatus: String?
    let icon: String   // SF Symbol equivalente delle icone SVG
}
private let PIPE_CARDS: [PipeCard] = [
    .init(label: "Leads", mapStatus: nil, icon: "chart.bar.fill"),
    .init(label: "Call fissata", mapStatus: "call_fissata", icon: "phone"),
    .init(label: "Call effettuata", mapStatus: "call_effettuata", icon: "phone.badge.checkmark"),
    .init(label: "Demo fissata", mapStatus: "demo_fissata", icon: "calendar"),
    .init(label: "Clienti", mapStatus: "chiuso_vinto", icon: "trophy"),
    .init(label: "Negoziazione", mapStatus: "negoziazione", icon: "arrow.left.arrow.right"),
    .init(label: "Proposta inviata", mapStatus: "proposta_inviata", icon: "paperplane"),
    .init(label: "Demo effettuata", mapStatus: "demo_effettuata", icon: "play.display"),
]
// Flusso a serpentina: 0→1→2→3→7→6→5→4
private let FLOW_EDGES: [(Int, Int)] = [(0,1),(1,2),(2,3),(3,7),(7,6),(6,5),(5,4)]
// varco ampio tra le card: il filamento del flusso vive lì
private let PIPE_GAP: CGFloat = 30

// ─── Model del dettaglio ───
@MainActor
final class DettaglioModel: ObservableObject {
    @Published var project: Project
    @Published var events: [HubEvent] = []
    @Published var statusCounts: [String: Int] = [:]
    @Published var tipoServizioCounts: [String: Int] = [:]
    @Published var error: String?
    @Published var loaded = false

    init(project: Project) { self.project = project }

    var totalLeads: Int { statusCounts.values.reduce(0, +) }

    func load() async {
        do {
            if let fresh = try await HubAPI.getProject(slug: project.slug) { project = fresh }
            async let e = HubAPI.listRecentEvents()
            async let c = HubAPI.leadStatusCounts(projectId: project.id)
            async let s = HubAPI.leadTipoServizioCounts(projectId: project.id)
            let (events, counts, svc) = try await (e, c, s)
            self.events = events.filter { $0.project_id == project.id }
            self.statusCounts = counts
            self.tipoServizioCounts = svc
            self.loaded = true
        } catch { self.error = error.localizedDescription }
    }
}

// ─── Pagina dettaglio progetto ───
struct ProgettoDettaglioView: View {
    let tab: ProjectTab
    @StateObject private var model: DettaglioModel
    @State private var editing = false

    init(project: Project, tab: ProjectTab) {
        self.tab = tab
        _model = StateObject(wrappedValue: DettaglioModel(project: project))
    }

    var body: some View {
        Group {
            switch tab {
            case .dash: dashBody
            case .code: ProgettoCodeView(project: model.project)
            case .altro: altroBody
            }
        }
        .task(id: model.project.id) { await model.load() }
        .sheet(isPresented: $editing) {
            ProjectModalView(project: model.project) { Task { await model.load() } }
        }
    }

    private var dashBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backLink
                if let err = model.error {
                    GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                }
                if !model.loaded {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if model.totalLeads == 0 {
                    simpleLayout
                } else {
                    EnergizzoLayout(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
    }

    private var backLink: some View {
        Button { AppState.shared.route = .progetti } label: {
            Text("← PROGETTI")
                .font(.system(size: 11)).tracking(1.5)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    // Layout semplice per progetti senza leads (come la versione Tauri)
    private var simpleLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(model.project.name.uppercased())
                    .font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                StatusBadge(status: model.project.status)
                Spacer()
                Button("Modifica") { editing = true }.buttonStyle(.bordered)
            }
            if let d = model.project.description, !d.isEmpty {
                Text(d).font(.system(size: 11.5)).lineSpacing(4)
                    .foregroundStyle(Color(red: 180/255, green: 205/255, blue: 245/255).opacity(0.7))
            }
            if let n = model.project.notes, !n.isEmpty {
                Text(n).font(.system(size: 10.5)).lineSpacing(4)
                    .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ATTIVITÀ RECENTI (14 GIORNI)")
                        .font(.system(size: 9.5, weight: .heavy)).tracking(2)
                        .foregroundStyle(Holo.labelDim)
                    SkyBars(values: bucketEventsByDay(model.events, days: 14), hue: model.project.hue, height: 60)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 14, leading: 17, bottom: 12, trailing: 17))
            }
        }
    }

    private var altroBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backLink
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Altro · \(model.project.slug)")
                            .font(.system(size: 11, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Holo.labelDim)
                        Text("Sezione in arrivo — qui decideremo cosa metterci (note, deploy, documenti, eventi…).")
                            .font(.system(size: 12.5)).lineSpacing(5)
                            .foregroundStyle(Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.7))
                    }
                    .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
                }
                .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
    }
}

// ─── Layout Energizzo completo (progetto con leads) ───
private struct EnergizzoLayout: View {
    @ObservedObject var model: DettaglioModel
    @State private var activeView = "tab"        // tab | card | map
    @State private var activeFilter: String? = nil

    var body: some View {
        let svc = groupTipoServizio(model.tipoServizioCounts)
        VStack(alignment: .leading, spacing: 16) {
            // TopRow: barre attività + tipo servizio
            HStack(spacing: 16) {
                SkyBars(values: bucketEventsByDay(model.events, days: 14), hue: model.project.hue, height: 80)
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
                    .frame(maxWidth: .infinity)
                    .background(LinearGradient(
                        colors: [Holo.hsl(model.project.hue, 60, 30).opacity(0.22),
                                 Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Holo.hsl(model.project.hue, 85, 62).opacity(0.45), lineWidth: 1))

                ServicePanel(dual: svc.dual, elet: svc.elet, gas: svc.gas, total: svc.total)
            }

            // Pipeline board
            GlassCard {
                VStack(spacing: 0) {
                    PipelineBoard(statusCounts: model.statusCounts, totalLeads: model.totalLeads,
                                  activeFilter: $activeFilter, onMapJump: {
                        if activeView == "map" { activeView = "tab" }
                    })
                    if activeFilter != nil {
                        Button("mostra tutti") { activeFilter = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 11)).tracking(1)
                            .foregroundStyle(Color(hex: 0xcfe3ff)).underline()
                            .padding(.top, 6)
                    }
                }
                .padding(14)
            }

            // Tabs vista: Tabella · Card · Mappa
            HStack(spacing: 6) {
                viewTab("tab", "▦ Tabella")
                viewTab("card", "⊞ Card")
                viewTab("map", "⊙ Mappa")
            }

            switch activeView {
            case "tab": LeadsTableView(model: model, activeFilter: activeFilter)
            case "card": LeadsCardGridView(model: model, activeFilter: activeFilter)
            default: HoloMapView(model: model)
            }
        }
    }

    private func viewTab(_ id: String, _ label: String) -> some View {
        let on = activeView == id
        return Button { activeView = id } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold)).tracking(1)
                .foregroundStyle(on ? Color(hex: 0xe8f2ff) : Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? Color(red: 40/255, green: 70/255, blue: 140/255).opacity(0.5) : Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
                .overlay(Capsule().strokeBorder(on ? Holo.hsl(217, 85, 62).opacity(0.7) : Color(red: 125/255, green: 175/255, blue: 1).opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// ─── Pannello tipo servizio: cap Dual/Elettrico/Gas + scie animate ───
private struct ServicePanel: View {
    let dual: Int, elet: Int, gas: Int, total: Int

    private func pct(_ n: Int) -> Int { total > 0 ? Int((Double(n) / Double(total) * 100).rounded()) : 0 }

    var body: some View {
        GlassCard {
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    cap("Dual", n: dual, hue: 152, bolt: true, flame: true)
                    cap("Elettrico", n: elet, hue: 38, bolt: true, flame: false)
                    cap("Gas", n: gas, hue: 217, bolt: false, flame: true)
                }
                SparkField(dual: dual, elet: elet, gas: gas, total: total)
                    .frame(height: 36)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
        }
        .frame(maxWidth: .infinity)
    }

    private func cap(_ label: String, n: Int, hue: Double, bolt: Bool, flame: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if bolt { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Holo.hsl(38, 92, 62)) }
                if flame { Image(systemName: "flame.fill").font(.system(size: 9)).foregroundStyle(Holo.hsl(217, 90, 65)) }
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.labelDim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(n)").font(.system(size: 22, weight: .black)).foregroundStyle(Holo.hsl(hue, 90, 68))
                    .shadow(color: Holo.hsl(hue, 90, 60).opacity(0.55), radius: 6)
                Text("\(pct(n))%").font(.system(size: 10, weight: .semibold)).foregroundStyle(Holo.subDim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Holo.hsl(hue, 90, 60))
                        .frame(width: geo.size.width * CGFloat(pct(n)) / 100)
                        .shadow(color: Holo.hsl(hue, 90, 60).opacity(0.8), radius: 4)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Scie che salgono (replica .spark di holo.css) — TimelineView + Canvas
private struct SparkField: View {
    let dual: Int, elet: Int, gas: Int, total: Int

    private struct Spark { let hue: Double; let x: CGFloat; let speed: Double; let phase: Double; let h: CGFloat }
    private var sparks: [Spark] {
        guard total > 0 else { return [] }
        var rng = SeededRandom(seed: 42)
        let defs: [(Double, Int)] = [
            (152, max(2, Int((Double(dual) / Double(total) * 28).rounded()))),
            (38, max(1, Int((Double(elet) / Double(total) * 28).rounded()))),
            (217, max(1, Int((Double(gas) / Double(total) * 28).rounded()))),
        ]
        return defs.flatMap { (hue, n) in
            (0..<n).map { _ in
                Spark(hue: hue, x: CGFloat(3 + rng.next() * 94) / 100,
                      speed: 1.6 + rng.next() * 2.2, phase: rng.next() * 3.5,
                      h: CGFloat(8 + rng.next() * 14))
            }
        }
    }

    var body: some View {
        let items = sparks
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                for s in items {
                    // progresso 0→1 ciclico: parte dal basso e sale
                    let p = ((t / s.speed) + s.phase).truncatingRemainder(dividingBy: 1)
                    let y = size.height - CGFloat(p) * (size.height + s.h)
                    let rect = CGRect(x: s.x * size.width, y: y, width: 1.5, height: s.h)
                    let color = Color(hue: s.hue / 360, saturation: 0.9, brightness: 0.95)
                        .opacity(0.85 * (1 - p * 0.6))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .clipped()
    }
}

/// RNG deterministico (niente Math.random in layout: stessa scena a ogni render)
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64.max >> 11)
    }
}

// ─── Pipeline board 4×2 con filamenti di flusso ───
private struct PipelineBoard: View {
    let statusCounts: [String: Int]
    let totalLeads: Int
    @Binding var activeFilter: String?
    var onMapJump: () -> Void

    var body: some View {
        VStack(spacing: PIPE_GAP) {
            row(indices: [0, 1, 2, 3])
            row(indices: [4, 5, 6, 7])
        }
        .backgroundStyle(.clear)
        .background(FlowLines())
    }

    private func row(indices: [Int]) -> some View {
        HStack(spacing: PIPE_GAP) {
            ForEach(indices, id: \.self) { i in
                pipeCard(PIPE_CARDS[i])
            }
        }
    }

    private func value(_ c: PipeCard) -> Int {
        guard let s = c.mapStatus else { return totalLeads }
        return statusCounts[s] ?? 0
    }

    private func pipeCard(_ c: PipeCard) -> some View {
        let sel = c.mapStatus != nil && c.mapStatus == activeFilter
        return Button {
            activeFilter = c.mapStatus
            onMapJump()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value(c))")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Holo.hsl(217, 90, 72))
                    .shadow(color: Holo.hsl(217, 90, 60).opacity(0.6), radius: 6)
                Text(c.label.uppercased())
                    .font(.system(size: 8.5, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(Holo.labelDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .overlay(alignment: .topTrailing) {
                Image(systemName: c.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Holo.hsl(217, 80, 65).opacity(0.55))
                    .padding(8)
            }
            // sfondo OPACO: il filamento del flusso deve vedersi solo nei varchi tra le card
            .background(sel ? Color(red: 14/255, green: 22/255, blue: 46/255) : Color(red: 8/255, green: 12/255, blue: 26/255))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(sel ? Holo.hsl(217, 90, 65).opacity(0.9) : Holo.hsl(217, 70, 50).opacity(0.35),
                              lineWidth: sel ? 1.5 : 1))
            .shadow(color: sel ? Holo.hsl(217, 90, 55).opacity(0.4) : .clear, radius: 9)
        }
        .buttonStyle(.plain)
    }
}

/// Filamenti del flusso a serpentina dietro le card, con raggio animato
private struct FlowLines: View {
    // centri delle 8 card nella griglia 4×2 (spacing PIPE_GAP)
    private func flowPath(in size: CGSize) -> Path {
        let cw = (size.width - 3 * PIPE_GAP) / 4, ch = (size.height - PIPE_GAP) / 2
        func center(_ i: Int) -> CGPoint {
            let row = i / 4, col = i % 4
            return CGPoint(x: CGFloat(col) * (cw + 14) + cw / 2,
                           y: CGFloat(row) * (ch + 14) + ch / 2)
        }
        return Path { p in
            for (a, b) in FLOW_EDGES {
                p.move(to: center(a))
                p.addLine(to: center(b))
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let path = flowPath(in: geo.size)
            ZStack {
                path.stroke(Color(red: 140/255, green: 180/255, blue: 250/255).opacity(0.4), lineWidth: 3)
                // raggio lento che percorre tutta la serpentina (~8s a giro)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat(t.truncatingRemainder(dividingBy: 8.0) / 8.0)
                    path.trim(from: max(0, phase - 0.05), to: phase)
                        .stroke(Holo.hsl(217, 95, 78), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .shadow(color: Holo.hsl(217, 95, 65).opacity(0.95), radius: 6)
                }
            }
        }
    }
}
