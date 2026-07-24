import SwiftUI

/// I progetti che sono agenzie immobiliari: stessa dash, stesse tabelle, dati
/// separati da `project_slug`. Aggiungerne una vuol dire aggiungere lo slug qui
/// e la riga in `projects` — non serve altro codice.
let AGENZIE_IMMOBILIARI: Set<String> = ["gz-ibiza", "wallis-57"]

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
            }
        }
        .task(id: model.project.id) { await model.load() }
        .sheet(isPresented: $editing) {
            ProjectModalView(project: model.project) { Task { await model.load() } }
        }
    }

    private var dashBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                backLink
                if model.project.slug == "camere-pse" {
                    // dash dedicata Camere PSE: pannello prenotazioni camere
                    CamerePSEDashboard()
                } else if model.project.slug == "ncreative" {
                    // dash dedicata NCREATIVE: CRM dell'agenzia social (clienti,
                    // pipeline, calendario contenuti, fatture e spese)
                    NCreativeDashboard()
                } else if AGENZIE_IMMOBILIARI.contains(model.project.slug) {
                    // GZ Ibiza e Wallis 57 sono la stessa agenzia immobiliare due
                    // volte: identica dash, dati separati da project_slug.
                    ImmobiliareDashboard(slug: model.project.slug, titolo: model.project.name)
                } else {
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

}

// ─── Layout Energizzo completo (progetto con leads) ───
private struct EnergizzoLayout: View {
    @ObservedObject var model: DettaglioModel
    @State private var activeView = "tab"        // tab | card | map
    @State private var activeFilter: String? = nil
    @State private var searchText = ""

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

            // Tabs vista: Tabella · Card · Mappa + ricerca
            HStack(spacing: 6) {
                viewTab("tab", "▦ Tabella")
                viewTab("card", "⊞ Card")
                viewTab("map", "⊙ Mappa")
                searchField
                Spacer(minLength: 0)
            }

            switch activeView {
            case "tab": LeadsTableView(model: model, activeFilter: activeFilter, search: searchText)
            case "card": LeadsCardGridView(model: model, activeFilter: activeFilter, search: searchText)
            default: HoloMapView(model: model)
            }
        }
    }

    private var searchField: some View {
        HoloSearchField(placeholder: "Cerca ragione sociale…", text: $searchText, width: 190, radius: 999)
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
                    StatCap(label: "Dual", n: dual, pct: pct(dual), hue: 152, bolt: true, flame: true)
                    StatCap(label: "Elettrico", n: elet, pct: pct(elet), hue: 38, bolt: true, flame: false)
                    StatCap(label: "Gas", n: gas, pct: pct(gas), hue: 217, bolt: false, flame: true)
                }
                // bande proporzionali al mix (verde Dual · ambra Elettrico · blu Gas)
                WaveEqualizer(hueAt: { f in
                    let d = total > 0 ? CGFloat(dual) / CGFloat(total) : 0.34
                    let e = total > 0 ? CGFloat(elet) / CGFloat(total) : 0.33
                    return f < d ? 152 : (f < d + e ? 38 : 217)
                })
                .frame(height: 36)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Mini-stat con barra (usata dai pannelli servizio Energizzo ed EasyAct).
struct StatCap: View {
    let label: String
    let n: Int
    let pct: Int
    let hue: Double
    var bolt = false
    var flame = false

    var body: some View {
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
                Text("\(pct)%").font(.system(size: 10, weight: .semibold)).foregroundStyle(Holo.subDim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Holo.hsl(hue, 90, 60))
                        .frame(width: geo.size.width * CGFloat(pct) / 100)
                        .shadow(color: Holo.hsl(hue, 90, 60).opacity(0.8), radius: 4)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Equalizer ordinato: barre equidistanti mosse da un'onda morbida che viaggia;
/// hueAt(0..1) decide il colore per posizione (bande proporzionali).
struct WaveEqualizer: View {
    let hueAt: (CGFloat) -> Double
    var n = 44

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let slot = size.width / CGFloat(n)
                let bw: CGFloat = 2.5
                for i in 0..<n {
                    let f = CGFloat(i) / CGFloat(n - 1)
                    // onda sinusoidale che scorre: ordinata, discreta
                    let wave = 0.5 + 0.5 * sin(t * 1.3 + Double(i) * 0.45)
                    let h = 5 + CGFloat(wave) * (size.height - 7)
                    let x = slot * CGFloat(i) + (slot - bw) / 2
                    let color = Color(hue: hueAt(f) / 360, saturation: 0.82, brightness: 0.96)
                        .opacity(0.28 + 0.55 * wave)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - h, width: bw, height: h),
                                  cornerRadius: 1.25), with: .color(color))
                }
            }
        }
        .clipped()
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
                pipeCard(PIPE_CARDS[i], index: i)
            }
        }
    }

    private func value(_ c: PipeCard) -> Int {
        guard let s = c.mapStatus else { return totalLeads }
        return statusCounts[s] ?? 0
    }

    private func pipeCard(_ c: PipeCard, index i: Int) -> some View {
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
                FlowIcon(systemName: c.icon, node: i)
            }
            // sfondo OPACO: il filamento del flusso deve vedersi solo nei varchi tra le card
            .background(sel ? Color(red: 14/255, green: 22/255, blue: 46/255) : Color(red: 8/255, green: 12/255, blue: 26/255))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(sel ? Holo.hsl(217, 90, 65).opacity(0.9) : Holo.hsl(217, 70, 50).opacity(0.35),
                              lineWidth: sel ? 1.5 : 1))
            .overlay(CardFlowBorder(node: i))   // cometa che fa il giro al passaggio del flusso
            .shadow(color: sel ? Holo.hsl(217, 90, 55).opacity(0.4) : .clear, radius: 9)
        }
        .buttonStyle(PipeCardButtonStyle())
    }
}

