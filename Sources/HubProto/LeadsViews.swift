import SwiftUI
import MapKit
import AppKit

// ─── Avatar con anello temperatura (replica LeadAvatar) ───
struct LeadAvatarView: View {
    let name: String
    let status: String
    var size: CGFloat = 26

    var body: some View {
        let (temp, hot) = LEAD_TEMP[status] ?? (20, false)
        let col = hot ? Color(hex: 0xffd28a) : Color(hex: 0x9ec9ff)
        let ring = hot ? Color(hex: 0xf59e0b) : Color(hex: 0x3b82f6)
        let ini = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(2).compactMap { $0.first.map(String.init) }
            .joined().uppercased()
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(temp) / 100)
                .stroke(AngularGradient(colors: [col, ring], center: .center),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: col.opacity(hot ? 0.8 : 0.5), radius: hot ? 4 : 3)
            Text(ini.isEmpty ? "·" : ini)
                .font(.system(size: size * 0.34, weight: .heavy))
                .foregroundStyle(col)
        }
        .frame(width: size, height: size)
    }
}

struct LeadStatusBadgeView: View {
    let status: String
    var body: some View {
        let (fg, bg, bd, label): (UInt32, Double, Double, String) = {
            switch status {
            case "chiuso_vinto": return (0x9af0c5, 0.14, 0.55, "CLIENTE")
            case "perso": return (0xffb3ad, 0.22, 0.7, "PERSO")
            case "demo_fissata": return (0xffd9a0, 0.16, 0.6, "DEMO FISSATA")
            case "demo_effettuata": return (0xffd9a0, 0.16, 0.6, "DEMO")
            case "proposta_inviata": return (0xffd9a0, 0.16, 0.6, "PROPOSTA")
            case "negoziazione": return (0xffd9a0, 0.16, 0.6, "NEGOZIAZIONE")
            default: return (0xa8cdff, 0.14, 0.5, (STATUS_LABELS[status] ?? status).uppercased())
            }
        }()
        let base: Color = {
            switch status {
            case "chiuso_vinto": return Color(hex: 0x34d399)
            case "perso": return Color(red: 229/255, green: 57/255, blue: 53/255)
            case "demo_fissata", "demo_effettuata", "proposta_inviata", "negoziazione":
                return Color(red: 1, green: 170/255, blue: 45/255)
            default: return Color(red: 88/255, green: 166/255, blue: 1)
            }
        }()
        Text(label)
            .font(.system(size: 9.5, weight: .heavy)).tracking(1)
            .foregroundStyle(Color(hex: fg))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(base.opacity(bg)))
            .overlay(Capsule().strokeBorder(base.opacity(bd), lineWidth: 1))
            .fixedSize()
    }
}

func openExternal(_ urlString: String) {
    if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
}

// ─── Tabella leads con paginazione (replica EnergizzoTable) ───
struct LeadsTableView: View {
    @ObservedObject var model: DettaglioModel
    let activeFilter: String?

    @State private var leads: [Lead] = []
    @State private var loading = false
    @State private var page = 0
    private let pageSize = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassCard {
                VStack(spacing: 0) {
                    headerRow
                    Divider().overlay(Color.white.opacity(0.08))
                    if loading {
                        Text("Caricamento…").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                            .frame(maxWidth: .infinity).padding(24)
                    } else if leads.isEmpty {
                        Text("Nessun lead in questo stadio").font(.system(size: 12))
                            .foregroundStyle(Holo.labelDim)
                            .frame(maxWidth: .infinity).padding(24)
                    } else {
                        ForEach(leads) { lead in leadRow(lead) }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 9) {
                Button("← Prec") { page -= 1 }.disabled(page == 0)
                Text("Pagina \(page + 1)").font(.system(size: 11)).foregroundStyle(Holo.subDim)
                Button("Succ →") { page += 1 }.disabled(leads.count < pageSize)
            }
        }
        .task(id: "\(activeFilter ?? "all")-\(page)") { await load() }
        .onChange(of: activeFilter) { page = 0 }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            leads = try await HubAPI.listLeads(projectId: model.project.id, status: activeFilter,
                                               limit: pageSize, offset: page * pageSize)
        } catch { leads = [] }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            th("RAGIONE SOCIALE", flex: 2.2)
            th("COMUNE (PROV)", flex: 1.2)
            th("TIPO SERVIZIO", flex: 1)
            th("CATEGORIA", flex: 1)
            th("STATO", flex: 1)
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func th(_ t: String, flex: CGFloat) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(1.3)
            .foregroundStyle(Holo.labelDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(flex)
    }

