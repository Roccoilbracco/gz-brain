import SwiftUI
import MapKit
import AppKit
import UniformTypeIdentifiers

// ============================================================================
// Registro Proprietà (immobili) + storico operazioni.
// Una proprietà può essere venduta/affittata/traspasata più volte nel tempo:
// ogni operazione è una riga in proprieta_storico (timeline).
// ============================================================================

// ── Modelli ──────────────────────────────────────────────────────────────────
struct Proprieta: Decodable, Identifiable {
    let id: String
    var title: String
    var reference: String?
    var address: String?
    var zone: String?
    var city: String?
    var category: String?
    var listing_type: String?
    var property_type: String?
    var bedrooms: Int?
    var bathrooms: Int?
    var size_sqm: Int?
    var price: Int?
    var status: String
    var photos: [String]?
    var latitude: Double?
    var longitude: Double?
    var notes: String?
    var site_visibility: [String: Bool]?
    let created_at: String?
    var proprieta_storico: [ProprietaStorico]?
}

struct ProprietaStorico: Decodable, Identifiable {
    let id: String
    var event_type: String?
    var event_date: String?
    var price: Int?
    var counterparty: String?
    var agent: String?
    var notes: String?
    let created_at: String?
}

enum PropertyStatus: String, CaseIterable, Identifiable {
    case disponibile, riservata, venduta, affittata, ritirata
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var hue: Double {
        switch self {
        case .disponibile: return 150
        case .riservata: return 45
        case .venduta: return 210
        case .affittata: return 190
        case .ritirata: return 5
        }
    }
    static func from(_ s: String?) -> PropertyStatus { PropertyStatus(rawValue: s ?? "") ?? .disponibile }
}

enum StoricoEvent: String, CaseIterable, Identifiable {
    case acquisizione, vendita, affitto, traspaso, variazione_prezzo, ritiro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .variazione_prezzo: return "Variazione prezzo"
        default: return rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .acquisizione: return "plus.circle.fill"
        case .vendita: return "eurosign.circle.fill"
        case .affitto: return "key.fill"
        case .traspaso: return "arrow.left.arrow.right.circle.fill"
        case .variazione_prezzo: return "tag.fill"
        case .ritiro: return "xmark.circle.fill"
        }
    }
    var hue: Double {
        switch self {
        case .acquisizione: return 190
        case .vendita: return 210
        case .affitto: return 150
        case .traspaso: return 280
        case .variazione_prezzo: return 45
        case .ritiro: return 5
        }
    }
    static func from(_ s: String?) -> StoricoEvent { StoricoEvent(rawValue: s ?? "") ?? .vendita }
}

// data ISO "yyyy-MM-dd" → "dd MMM yyyy"
private let ymdIn: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "it_IT"); return f }()
private let ymdOut: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd MMM yyyy"; f.locale = Locale(identifier: "it_IT"); return f }()
func prettyDate(_ s: String?) -> String {
    guard let s, let d = ymdIn.date(from: String(s.prefix(10))) else { return s ?? "—" }
    return ymdOut.string(from: d)
}

// ── API ──────────────────────────────────────────────────────────────────────
extension HubAPI {
    static func listProprieta() async throws -> [Proprieta] {
        try await sb.fetch("proprieta?select=*,proprieta_storico(id)&order=created_at.desc&limit=2000")
    }
    static func getProprieta(id: String) async throws -> Proprieta? {
        let rows: [Proprieta] = try await sb.fetch("proprieta?select=*,proprieta_storico(*)&id=eq.\(id)")
        return rows.first
    }
    @discardableResult
    static func createProprieta(_ fields: [String: Any?]) async throws -> Proprieta {
        try await sb.insertReturning("proprieta", body: fields)
    }
    static func updateProprieta(id: String, fields: [String: Any?]) async throws {
        var body = fields; body["updated_at"] = isoNowString()
        try await sb.mutate("proprieta?id=eq.\(id)", method: "PATCH", body: body)
    }
    static func deleteProprieta(id: String) async throws {
        try await sb.mutate("proprieta?id=eq.\(id)", method: "DELETE")
    }
    static func addStorico(_ fields: [String: Any?]) async throws {
        try await sb.mutate("proprieta_storico", method: "POST", body: fields)
    }
    static func deleteStorico(id: String) async throws {
        try await sb.mutate("proprieta_storico?id=eq.\(id)", method: "DELETE")
    }
    // foto: bucket 'proprieta'
    @discardableResult
    static func uploadProprietaPhoto(propId: String, data: Data, ext: String) async throws -> String {
        let name = "\(propId)/\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "jpg" : ext)"
        return try await sb.uploadFile(bucket: "proprieta", path: name, data: data, contentType: "image/\(ext == "png" ? "png" : "jpeg")")
    }
    static func downloadProprietaPhoto(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "proprieta", path: path)
    }
    // documenti (contratti, piantine, ecc.) nel bucket 'proprieta' sotto <propId>/docs/
    static func listProprietaDocumenti(_ propId: String) async throws -> [ProprietaDocumento] {
        try await sb.fetch("proprieta_documenti?select=*&proprieta_id=eq.\(propId)&order=created_at.desc")
    }
    static func addProprietaDocumento(propId: String, fileURL: URL, tipo: String) async throws {
        let bytes = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.isEmpty ? "pdf" : fileURL.pathExtension
        let ct = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let safe = fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let name = "\(propId)/docs/\(UUID().uuidString.prefix(8))-\(safe).\(ext)"
        let stored = try await sb.uploadFile(bucket: "proprieta", path: name, data: bytes, contentType: ct)
        try await sb.mutate("proprieta_documenti", method: "POST", body: [
            "proprieta_id": propId, "nome": fileURL.lastPathComponent, "path": stored, "tipo": tipo,
        ])
    }
    static func deleteProprietaDocumento(id: String, path: String?) async throws {
        try await sb.mutate("proprieta_documenti?id=eq.\(id)", method: "DELETE")
        if let p = path { try? await sb.deleteFile(bucket: "proprieta", path: p) }
    }
    static func downloadProprietaDoc(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "proprieta", path: path)
    }
}

