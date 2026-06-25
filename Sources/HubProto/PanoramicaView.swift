import SwiftUI

// ─── Palette holo (replica holo.css tema default) ───
enum Holo {
    static let text = Color(red: 0xd7/255, green: 0xe7/255, blue: 0xff/255)
    static let titleText = Color(red: 0xe8/255, green: 0xf2/255, blue: 0xff/255)
    static let labelDim = Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65)
    static let subDim = Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.6)
    static let cardBorder = Color(red: 130/255, green: 180/255, blue: 255/255).opacity(0.32)

    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
        // HSL→Color (SwiftUI usa HSB)
        let s1 = s / 100, l1 = l / 100
        let v = l1 + s1 * min(l1, 1 - l1)
        let sb = v == 0 ? 0 : 2 * (1 - l1 / v)
        return Color(hue: h / 360, saturation: sb, brightness: v)
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(
                LinearGradient(
                    colors: [Color(red: 18/255, green: 28/255, blue: 58/255).opacity(0.92),
                             Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.94)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Holo.cardBorder, lineWidth: 1))
            .shadow(color: Color(red: 20/255, green: 50/255, blue: 140/255).opacity(0.3), radius: 17)
    }
}

struct StatusBadge: View {
    let status: String
    var body: some View {
        let (fg, bg, bd, label): (Color, Color, Color, String) = {
            switch status {
            case "live":  return (Color(hex: 0x9af0c5), Color(hex: 0x34d399).opacity(0.14), Color(hex: 0x34d399).opacity(0.55), "LIVE")
            case "dev":   return (Color(hex: 0xffd9a0), Color(red: 1, green: 160/255, blue: 30/255).opacity(0.16), Color(red: 1, green: 180/255, blue: 60/255).opacity(0.6), "DEV")
            case "pausa": return (Color(hex: 0xffb3ad), Color(red: 229/255, green: 57/255, blue: 53/255).opacity(0.22), Color(red: 1, green: 90/255, blue: 80/255).opacity(0.7), "PAUSA")
            default:      return (Color(hex: 0xa8cdff), Color(red: 88/255, green: 166/255, blue: 1).opacity(0.14), Color(red: 88/255, green: 166/255, blue: 1).opacity(0.5), status.uppercased())
            }
        }()
        Text(label)
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(1)
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(bd, lineWidth: 1))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

/// Vetrina barre vive (replica SkyBars.tsx) — pulse animato come pulse2d
struct SkyBars: View {
    let values: [Int]
    let hue: Double
    var height: CGFloat = 30
    @State private var pulse = false

    var body: some View {
        let maxV = max(values.max() ?? 1, 1)
        let empty = values.allSatisfy { $0 == 0 }
        Group {
            if empty {
                // nessun dato reale → barre decorative (onda morbida) solo per effetto scenico
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<14, id: \.self) { i in
                        let v = 0.30 + 0.42 * (0.5 + 0.5 * sin(Double(i) * 0.7))
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                            .fill(LinearGradient(
                                colors: [Holo.hsl(hue, 80, 62), Holo.hsl(hue, 75, 42)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(height: 3 + CGFloat(v) * (height - 6))
                            .opacity(pulse ? 0.5 : 0.26)
                            .scaleEffect(y: pulse ? 1 : 0.6, anchor: .bottom)
                            .animation(.easeInOut(duration: 2.4).repeatForever().delay(Double(i) * -0.13), value: pulse)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height, alignment: .bottom)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                            .fill(LinearGradient(
                                colors: [Holo.hsl(hue, 95, 70), Holo.hsl(hue, 90, 48)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(height: 3 + CGFloat(v) / CGFloat(maxV) * (height - 6))
                            .shadow(color: Holo.hsl(hue, 95, 62).opacity(0.7), radius: 3)
                            .scaleEffect(y: pulse ? 1 : 0.64, anchor: .bottom)
                            .opacity(pulse ? 1 : 0.85)
                            .animation(.easeInOut(duration: 2.4).repeatForever().delay(Double(i) * -0.13), value: pulse)
                    }
                }
                .frame(height: height, alignment: .bottom)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Holo.hsl(hue, 80, 60).opacity(0.35)).frame(height: 1) }
        .onAppear { pulse = true }
    }
}

struct ProjectCardView: View {
    let project: Project
    let events: [HubEvent]
    @State private var hovering = false

    var body: some View {
        let buckets = bucketEventsByDay(events.filter { $0.project_id == project.id }, days: 14)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Holo.titleText)
                Spacer()
                StatusBadge(status: project.status)
            }
            Text(project.description ?? "")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(red: 180/255, green: 205/255, blue: 245/255).opacity(0.65))
                .lineSpacing(3)
                .frame(minHeight: 30, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
            SkyBars(values: buckets, hue: project.hue)
        }
        .padding(EdgeInsets(top: 12, leading: 13, bottom: 10, trailing: 13))
        .background(
            LinearGradient(colors: [Holo.hsl(project.hue, 60, 30).opacity(0.22),
                                    Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Holo.hsl(project.hue, 85, 62).opacity(hovering ? 0.8 : 0.45), lineWidth: 1))
        .shadow(color: Holo.hsl(project.hue, 85, 48).opacity(hovering ? 0.3 : 0.14), radius: 11)
        .onHover { hovering = $0 }
        .onTapGesture { AppState.shared.route = .progetto(slug: project.slug, tab: .dash) }
    }
}

struct KpiCard: View {
    let label: String
    let value: String
    let sub: String
    let hue: Double
    @State private var breathe = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.labelDim)
                Text(value)
                    .font(.system(size: 31, weight: .black))
                    .foregroundStyle(Holo.hsl(hue, 90, 70))
                    .shadow(color: Holo.hsl(hue, 90, 60).opacity(0.6), radius: 8)
                    .padding(.top, 6)
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(Holo.subDim)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 15, leading: 17, bottom: 13, trailing: 17))
            .overlay(alignment: .bottom) {
                // basebar con breathe
                LinearGradient(colors: [Holo.hsl(hue, 85, 55), Holo.hsl(hue, 90, 70), Holo.hsl(hue, 85, 55)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4)
                    .shadow(color: Holo.hsl(hue, 90, 60).opacity(0.9), radius: 7)
                    .brightness(breathe ? 0.12 : -0.06)
                    .animation(.easeInOut(duration: 3.2).repeatForever(), value: breathe)
            }
        }
        .onAppear { breathe = true }
    }
}