/// Niente fade di opacità alla pressione (il default .plain rende la card
/// semi-trasparente e scopre il filamento del flusso dietro): solo un micro-scale.
private struct PipeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// ─── Flusso RILASSATO: un solo fascio morbido che scorre lento e poi riposa
//     (ispirato ai "pulse beam / gradient tracing" di 21st.dev) ───
private let FLOW_PERIOD = 15.0                       // ciclo completo, lento
private let FLOW_TRAVEL = 0.72                        // frazione in viaggio; il resto è pausa
private let FLOW_ORDER = [0, 1, 2, 3, 7, 6, 5, 4]    // ordine di percorrenza (serpentina)

/// Posizione 0→1 della testa del fascio con easing dolce; nil durante la pausa.
private func flowHead(at t: Double) -> Double? {
    let c = (t / FLOW_PERIOD).truncatingRemainder(dividingBy: 1)
    guard c < FLOW_TRAVEL else { return nil }
    let u = c / FLOW_TRAVEL
    return u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2   // easeInOut
}

/// Quanto un nodo è illuminato dal fascio (0→1), con dolce dissolvenza.
private func flowGlow(node: Int, at t: Double) -> Double {
    guard let head = flowHead(at: t),
          let idx = FLOW_ORDER.firstIndex(of: node) else { return 0 }
    let pos = Double(idx) / Double(FLOW_ORDER.count - 1)
    return max(0, 1 - abs(head - pos) / 0.13)
}

/// Bordo della card che si illumina dolcemente al passaggio del fascio (niente cometa veloce).
private struct CardFlowBorder: View {
    let node: Int
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let g = flowGlow(node: node, at: tl.date.timeIntervalSinceReferenceDate)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Holo.hsl(217, 92, 72).opacity(0.85 * g), lineWidth: 1.5)
                .shadow(color: Holo.hsl(217, 95, 66).opacity(0.6 * g), radius: 9 * g)
        }
    }
}

/// Icona di un nodo che si illumina e cresce DOLCEMENTE al passaggio del fascio.
private struct FlowIcon: View {
    let systemName: String
    let node: Int
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let g = flowGlow(node: node, at: tl.date.timeIntervalSinceReferenceDate)
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(Holo.hsl(217, 85, 60 + 28 * g))
                .opacity(0.55 + 0.45 * g)
                .scaleEffect(1 + 0.12 * g)
                .shadow(color: Holo.hsl(217, 95, 70).opacity(0.7 * g), radius: 7 * g)
                .padding(8)
        }
    }
}

/// Filamenti del flusso a serpentina dietro le card, con raggio animato
private struct FlowLines: View {
    // centri delle 8 card nella griglia 4×2 (spacing PIPE_GAP)
    private func flowPath(in size: CGSize) -> Path {
        let cw = (size.width - 3 * PIPE_GAP) / 4, ch = (size.height - PIPE_GAP) / 2
        func center(_ i: Int) -> CGPoint {
            let row = i / 4, col = i % 4
            return CGPoint(x: CGFloat(col) * (cw + PIPE_GAP) + cw / 2,
                           y: CGFloat(row) * (ch + PIPE_GAP) + ch / 2)
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
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let head = flowHead(at: tl.date.timeIntervalSinceReferenceDate)
                ZStack {
                    // binario di base, tenue e statico
                    path.stroke(Color(red: 140/255, green: 180/255, blue: 250/255).opacity(0.26),
                                lineWidth: 2)
                    // un solo fascio morbido con coda lunga sfumata, che scorre lento
                    if let head {
                        let h = CGFloat(head)
                        path.trim(from: max(0, h - 0.16), to: h)
                            .stroke(Holo.hsl(217, 92, 74).opacity(0.8),
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .shadow(color: Holo.hsl(217, 95, 66).opacity(0.55), radius: 5)
                    }
                }
            }
        }
    }
}