struct ProprietaDocumento: Decodable, Identifiable {
    let id: String
    let nome: String
    let path: String
    let tipo: String?
    let created_at: String?
}

enum DocTipo: String, CaseIterable, Identifiable {
    case contratto, piantina, catasto, altro
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var hue: Double {
        switch self {
        case .contratto: return 210
        case .piantina: return 150
        case .catasto: return 45
        case .altro: return 280
        }
    }
    var icon: String {
        switch self {
        case .contratto: return "doc.text.fill"
        case .piantina: return "ruler.fill"
        case .catasto: return "map.fill"
        case .altro: return "paperclip"
        }
    }
    static func from(_ s: String?) -> DocTipo { DocTipo(rawValue: s ?? "") ?? .altro }
}

// ── Carosello immagini remoto (scorre 1 alla volta) ──────────────────────────
struct RemoteImageCarousel: View {
    let paths: [String]
    var height: CGFloat = 150
    var corner: CGFloat = 10
    @State private var images: [NSImage?] = []
    @State private var index = 0
    @State private var loaded = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(Color(hex: 0x0c1220))
            if !loaded {
                ProgressView().controlSize(.small)
            } else if let img = images.indices.contains(index) ? images[index] : nil {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(Csb.secFg.opacity(0.5))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(alignment: .center) { if paths.count > 1 { arrows } }
        .overlay(alignment: .bottom) { if paths.count > 1 { dots } }
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            if v.translation.width < -30 { step(1) } else if v.translation.width > 30 { step(-1) }
        })
        .task { await load() }
    }

    private var arrows: some View {
        HStack {
            navBtn("chevron.left") { step(-1) }
            Spacer()
            navBtn("chevron.right") { step(1) }
        }
        .padding(.horizontal, 6)
    }
    private func navBtn(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(.black.opacity(0.4)))
        }.buttonStyle(.plain)
    }
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(paths.indices, id: \.self) { i in
                Circle().fill(i == index ? Color.white : Color.white.opacity(0.4)).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.35)))
        .padding(.bottom, 8)
    }
    private func step(_ d: Int) {
        guard !paths.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.18)) { index = (index + d + paths.count) % paths.count }
    }
    private func load() async {
        guard !loaded else { return }
        var imgs: [NSImage?] = []
        for p in paths {
            if let data = try? await HubAPI.downloadProprietaPhoto(path: p) { imgs.append(NSImage(data: data)) }
            else { imgs.append(nil) }
        }
        images = imgs; loaded = true
    }
}

enum PropViewMode { case lista, griglia, mappa }

// ── Lista proprietà (tabella + griglia card + mappa) ─────────────────────────
struct ProprietaView: View {
    @State private var items: [Proprieta] = []
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var search = ""
    @State private var showAdd = false
    @State private var mode: PropViewMode = .lista