    private func leadRow(_ lead: Lead) -> some View {
        Button {
            AppState.shared.route = .lead(slug: model.project.slug, leadId: lead.id)
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    LeadAvatarView(name: lead.ragione_sociale, status: lead.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lead.ragione_sociale)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Holo.titleText).lineLimit(1)
                        if let piva = lead.piva {
                            Text(piva).font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(2.2)
                td(lead.comune.map { "\($0)\(lead.provincia.map { " (\($0))" } ?? "")" } ?? "—", flex: 1.2)
                td(lead.tipo_servizio ?? "—", flex: 1, bright: true)
                td(lead.categoria ?? "—", flex: 1)
                LeadStatusBadgeView(status: lead.status)
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func td(_ t: String, flex: CGFloat, bright: Bool = false) -> some View {
        Text(t).font(.system(size: 11.5))
            .foregroundStyle(bright ? Holo.text : Color(red: 180/255, green: 205/255, blue: 245/255).opacity(0.65))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(flex)
    }
}

// ─── Card grid con mini-Italia (replica LeadsCardGrid) ───
struct LeadsCardGridView: View {
    @ObservedObject var model: DettaglioModel
    let activeFilter: String?

    @State private var leads: [Lead] = []
    @State private var loading = false
    private let cardLimit = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("CARD · LEADS").font(.system(size: 11, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.hsl(217, 90, 70))
                Text(loading ? "…" : "\(leads.count)\(leads.count >= cardLimit ? "+" : "")")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Holo.subDim)
                if let f = activeFilter {
                    Text(f.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0xffd9a0))
                }
            }
            if loading {
                Text("Caricamento…").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                    .frame(maxWidth: .infinity).padding(36)
            } else if leads.isEmpty {
                Text("Nessun lead").font(.system(size: 12)).foregroundStyle(Holo.labelDim)
                    .frame(maxWidth: .infinity).padding(36)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(leads) { lead in
                        LeadCardView(lead: lead) {
                            AppState.shared.route = .lead(slug: model.project.slug, leadId: lead.id)
                        }
                    }
                }
            }
            Text("CONFINI REALI ISTAT (openpolis/geojson-italy, CC-BY) · PIN DA LAT/LON VERE\(leads.count >= cardLimit ? " · PRIME \(cardLimit) CARD" : "")")
                .font(.system(size: 8.5)).tracking(1)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.35))
        }
        .task(id: activeFilter ?? "all") { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            leads = try await HubAPI.listLeads(projectId: model.project.id, status: activeFilter, limit: cardLimit)
        } catch { leads = [] }
    }
}

struct LeadCardView: View {
    let lead: Lead
    let onClick: () -> Void