@MainActor
final class PanoramicaModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var events: [HubEvent] = []
    @Published var leadsTotal: Int?
    @Published var error: String?

    func load() async {
        do {
            async let p = HubAPI.listProjects()
            async let e = HubAPI.listRecentEvents()
            async let c = HubAPI.leadsTotal()
            (projects, events, leadsTotal) = try await (p, e, c)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PanoramicaView: View {
    @ObservedObject var model: PanoramicaModel

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("PANORAMICA")
                        .font(.system(size: 19, weight: .heavy))
                        .tracking(5)
                        .foregroundStyle(Holo.titleText)
                        .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                        .padding(.bottom, 4)

                    if let err = model.error {
                        GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                    }

                    HStack(spacing: 16) {
                        KpiCard(label: "Progetti attivi", value: "\(model.projects.count)",
                                sub: "\(model.projects.filter { $0.status == "live" }.count) live · \(model.projects.filter { $0.status != "live" && $0.status != "pausa" }.count) in lavorazione",
                                hue: 217)
                        KpiCard(label: "Eventi oggi", value: "\(todayCount)",
                                sub: "\(model.events.count) negli ultimi 14 giorni", hue: 270)
                        KpiCard(label: "Leads in pipeline",
                                value: model.leadsTotal.map(String.init) ?? "—",
                                sub: "dentro Energizzo", hue: 25)
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                Text("PROGETTI")
                                    .font(.system(size: 14, weight: .heavy)).tracking(2.5)
                                    .foregroundStyle(Holo.hsl(217, 90, 70))
                                    .shadow(color: Holo.hsl(217, 90, 60).opacity(0.65), radius: 7)
                                Spacer()
                                Text("ATTIVITÀ ULTIMI 14 GIORNI")
                                    .font(.system(size: 10)).tracking(1.5)
                                    .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13), count: 4),
                                      alignment: .leading, spacing: 13) {
                                ForEach(model.projects) { p in
                                    ProjectCardView(project: p, events: model.events)
                                }
                            }
                        }
                        .padding(EdgeInsets(top: 17, leading: 19, bottom: 15, trailing: 19))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
            }
    }

    private var todayCount: Int {
        let cal = Calendar.current
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        return model.events.filter { e in
            guard let d = iso.date(from: e.created_at) ?? isoPlain.date(from: e.created_at) else { return false }
            return cal.isDateInToday(d)
        }.count
    }
}

// Sfondo: griglia fitta di puntini tondi, statici e discreti.
struct DataGridHeroBackground: View {
    var tint = Color(red: 86/255, green: 134/255, blue: 244/255)
    var step: CGFloat = 26
    var dot: CGFloat = 2
    var body: some View {
        Canvas { ctx, size in
            let color = tint.opacity(0.10)
            var y: CGFloat = step / 2
            while y <= size.height {
                var x: CGFloat = step / 2
                while x <= size.width {
                    let r = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    ctx.fill(Path(ellipseIn: r), with: .color(color))
                    x += step
                }
                y += step
            }
        }
        .mask(RadialGradient(colors: [.black, .black.opacity(0.5), .clear],
                             center: UnitPoint(x: 0.5, y: 0.40), startRadius: 120, endRadius: 880))
    }
}

/// Griglia 64px con mask radiale (replica body::before di holo.css)
struct GridLines: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 64
            let color = Color(red: 70/255, green: 120/255, blue: 230/255).opacity(0.055)
            var x: CGFloat = 0
            while x <= size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(color))
                y += step
            }
        }
        .mask(
            RadialGradient(colors: [.black, .clear],
                           center: UnitPoint(x: 0.55, y: 0.4), startRadius: 250, endRadius: 800)
        )
    }
}