    private var filtered: [Proprieta] {
        items.filter { p in
            search.isEmpty || [p.title, p.reference, p.zone, p.city, p.address]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("PROPRIETÀ").font(.system(size: 19, weight: .heavy)).tracking(5)
                        .foregroundStyle(Holo.titleText)
                        .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                    Spacer()
                    viewToggle
                    HoloSearchField(placeholder: "Cerca immobile…", text: $search)
                    MenuPillButton(label: "Aggiungi proprietà", icon: "plus") { showAdd = true }
                }

                if let errorMsg {
                    GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.top, 8)
                } else if mode == .mappa {
                    PropertyMap(items: filtered)
                        .frame(height: 560)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Holo.cardBorder, lineWidth: 1))
                } else if filtered.isEmpty {
                    EmptyStateCard(icon: "house", text: search.isEmpty
                        ? "Nessuna proprietà.\nAggiungine una con “+ Aggiungi proprietà”."
                        : "Nessuna proprietà trovata.")
                } else if mode == .lista {
                    PropertyTable(items: filtered)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { p in PropertyCard(p: p) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 54, leading: 30, bottom: 34, trailing: 30))
        }
        .task { await load() }
        .sheet(isPresented: $showAdd) { ProprietaFormView(existing: nil) { await load() } }
    }

    private var viewToggle: some View {
        HStack(spacing: 3) {
            toggleBtn("Lista", "list.bullet", on: mode == .lista) { mode = .lista }
            toggleBtn("Griglia", "square.grid.2x2", on: mode == .griglia) { mode = .griglia }
            toggleBtn("Mappa", "map", on: mode == .mappa) { mode = .mappa }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Csb.tabsBg))
    }
    private func toggleBtn(_ label: String, _ icon: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? Csb.itemFgOn : Color(hex: 0x9b988f))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Csb.tabOn : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Csb.tabOnBorder : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { items = try await HubAPI.listProprieta() }
        catch let e { errorMsg = e.localizedDescription }
    }
}

// operazione: label + tinta (coerente col pannello leads: vendita ambra, affitto blu, traspaso viola)
func operationInfo(_ s: String?) -> (label: String, hue: Double)? {
    switch s {
    case "vendita": return ("Vendita", 30)
    case "affitto": return ("Affitto", 210)
    case "traspaso": return ("Traspaso", 280)
    default: return nil
    }
}