    var body: some View {
        let (temp, hot) = LEAD_TEMP[lead.status] ?? (20, false)
        let col = hot ? Color(hex: 0xffd28a) : Color(hex: 0x9ec9ff)
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        LeadAvatarView(name: lead.ragione_sociale, status: lead.status, size: 24)
                        Text(lead.ragione_sociale)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Holo.titleText)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let cat = lead.categoria {
                        Text(cat.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
                            .foregroundStyle(Color(hex: 0xa8cdff))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Color(red: 88/255, green: 166/255, blue: 1).opacity(0.5), lineWidth: 1))
                    }
                    if let comune = lead.comune {
                        Text("\(comune)\(lead.provincia.map { " (\($0))" } ?? "")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(red: 180/255, green: 205/255, blue: 245/255).opacity(0.65))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        LeadStatusBadgeView(status: lead.status)
                        Text("\(temp)°").font(.system(size: 10, weight: .heavy)).foregroundStyle(col)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Mini Italia con pin
                ItalyMini(lat: lead.latitude, lon: lead.longitude, hot: hot)
                    .frame(width: 66, height: 86)
            }
            .padding(11)
            .background(LinearGradient(
                colors: [Color(red: 14/255, green: 22/255, blue: 46/255).opacity(0.92),
                         Color(red: 8/255, green: 13/255, blue: 28/255).opacity(0.94)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder((hot ? Holo.hsl(25, 85, 60) : Holo.hsl(217, 70, 55)).opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Mini-mappa Italia in SwiftUI Path (path condiviso, scala dal viewBox 100×131.2)
struct ItalyMini: View {
    let lat: Double?
    let lon: Double?
    let hot: Bool

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 100, geo.size.height / 131.2)
            let t = CGAffineTransform(scaleX: scale, y: scale)
            let path = Italy.path.applying(t)
            ZStack {
                path.fill(Color(red: 60/255, green: 110/255, blue: 230/255).opacity(0.07))
                path.stroke(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.4), lineWidth: 0.6)
                if let lat, let lon {
                    let pt = CGPoint(x: Italy.projX(lon) * scale, y: Italy.projY(lat) * scale)
                    Circle().fill((hot ? Holo.hsl(25, 95, 60) : Holo.hsl(217, 95, 62)).opacity(0.4))
                        .frame(width: 8 * scale, height: 8 * scale).position(pt)
                    Circle().fill(hot ? Holo.hsl(25, 95, 66) : Holo.hsl(217, 95, 72))
                        .frame(width: 3.6 * scale, height: 3.6 * scale).position(pt)
                    Circle().fill(.white).frame(width: 1.6 * scale, height: 1.6 * scale).position(pt)
                }
            }
        }
    }
}

// ─── Mappa MapKit con clustering nativo (sostituisce Leaflet) ───
struct HoloMapView: View {
    @ObservedObject var model: DettaglioModel
    @State private var leads: [Lead] = []
    @State private var loading = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ClusterMap(leads: leads)
                .frame(height: 520)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.32), lineWidth: 1))
            if loading {
                Text("Caricamento mappa…").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            legend
        }
        .task { await load() }
    }

    private func load() async {
        do { leads = try await HubAPI.listLeads(projectId: model.project.id, limit: 2000) } catch {}
        loading = false
    }

    private var legend: some View {
        let counts = model.statusCounts
        let total = counts.values.reduce(0, +)
        let inLav = total - (counts["da_contattare"] ?? 0) - (counts["chiuso_vinto"] ?? 0)
        return VStack(alignment: .leading, spacing: 6) {
            Text("LEGENDA · \(total) LEAD")
                .font(.system(size: 9, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Holo.labelDim)
            legendRow(Color(hex: 0x5b9dff), "Da contattare", counts["da_contattare"] ?? 0)
            legendRow(Holo.hsl(38, 92, 62), "In lavorazione", inLav)
            legendRow(Color(hex: 0x34d399), "Clienti", counts["chiuso_vinto"] ?? 0)
        }
        .padding(12)
        .background(Color(red: 8/255, green: 13/255, blue: 28/255).opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.3), lineWidth: 1))
        .padding(14)
    }

    private func legendRow(_ c: Color, _ label: String, _ n: Int) -> some View {
        HStack(spacing: 7) {
            Circle().fill(c).frame(width: 8, height: 8).shadow(color: c, radius: 3)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Holo.text)
            Spacer(minLength: 12)
            Text("\(n)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Holo.titleText)
        }
    }
}

private final class LeadAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c; super.init() }
}

/// MKMapView con clustering nativo (MKMarkerAnnotationView.clusteringIdentifier)
struct ClusterMap: NSViewRepresentable {
    let leads: [Lead]

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 42.4, longitude: 12.6),
            span: MKCoordinateSpan(latitudeDelta: 9.5, longitudeDelta: 9.5)), animated: false)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let existing = map.annotations.count - (map.annotations.first(where: { $0 is MKUserLocation }) != nil ? 1 : 0)
        let coords = leads.compactMap { l -> CLLocationCoordinate2D? in
            guard let lat = l.latitude, let lon = l.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard existing != coords.count else { return }
        map.removeAnnotations(map.annotations)
        map.addAnnotations(coords.map(LeadAnnotation.init))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let id = annotation is MKClusterAnnotation
                ? MKMapViewDefaultClusterAnnotationViewReuseIdentifier
                : MKMapViewDefaultAnnotationViewReuseIdentifier
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id, for: annotation) as! MKMarkerAnnotationView
            v.clusteringIdentifier = "lead"
            v.markerTintColor = NSColor(red: 0x5b/255, green: 0x9d/255, blue: 1, alpha: 1)
            v.glyphTintColor = .white
            v.displayPriority = .defaultLow
            return v
        }
    }
}