private struct PropertyCard: View {
    let p: Proprieta
    @State private var hover = false
    private var st: PropertyStatus { .from(p.status) }
    private var storicoCount: Int { p.proprieta_storico?.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if let ph = p.photos, !ph.isEmpty {
                RemoteImageCarousel(paths: ph, height: 150, corner: 0)
            }
            Button { AppState.shared.route = .proprieta(id: p.id) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Holo.titleText).lineLimit(1)
                            if let r = p.reference, !r.isEmpty {
                                Text("Rif. \(r)").font(.system(size: 10)).foregroundStyle(Csb.tagFg)
                            }
                        }
                        Spacer(minLength: 4)
                        statusBadge
                    }
                    if [p.zone, p.city].compactMap({ $0 }).first != nil {
                        HStack(spacing: 5) {
                            Image(systemName: "mappin.circle.fill").font(.system(size: 10)).foregroundStyle(Csb.secFg)
                            Text([p.zone, p.city].compactMap { $0 }.joined(separator: ", ")).font(.system(size: 11))
                                .foregroundStyle(Holo.subDim).lineLimit(1)
                        }
                    }
                    Text([p.category?.capitalized, p.property_type,
                          p.size_sqm.map { "\($0) m²" }, p.bedrooms.map { "\($0) cam" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
                    HStack(spacing: 8) {
                        if let op = operationInfo(p.listing_type) {
                            Text(op.label.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
                                .foregroundStyle(Holo.hsl(op.hue, 85, 74))
                                .padding(.horizontal, 7).padding(.vertical, 2.5)
                                .background(Capsule().fill(Holo.hsl(op.hue, 70, 45).opacity(0.18)))
                        }
                        if let pr = p.price { Text(LeadFmt.euro(pr)).font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Holo.hsl(150, 70, 68)) }
                        Spacer()
                        if storicoCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: 9))
                                Text("\(storicoCount)").font(.system(size: 10, weight: .bold))
                            }.foregroundStyle(Csb.avatar)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover ? Color.white.opacity(0.05) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0x121a2c).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(st.hue == 0 ? Color.white.opacity(0.08) : Holo.hsl(st.hue, 60, 55).opacity(0.28), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var statusBadge: some View {
        Text(st.label.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
            .foregroundStyle(Holo.hsl(st.hue, 85, 75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Holo.hsl(st.hue, 80, 60).opacity(0.5), lineWidth: 1))
    }
}

// ── Vista tabella (stile listado): righe compatte e ordinate ─────────────────
private struct PropertyTable: View {
    let items: [Proprieta]

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, p in
                PropertyRow(p: p, alt: idx % 2 == 1)
            }
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0x0e1626).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Holo.cardBorder.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var header: some View {
        HStack(spacing: 10) {
            cell("RIF.", 90, .leading)
            cell("OPERAZIONE", 104, .leading)
            cell("INDIRIZZO", nil, .leading)
            cell("PREZZO", 120, .trailing)
            cell("CAM", 44, .center)
            cell("M²", 56, .center)
            cell("STATO", 104, .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(Rectangle().fill(Holo.cardBorder.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }
    private func cell(_ t: String, _ w: CGFloat?, _ align: Alignment) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Holo.labelDim)
            .frame(width: w, alignment: align).frame(maxWidth: w == nil ? .infinity : nil, alignment: align)
    }
}

private struct PropertyRow: View {
    let p: Proprieta
    let alt: Bool
    @State private var hover = false
    private var st: PropertyStatus { .from(p.status) }

    var body: some View {
        Button { AppState.shared.route = .proprieta(id: p.id) } label: {
            HStack(spacing: 10) {
                // Rif.
                Text(p.reference ?? "—").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Holo.subDim).frame(width: 90, alignment: .leading).lineLimit(1)
                // Operazione + tipo
                VStack(alignment: .leading, spacing: 2) {
                    if let op = operationInfo(p.listing_type) {
                        Text(op.label).font(.system(size: 9.5, weight: .heavy)).tracking(0.4)
                            .foregroundStyle(Holo.hsl(op.hue, 85, 74))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Holo.hsl(op.hue, 70, 45).opacity(0.18)))
                    }
                    if let t = p.property_type { Text(t).font(.system(size: 9.5)).foregroundStyle(Holo.labelDim).lineLimit(1) }
                }
                .frame(width: 104, alignment: .leading)
                // Indirizzo
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Holo.titleText).lineLimit(1)
                    let loc = [p.zone, p.city].compactMap { $0 }.joined(separator: " · ")
                    if !loc.isEmpty { Text(loc).font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Prezzo
                Text(p.price.map { LeadFmt.euro($0) } ?? "—")
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Holo.hsl(150, 70, 68))
                    .frame(width: 120, alignment: .trailing).lineLimit(1)
                // Camere
                Text(p.bedrooms.map(String.init) ?? "—").font(.system(size: 12))
                    .foregroundStyle(Holo.subDim).frame(width: 44, alignment: .center)
                // m²
                Text(p.size_sqm.map { "\($0)" } ?? "—").font(.system(size: 12))
                    .foregroundStyle(Holo.subDim).frame(width: 56, alignment: .center)
                // Stato
                Text(st.label).font(.system(size: 9.5, weight: .heavy)).tracking(0.4)
                    .foregroundStyle(Holo.hsl(st.hue, 85, 75))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Holo.hsl(st.hue, 80, 60).opacity(0.5), lineWidth: 1))
                    .frame(width: 104, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(hover ? Color.white.opacity(0.06) : (alt ? Color.white.opacity(0.015) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// ── Scheda proprietà: info + timeline storico ────────────────────────────────
struct ProprietaDetailView: View {
    let proprietaId: String
    @State private var p: Proprieta?
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var showEdit = false
    @State private var showAddEvent = false
    @State private var confirmDelete = false

    private var st: PropertyStatus { .from(p?.status) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Button { AppState.shared.route = .proprietaHub } label: {
                    Text("← PROPRIETÀ").font(.system(size: 11)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
                }.buttonStyle(.plain)

                if let errorMsg {
                    GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if let p {
                    anagrafica(p)
                    if let ph = p.photos, !ph.isEmpty {
                        RemoteImageCarousel(paths: ph, height: 300, corner: 16)
                    }
                    storicoSection(p)
                    ProprietaDocumentiSection(proprietaId: proprietaId)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task(id: proprietaId) { await load() }
        .sheet(isPresented: $showEdit) {
            if let p { ProprietaFormView(existing: p) { await load() } }
        }
        .sheet(isPresented: $showAddEvent) {
            StoricoFormView(proprietaId: proprietaId) { await load() }
        }
    }

    private func anagrafica(_ p: Proprieta) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "house.fill").font(.system(size: 20)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(
                        colors: [Holo.hsl(st.hue, 55, 42), Holo.hsl(st.hue, 60, 28)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Holo.hsl(st.hue, 60, 55).opacity(0.45), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(.system(size: 18, weight: .heavy)).foregroundStyle(Holo.titleText).lineLimit(1)
                    if let r = p.reference, !r.isEmpty {
                        Text("Rif. \(r)").font(.system(size: 11, weight: .medium)).foregroundStyle(Csb.tagFg)
                    }
                }
                Spacer(minLength: 12)
                StatusChip(text: st.label, hue: st.hue)
                Menu {
                    Button { showEdit = true } label: { Label("Modifica", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Csb.itemFg)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabsBg))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            divider
            defRow("INDIRIZZO", [p.address, p.zone, p.city].compactMap { $0 }.joined(separator: ", ").ifEmpty("—"))
            divider
            defRow("TIPOLOGIA", [p.category?.capitalized, p.property_type].compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
            divider
            defRow("OPERAZIONE", operationInfo(p.listing_type)?.label ?? "—")
            divider
            defRow("DETTAGLI", [p.size_sqm.map { "\($0) m²" }, p.bedrooms.map { "\($0) camere" }, p.bathrooms.map { "\($0) bagni" }]
                .compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
            divider
            defRow("PREZZO ATTUALE", p.price.map { LeadFmt.euro($0) } ?? "—")
            if let n = p.notes, !n.isEmpty { divider; defRow("NOTE", n) }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Csb.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Csb.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .confirmationDialog("Eliminare la proprietà e tutto il suo storico?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { delete() }
            Button("Annulla", role: .cancel) {}
        }
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    private func defRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2)
                .foregroundStyle(Csb.secFg).frame(width: 130, alignment: .leading).padding(.top, 1)
            Text(value).font(.system(size: 13)).foregroundStyle(Holo.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18))
    }

    // timeline storico
    private func storicoSection(_ p: Proprieta) -> some View {
        let eventi = (p.proprieta_storico ?? []).sorted {
            ($0.event_date ?? "") > ($1.event_date ?? "")
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("STORICO OPERAZIONI").font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(210, 60, 66))
                Spacer()
                MenuPillButton(label: "Aggiungi evento", icon: "plus") { showAddEvent = true }
            }
            if eventi.isEmpty {
                EmptyStateCard(icon: "clock.arrow.circlepath",
                    text: "Nessuna operazione registrata.\nAggiungi acquisizione, vendita, affitto o traspaso.")
            } else {
                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(eventi.enumerated()), id: \.element.id) { i, ev in
                            storicoRow(ev)
                            if i < eventi.count - 1 {
                                Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 68)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func storicoRow(_ ev: ProprietaStorico) -> some View {
        let e = StoricoEvent.from(ev.event_type)
        return HStack(alignment: .center, spacing: 14) {
            // pastiglia icona colorata (evento)
            Image(systemName: e.icon).font(.system(size: 16))
                .foregroundStyle(Holo.hsl(e.hue, 88, 70))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Holo.hsl(e.hue, 70, 45).opacity(0.16)))
                .overlay(Circle().strokeBorder(Holo.hsl(e.hue, 70, 55).opacity(0.35), lineWidth: 1))

            // corpo: tipo + data, controparte/agente, note
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(e.label).font(.system(size: 13.5, weight: .bold)).foregroundStyle(Holo.hsl(e.hue, 82, 76))
                    Text(prettyDate(ev.event_date)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Csb.secFg)
                        .padding(.horizontal, 7).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                }
                if ev.counterparty != nil || ev.agent != nil {
                    Text([ev.counterparty, ev.agent.map { "Agente: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(Holo.subDim).lineLimit(1)
                }
                if let n = ev.notes, !n.isEmpty {
                    Text(n).font(.system(size: 11)).foregroundStyle(Holo.labelDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            // colonna destra: prezzo + elimina
            if let pr = ev.price {
                Text(LeadFmt.euro(pr)).font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Holo.titleText).monospacedDigit()
            }
            IconButton(icon: "trash", help: "Elimina", danger: true) {
                Task { try? await HubAPI.deleteStorico(id: ev.id); await load() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { p = try await HubAPI.getProprieta(id: proprietaId) }
        catch let e { errorMsg = e.localizedDescription }
    }
    private func delete() {
        Task {
            do { try await HubAPI.deleteProprieta(id: proprietaId)
                await MainActor.run { AppState.shared.route = .proprietaHub }
            } catch let e { await MainActor.run { errorMsg = "Eliminazione fallita: \(e.localizedDescription)" } }
        }
    }
}

private extension String { func ifEmpty(_ f: String) -> String { isEmpty ? f : self } }

// ── Form proprietà (nuova / modifica) ────────────────────────────────────────
struct ProprietaFormView: View {
    let existing: Proprieta?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""; @State private var reference = ""
    @State private var address = ""; @State private var zone = ""; @State private var city = ""
    @State private var category = ""; @State private var listingType = ""; @State private var propertyType = ""
    @State private var bedrooms = ""; @State private var bathrooms = ""; @State private var sqm = ""
    @State private var price = ""; @State private var status = PropertyStatus.disponibile
    @State private var notes = ""; @State private var saving = false
    @State private var newPhotos: [URL] = []
    // Visibilità sui siti: slug progetto → visibile. Key presente = associata al progetto.
    @State private var projects: [Project] = []
    @State private var visibility: [String: Bool] = [:]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "NUOVA PROPRIETÀ" : "MODIFICA PROPRIETÀ")
                    .font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HoloField(label: "Titolo *", text: $title, placeholder: "Es. Villa vista mare Es Cubells")
                HoloField(label: "Riferimento", text: $reference, placeholder: "Es. GZ-0012")
                HoloField(label: "Indirizzo", text: $address, placeholder: "Es. Carrer de …")
                HStack(spacing: 12) { HoloField(label: "Zona", text: $zone); HoloField(label: "Città", text: $city) }
                holoPicker("Operazione", [("", "—")] + LeadInterest.allCases.map { ($0.rawValue, $0.label) }, listingType) { listingType = $0 }
                HStack(spacing: 12) {
                    holoPicker("Categoria", [("", "—")] + LeadCategory.allCases.map { ($0.rawValue, $0.label) }, category) { category = $0 }
                    holoPicker("Tipo immobile", [("", "—")] + propertyTypes.map { ($0, $0) }, propertyType) { propertyType = $0 }
                }
                HStack(spacing: 12) {
                    HoloField(label: "Camere", text: $bedrooms, placeholder: "3")
                    HoloField(label: "Bagni", text: $bathrooms, placeholder: "2")
                    HoloField(label: "Superficie m²", text: $sqm, placeholder: "180")
                }
                HStack(spacing: 12) {
                    HoloField(label: "Prezzo €", text: $price, placeholder: "1200000")
                    holoPicker("Stato", PropertyStatus.allCases.map { ($0.rawValue, $0.label) }, status.rawValue) { status = .from($0) }
                }
                HoloField(label: "Note", text: $notes)
                visibilitaSiti
                photoStaging

                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : "Salva proprietà").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain)
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 720)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .onAppear(perform: prefill)
        .task { projects = (try? await HubAPI.listProjects()) ?? [] }
    }

    private var photoStaging: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FOTO").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                Spacer()
                Button { pickPhotos() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 10, weight: .bold))
                        Text("Aggiungi foto").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0xeaf0fb))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 40/255, green: 70/255, blue: 140/255).opacity(0.5)))
                    .overlay(Capsule().strokeBorder(Holo.hsl(217, 85, 62).opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            let existingCount = existing?.photos?.count ?? 0
            if newPhotos.isEmpty && existingCount == 0 {
                Text("Aggiungi foto dell'immobile (JPG, PNG).").font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
            } else {
                Text("\(existingCount) già caricate · \(newPhotos.count) nuove da caricare")
                    .font(.system(size: 10.5)).foregroundStyle(Holo.subDim)
            }
        }
    }
    // ── Visibilità sui siti: associa la proprietà a uno o più progetti e
    //    scegli se pubblicarla sul relativo sito ──
    private var visibilitaSiti: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VISIBILITÀ SUI SITI").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
            Text("Seleziona i progetti in cui mostrare la proprietà e attiva «Rendi visibile» per pubblicarla sul relativo sito.")
                .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
            if projects.isEmpty {
                Text("Caricamento progetti…").font(.system(size: 11)).foregroundStyle(Holo.subDim)
            } else {
                VStack(spacing: 6) { ForEach(projects) { siteRow($0) } }
            }
        }
    }

    private func siteRow(_ p: Project) -> some View {
        let associated = visibility[p.slug] != nil
        let visible = visibility[p.slug] == true
        return HStack(spacing: 10) {
            Button {
                if associated { visibility[p.slug] = nil } else { visibility[p.slug] = false }
            } label: {
                Image(systemName: associated ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(associated ? Holo.hsl(217, 85, 64) : Csb.secFg)
            }.buttonStyle(.plain)

            Text(p.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Holo.text)
            Spacer(minLength: 0)

            Button {
                guard associated else { return }
                visibility[p.slug] = !visible
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: visible ? "eye.fill" : "eye.slash").font(.system(size: 10))
                    Text(visible ? "Visibile sul sito" : "Rendi visibile").font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(visible ? Holo.hsl(145, 72, 60) : Csb.secFg)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(visible ? Holo.hsl(145, 60, 45).opacity(0.18) : Color.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(visible ? Holo.hsl(145, 60, 55).opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
                .opacity(associated ? 1 : 0.35)
            }.buttonStyle(.plain).disabled(!associated)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(associated ? Color.white.opacity(0.05) : Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func pickPhotos() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.jpeg, .png, .image]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        if p.runModal() == .OK { newPhotos.append(contentsOf: p.urls.filter { !newPhotos.contains($0) }) }
    }

    private func prefill() {
        guard let e = existing else { return }
        title = e.title; reference = e.reference ?? ""; address = e.address ?? ""
        zone = e.zone ?? ""; city = e.city ?? ""; category = e.category ?? ""
        listingType = e.listing_type ?? ""; propertyType = e.property_type ?? ""
        bedrooms = e.bedrooms.map(String.init) ?? ""; bathrooms = e.bathrooms.map(String.init) ?? ""
        sqm = e.size_sqm.map(String.init) ?? ""; price = e.price.map(String.init) ?? ""
        status = .from(e.status); notes = e.notes ?? ""
        visibility = e.site_visibility ?? [:]
    }
    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let body: [String: Any?] = [
            "title": title.trimmingCharacters(in: .whitespaces), "reference": s(reference),
            "address": s(address), "zone": s(zone), "city": s(city),
            "category": s(category), "listing_type": s(listingType), "property_type": s(propertyType),
            "bedrooms": Int(bedrooms), "bathrooms": Int(bathrooms), "size_sqm": Int(sqm),
            "price": Int(price), "status": status.rawValue, "notes": s(notes),
            "site_visibility": visibility,
        ]
        do {
            let propId: String
            if let e = existing { try await HubAPI.updateProprieta(id: e.id, fields: body); propId = e.id }
            else { propId = try await HubAPI.createProprieta(body).id }
            if !newPhotos.isEmpty {
                var paths = existing?.photos ?? []
                for url in newPhotos {
                    if let data = try? Data(contentsOf: url) {
                        let p = try await HubAPI.uploadProprietaPhoto(propId: propId, data: data, ext: url.pathExtension.lowercased())
                        paths.append(p)
                    }
                }
                try await HubAPI.updateProprieta(id: propId, fields: ["photos": paths])
            }
            await onSaved(); dismiss()
        } catch { saving = false }
    }
}

// ── Form evento storico ───────────────────────────────────────────────────────
struct StoricoFormView: View {
    let proprietaId: String
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var event = StoricoEvent.vendita
    @State private var date = Date()
    @State private var price = ""; @State private var counterparty = ""; @State private var agent = ""; @State private var notes = ""
    @State private var saving = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("NUOVO EVENTO").font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HStack(spacing: 12) {
                    holoPicker("Tipo operazione", StoricoEvent.allCases.map { ($0.rawValue, $0.label) }, event.rawValue) { event = .from($0) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DATA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact).colorScheme(.dark)
                    }.frame(width: 150)
                }
                HoloField(label: "Prezzo €", text: $price, placeholder: "Es. 1350000")
                HStack(spacing: 12) {
                    HoloField(label: "Controparte", text: $counterparty, placeholder: "Acquirente / inquilino")
                    HoloField(label: "Agente", text: $agent, placeholder: "Giorgio")
                }
                HoloField(label: "Note", text: $notes)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : "Salva evento").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain).disabled(saving)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 470)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let body: [String: Any?] = [
            "proprieta_id": proprietaId, "event_type": event.rawValue, "event_date": f.string(from: date),
            "price": Int(price), "counterparty": s(counterparty), "agent": s(agent), "notes": s(notes),
        ]
        do { try await HubAPI.addStorico(body); await onSaved(); dismiss() }
        catch { saving = false }
    }
}

// ── Sezione documenti della proprietà (contratti, piantine, ecc.) ────────────
struct ProprietaDocumentiSection: View {
    let proprietaId: String
    @State private var docs: [ProprietaDocumento] = []
    @State private var loading = true
    @State private var busy = false
    @State private var msg: String?
    @State private var filter: DocTipo? = nil

    private var shown: [ProprietaDocumento] {
        guard let f = filter else { return docs }
        return docs.filter { DocTipo.from($0.tipo) == f }
    }
    private func count(_ t: DocTipo) -> Int { docs.filter { DocTipo.from($0.tipo) == t }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DOCUMENTI").font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(210, 60, 66))
                Spacer()
                Menu {
                    ForEach(DocTipo.allCases) { t in
                        Button { pick(tipo: t) } label: { Label("Carica \(t.label)", systemImage: t.icon) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").font(.system(size: 10, weight: .bold))
                        Text("Carica").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Csb.itemFgOn)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabOn.opacity(0.9)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(busy).opacity(busy ? 0.5 : 1)
            }
            if let msg { Text(msg).font(.system(size: 11)).foregroundStyle(Holo.subDim) }
            if loading {
                Text("Caricamento…").font(.system(size: 12)).foregroundStyle(Holo.subDim).padding(.vertical, 6)
            } else if docs.isEmpty {
                EmptyStateCard(icon: "doc.text", text: "Nessun documento.\nCarica contratti, piantine, visure catastali con “Carica”.")
            } else {
                // filtri per tipo
                HStack(spacing: 7) {
                    filterChip(nil, "Tutti", docs.count)
                    ForEach(DocTipo.allCases) { t in
                        if count(t) > 0 { filterChip(t, t.label, count(t)) }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, d in
                        row(d)
                        if i < shown.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                    }
                }
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .task(id: proprietaId) { await load() }
    }

    private func filterChip(_ t: DocTipo?, _ label: String, _ n: Int) -> some View {
        let on = filter == t
        let c = t?.hue ?? 210
        return Button { withAnimation(.easeOut(duration: 0.15)) { filter = t } } label: {
            Text("\(label) \(n)").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? Color(hex: 0x0b1220) : Holo.hsl(c, 60, 72))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(on ? Holo.hsl(c, 75, 62) : Holo.hsl(c, 60, 45).opacity(0.15)))
                .overlay(Capsule().strokeBorder(Holo.hsl(c, 70, 55).opacity(on ? 0 : 0.4), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func row(_ d: ProprietaDocumento) -> some View {
        let t = DocTipo.from(d.tipo)
        return HStack(spacing: 12) {
            Image(systemName: t.icon).font(.system(size: 13)).foregroundStyle(Holo.hsl(t.hue, 75, 70))
            Text(d.nome).font(.system(size: 12.5)).foregroundStyle(Holo.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(t.label.uppercased()).font(.system(size: 8, weight: .heavy)).tracking(0.5)
                .foregroundStyle(Holo.hsl(t.hue, 80, 74))
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(Holo.hsl(t.hue, 70, 45).opacity(0.18)))
            IconButton(icon: "arrow.up.right.square", help: "Apri") { Task { await apri(d) } }
            IconButton(icon: "trash", help: "Elimina", danger: true) { Task { await elimina(d) } }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { docs = try await HubAPI.listProprietaDocumenti(proprietaId) }
        catch let e { msg = "Errore: \(e.localizedDescription)" }
    }
    private func apri(_ d: ProprietaDocumento) async {
        guard let data = try? await HubAPI.downloadProprietaDoc(path: d.path) else { msg = "Documento non disponibile."; return }
        let ext = (d.path as NSString).pathExtension
        let base = (d.nome as NSString).deletingPathExtension
        let url = appTempDir().appendingPathComponent(base.isEmpty ? "documento" : base)
            .appendingPathExtension(ext.isEmpty ? "pdf" : ext)
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }
    private func elimina(_ d: ProprietaDocumento) async {
        busy = true; defer { busy = false }
        do { try await HubAPI.deleteProprietaDocumento(id: d.id, path: d.path); await load() }
        catch let e { msg = "Errore eliminazione: \(e.localizedDescription)" }
    }
    private func pick(tipo: DocTipo) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .png, .jpeg, .image, .data]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let urls = p.urls
        Task {
            busy = true; defer { busy = false }
            do {
                for url in urls { try await HubAPI.addProprietaDocumento(propId: proprietaId, fileURL: url, tipo: tipo.rawValue) }
                await load()
            } catch let e { msg = "Errore caricamento: \(e.localizedDescription)" }
        }
    }
}

// ── Mappa Ibiza con pin proprietà (MapKit) ───────────────────────────────────
final class PropAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let propId: String
    init(propId: String, coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?) {
        self.propId = propId; self.coordinate = coordinate; self.title = title; self.subtitle = subtitle
    }
}

struct PropertyMap: NSViewRepresentable {
    let items: [Proprieta]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.appearance = NSAppearance(named: .darkAqua)
        mv.showsZoomControls = true
        mv.showsCompass = true
        // Ibiza
        mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 38.98, longitude: 1.43),
                                        span: MKCoordinateSpan(latitudeDelta: 0.42, longitudeDelta: 0.42)), animated: false)
        return mv
    }

    func updateNSView(_ mv: MKMapView, context: Context) {
        mv.removeAnnotations(mv.annotations)
        let anns: [PropAnnotation] = items.compactMap { p in
            guard let la = p.latitude, let lo = p.longitude else { return nil }
            return PropAnnotation(propId: p.id,
                                  coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo),
                                  title: p.title, subtitle: p.price.map { LeadFmt.euro($0) })
        }
        mv.addAnnotations(anns)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is PropAnnotation else { return nil }
            let id = "prop"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.annotation = annotation
            v.canShowCallout = true
            v.markerTintColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
            v.glyphImage = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)
            let btn = NSButton(title: "Apri", target: self, action: #selector(openProp(_:)))
            btn.bezelStyle = .rounded
            v.rightCalloutAccessoryView = btn
            return v
        }
        @objc private func openProp(_ sender: NSButton) { /* callout button, navigazione via mapView(_:annotationView:) */ }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: NSControl) {
            if let a = view.annotation as? PropAnnotation {
                AppState.shared.route = .proprieta(id: a.propId)
            }
        }
    }
}

// picker in stile HoloField (menu a tendina scuro, box a larghezza piena)
private func holoPicker(_ label: String, _ opts: [(String, String)], _ sel: String, _ set: @escaping (String) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
        Menu {
            ForEach(opts, id: \.0) { o in Button(o.1) { set(o.0) } }
        } label: {
            HStack(spacing: 8) {
                Text(opts.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xe8f2ff)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Holo.labelDim)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
    .frame(maxWidth: .infinity)
}
