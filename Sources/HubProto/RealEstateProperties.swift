import SwiftUI
import MapKit
import CoreLocation
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
    var price_rent: Int?   // affitto mensile (per i traspaso: costo traspaso in price + affitto qui)
    var status: String
    var photos: [String]?
    /// Video dell'immobile, stesso bucket pubblico delle foto sotto <id>/video/.
    var videos: [String]?
    var latitude: Double?
    var longitude: Double?
    var notes: String?
    /// Progetto proprietario dell'immobile: gz-ibiza, wallis-57. Non cambia
    /// nel tempo — è di chi è, non dove appare.
    var project_slug: String?
    /// Online sul sito del proprio progetto. Prima era `site_visibility`
    /// {slug: bool}, che confondeva "di chi è" con "dove si vede".
    var pubblicata: Bool?
    /// Il proprietario in pipeline (re_owners) a cui appartiene. Distinto da
    /// `proprieta_proprietari`, che è la catena storica: questo è chi firma
    /// l'encargo oggi, e serve al generatore di documenti per non chiedere
    /// quale immobile quando ne ha uno solo.
    var owner_id: String?
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
    case acquisizione, vendita, affitto, traspaso, variazione_prezzo, rescissione, devoluzione, ritiro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .variazione_prezzo: return "Variazione prezzo"
        case .rescissione: return "Rescissione contratto"
        case .devoluzione: return "Devoluzione a proprietari"
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
        case .rescissione: return "doc.badge.ellipsis"
        case .devoluzione: return "arrow.uturn.backward.circle.fill"
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
        case .rescissione: return 25
        case .devoluzione: return 5
        case .ritiro: return 5
        }
    }
    /// Questi eventi tolgono l'immobile dal mercato: registrandoli, lo stato
    /// passa a «ritirata» così la griglia lo mostra subito come non disponibile.
    var ritiraImmobile: Bool {
        switch self { case .rescissione, .devoluzione, .ritiro: return true; default: return false }
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
    /// `slug` nil = tutti i progetti (vista di sistema nella sidebar); valorizzato
    /// = solo gli immobili di quell'agenzia, come li vede la sua dash.
    static func listProprieta(slug: String? = nil) async throws -> [Proprieta] {
        var query = "proprieta?select=*,proprieta_storico(id)&order=created_at.desc&limit=2000"
        if let slug { query += "&project_slug=eq.\(slug)" }
        return try await sb.fetch(query)
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
    static func deleteProprietaPhotoFile(path: String) async throws {
        try await sb.deleteFile(bucket: "proprieta", path: path)
    }
    // video: stesso bucket delle foto, in una sottocartella per non mescolarli
    @discardableResult
    static func uploadProprietaVideo(propId: String, data: Data, ext: String) async throws -> String {
        let e = ext.isEmpty ? "mp4" : ext
        let name = "\(propId)/video/\(UUID().uuidString.prefix(8)).\(e)"
        let tipo: String
        switch e {
        case "mov", "qt": tipo = "video/quicktime"
        case "m4v": tipo = "video/x-m4v"
        case "webm": tipo = "video/webm"
        default: tipo = "video/mp4"
        }
        return try await sb.uploadFile(bucket: "proprieta", path: name, data: data, contentType: tipo)
    }
    static func deleteProprietaVideoFile(path: String) async throws {
        try await sb.deleteFile(bucket: "proprieta", path: path)
    }
    /// I video non si scaricano interi per guardarli: il bucket è pubblico e
    /// AVPlayer se li riproduce in streaming da qui.
    static func urlVideoProprieta(path: String) -> URL? {
        SupabaseClient.shared?.publicURL(bucket: "proprieta", path: path)
    }
    static func downloadProprietaPhoto(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "proprieta", path: path)
    }
    /// Bucket PRIVATO dei documenti (contratti, piantine, visure), sotto <propId>/docs/.
    ///
    /// Separato da `proprieta`, che è pubblico perché i siti ne servono le foto
    /// senza chiave: un contratto messo lì sarebbe scaricabile da chiunque ne
    /// indovinasse l'URL. Qui si entra solo da loggati — staff sempre, il
    /// proprietario solo sui documenti marcati `visibile_proprietario` delle
    /// sue proprietà (policy `docs owner read` su storage.objects).
    static let bucketDocumenti = "proprieta-docs"

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
        let stored = try await sb.uploadFile(bucket: bucketDocumenti, path: name, data: bytes, contentType: ct)
        try await sb.mutate("proprieta_documenti", method: "POST", body: [
            "proprieta_id": propId, "nome": fileURL.lastPathComponent, "path": stored, "tipo": tipo,
        ])
    }
    static func deleteProprietaDocumento(id: String, path: String?) async throws {
        try await sb.mutate("proprieta_documenti?id=eq.\(id)", method: "DELETE")
        if let p = path { try? await sb.deleteFile(bucket: bucketDocumenti, path: p) }
    }
    static func downloadProprietaDoc(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: bucketDocumenti, path: path)
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

/// Filtro per disponibilità dell'immobile.
enum DispFilter: String, CaseIterable, Identifiable {
    case tutte, disponibili, ritirate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tutte: return "Tutte"
        case .disponibili: return "Disponibili"
        case .ritirate: return "Non disponibili"
        }
    }
    var hue: Double? {
        switch self {
        case .tutte: return nil
        case .disponibili: return 150   // verde
        case .ritirate: return 5        // rosso
        }
    }
}

// ── Lista proprietà (tabella + griglia card + mappa) ─────────────────────────
struct ProprietaView: View {
    /// Incorporata dentro un'altra pagina (la dash GZ Ibiza): niente ScrollView
    /// proprio — sarebbe annidato in quello del progetto — e niente titolo, che
    /// la pagina ospite ha già il suo.
    let embedded: Bool
    /// Progetto di cui mostrare gli immobili. nil = tutti, per la voce
    /// «Proprietà» della sidebar che sta sopra ai progetti.
    let slug: String?
    /// Vedi CalendarioVisiteView.init: il memberwise sarebbe privato.
    init(embedded: Bool = false, slug: String? = nil) {
        self.embedded = embedded
        self.slug = slug
    }
    @State private var items: [Proprieta] = []
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var search = ""
    @State private var mode: PropViewMode = .lista
    @State private var geocoding = false
    @State private var geocodeLeft = 0
    // "tutte" | "disponibili" | "ritirate": la disponibilità dell'immobile
    @State private var dispFilter: DispFilter = .tutte
    // nil = tutte le operazioni; altrimenti venta/alquiler/traspaso
    @State private var opFilter: String?

    /// Un immobile è "disponibile" se non è stato tolto dal mercato. Riservata e
    /// affittata contano ancora come attivi; venduta e ritirata no.
    private func isDisponibile(_ p: Proprieta) -> Bool {
        !["venduta", "ritirata"].contains(p.status)
    }
    private var filtered: [Proprieta] {
        let base = items.filter { p in
            let okSearch = search.isEmpty || [p.title, p.reference, p.zone, p.city, p.address]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
            let okDisp: Bool = {
                switch dispFilter {
                case .tutte: return true
                case .disponibili: return isDisponibile(p)
                case .ritirate: return !isDisponibile(p)
                }
            }()
            let okOp = opFilter == nil || p.listing_type == opFilter
            return okSearch && okDisp && okOp
        }
        // Prima le disponibili, poi le non disponibili; dentro ogni gruppo per
        // riferimento, così l'ordine è stabile e non salta a ogni ricarica.
        return base.sorted { a, b in
            let da = isDisponibile(a), db = isDisponibile(b)
            if da != db { return da }
            return (a.reference ?? "") < (b.reference ?? "")
        }
    }

    var body: some View {
        ContenitoreScorrevole(scorre: !embedded) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    if !embedded {
                        Text("PROPRIETÀ").font(.system(size: 19, weight: .heavy)).tracking(5)
                            .foregroundStyle(Holo.titleText)
                            .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                    }
                    Spacer()
                    viewToggle
                    HoloSearchField(placeholder: "Cerca immobile…", text: $search)
                    MenuPillButton(label: "Aggiungi proprietà", icon: "plus") {
                        AppState.shared.route = .proprietaNuova(slug: slug ?? "gz-ibiza")
                    }
                }

                // I filtri non hanno senso sulla mappa (che mostra solo i pin)
                if mode != .mappa && errorMsg == nil && !loading { filtriBar }

                if let errorMsg {
                    GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.top, 8)
                } else if mode == .mappa {
                    mapLegend
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
        .task(id: slug) { await load(); await geocodeMissing() }
    }

    // quante proprietà hanno un pin e quante restano da localizzare
    private var mapLegend: some View {
        let senza = filtered.filter { $0.latitude == nil || $0.longitude == nil }
        return HStack(spacing: 10) {
            Text("\(filtered.count - senza.count) di \(filtered.count) sulla mappa")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Holo.subDim)
            if !senza.isEmpty {
                Text("\(senza.count) senza posizione")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Holo.hsl(45, 80, 70))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Holo.hsl(45, 70, 45).opacity(0.16)))
                    .overlay(Capsule().strokeBorder(Holo.hsl(45, 70, 55).opacity(0.4), lineWidth: 1))
                if geocoding {
                    Text("Localizzazione in corso… \(geocodeLeft) rimaste")
                        .font(.system(size: 11)).foregroundStyle(Holo.subDim)
                } else {
                    MenuPillButton(label: "Localizza mancanti", icon: "mappin.and.ellipse") {
                        Task { await geocodeMissing() }
                    }
                }
            }
            Spacer()
        }
    }

    // ── Barra filtri: disponibilità + operazione, con contatore ──────────────
    private var filtriBar: some View {
        HStack(spacing: 8) {
            ForEach(DispFilter.allCases) { d in
                pill(d.label, on: dispFilter == d, hue: d.hue) { dispFilter = d }
            }
            Rectangle().fill(Holo.cardBorder).frame(width: 1, height: 18).padding(.horizontal, 2)
            pill("Tutte le operazioni", on: opFilter == nil, hue: nil) { opFilter = nil }
            ForEach(["vendita", "affitto", "traspaso"], id: \.self) { op in
                if let d = operationInfo(op) {
                    pill(d.label, on: opFilter == op, hue: d.hue) { opFilter = opFilter == op ? nil : op }
                }
            }
            Spacer()
            Text("\(filtered.count) su \(items.count)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Holo.subDim)
        }
    }
    private func pill(_ label: String, on: Bool, hue: Double?, _ act: @escaping () -> Void) -> some View {
        let c = hue.map { Holo.hsl($0, 55, 62) } ?? Csb.itemFgOn
        return Button(action: act) {
            Text(label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? (hue == nil ? Csb.itemFgOn : c) : Color(hex: 0x9b988f))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? (hue.map { Holo.hsl($0, 45, 45).opacity(0.18) } ?? Csb.tabOn) : Csb.tabsBg))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? (hue == nil ? Csb.tabOnBorder : c.opacity(0.5)) : Holo.cardBorder, lineWidth: 1))
        }.buttonStyle(.plain)
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
        do { items = try await HubAPI.listProprieta(slug: slug) }
        catch let e { errorMsg = e.localizedDescription }
    }

    // Geocodifica in background gli indirizzi senza coordinate → salva lat/lng,
    // così i pin appaiono sulla mappa. Apple throttla: una richiesta ~al secondo.
    private func geocodeMissing() async {
        guard !geocoding else { return }
        geocoding = true; defer { geocoding = false; geocodeLeft = 0 }
        let geocoder = CLGeocoder()
        let mancanti = items.filter { $0.latitude == nil || $0.longitude == nil }
        geocodeLeft = mancanti.count

        for p in mancanti {
            defer { geocodeLeft -= 1 }
            // dal più preciso al più generico: se la via non si trova, ripiega su zona/città
            let parts = [p.address, p.zone, p.city].compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            let queries = [
                (parts + ["Ibiza, Islas Baleares, España"]).joined(separator: ", "),
                (parts.dropFirst() + ["Ibiza, Islas Baleares, España"]).joined(separator: ", "),
            ]

            for q in queries {
                do {
                    if let loc = try await geocoder.geocodeAddressString(q).first?.location {
                        let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
                        try? await HubAPI.updateProprieta(id: p.id, fields: ["latitude": lat, "longitude": lng])
                        if let i = items.firstIndex(where: { $0.id == p.id }) {
                            items[i].latitude = lat; items[i].longitude = lng
                        }
                        break
                    }
                } catch let e as NSError where e.code == CLError.network.rawValue {
                    // Apple throttla le richieste a raffica: rallenta e riprova la stessa query
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if let loc = try? await geocoder.geocodeAddressString(q).first?.location {
                        let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
                        try? await HubAPI.updateProprieta(id: p.id, fields: ["latitude": lat, "longitude": lng])
                        if let i = items.firstIndex(where: { $0.id == p.id }) {
                            items[i].latitude = lat; items[i].longitude = lng
                        }
                        break
                    }
                } catch {
                    // indirizzo non trovato: prova la query successiva (più generica)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
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
                        if let rent = p.price_rent { Text(LeadFmt.euro(rent) + "/mes").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Holo.hsl(210, 78, 70)) }
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
            cell("", 52, .leading)          // foto
            cell("RIF.", 78, .leading)
            cell("OPERAZIONE", 158, .leading)
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

    @ViewBuilder private var thumbnail: some View {
        if let first = p.photos?.first {
            RemoteImageCarousel(paths: [first], height: 40, corner: 8)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05))
                .overlay(Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Holo.labelDim.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    var body: some View {
        Button { AppState.shared.route = .proprieta(id: p.id) } label: {
            HStack(spacing: 10) {
                // Foto (placeholder finché non ci sono foto)
                thumbnail.frame(width: 52, height: 40)
                // Rif.
                Text(p.reference ?? "—").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Holo.subDim).frame(width: 78, alignment: .leading).lineLimit(1)
                // Operazione + tipo (badge inline sulla stessa riga)
                HStack(spacing: 5) {
                    if let op = operationInfo(p.listing_type) {
                        Text(op.label).font(.system(size: 9.5, weight: .heavy)).tracking(0.4)
                            .foregroundStyle(Holo.hsl(op.hue, 85, 74))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Holo.hsl(op.hue, 70, 45).opacity(0.2)))
                    }
                    if let t = p.property_type {
                        Text(t).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Holo.subDim)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                            .lineLimit(1)
                    }
                }
                .frame(width: 158, alignment: .leading)
                // Indirizzo
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Holo.titleText).lineLimit(1)
                    let loc = [p.zone, p.city].compactMap { $0 }.joined(separator: " · ")
                    if !loc.isEmpty { Text(loc).font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Prezzo (per i traspaso: costo traspaso + affitto/mes)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(p.price.map { LeadFmt.euro($0) } ?? "—")
                        .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Holo.hsl(150, 70, 68)).lineLimit(1)
                    if let rent = p.price_rent {
                        Text(LeadFmt.euro(rent) + "/mes").font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Holo.hsl(210, 78, 70)).lineLimit(1)
                    }
                }
                .frame(width: 120, alignment: .trailing)
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
// ── Draft editabile: i campi della proprietà come stringhe modificabili ──────
struct PropertyDraft {
    var title = "", reference = "", address = "", zone = "", city = ""
    var category = "", listingType = "", propertyType = ""
    var bedrooms = "", bathrooms = "", sqm = "", price = "", priceRent = ""
    var status = PropertyStatus.disponibile
    var notes = ""
    var photos: [String] = []
    /// Di chi è l'immobile. Si sceglie alla creazione e di norma non cambia:
    /// spostarlo di agenzia è un'eccezione, non un interruttore di visibilità.
    var projectSlug = "gz-ibiza"
    /// Online sul sito del proprio progetto.
    var pubblicata = false

    init() {}
    init(_ e: Proprieta) {
        title = e.title; reference = e.reference ?? ""; address = e.address ?? ""
        zone = e.zone ?? ""; city = e.city ?? ""; category = e.category ?? ""
        listingType = e.listing_type ?? ""; propertyType = e.property_type ?? ""
        bedrooms = e.bedrooms.map(String.init) ?? ""; bathrooms = e.bathrooms.map(String.init) ?? ""
        sqm = e.size_sqm.map(String.init) ?? ""; price = e.price.map(String.init) ?? ""
        priceRent = e.price_rent.map(String.init) ?? ""
        status = .from(e.status); notes = e.notes ?? ""
        photos = e.photos ?? []
        projectSlug = e.project_slug ?? "gz-ibiza"; pubblicata = e.pubblicata ?? false
    }

    var isValid: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    private func s(_ v: String) -> String? {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    }
    func fields() -> [String: Any?] {
        [
            "title": title.trimmingCharacters(in: .whitespaces), "reference": s(reference),
            "address": s(address), "zone": s(zone), "city": s(city),
            "category": s(category), "listing_type": s(listingType), "property_type": s(propertyType),
            "bedrooms": Int(bedrooms), "bathrooms": Int(bathrooms), "size_sqm": Int(sqm),
            "price": Int(price), "price_rent": Int(priceRent), "status": status.rawValue,
            "notes": s(notes), "project_slug": projectSlug, "pubblicata": pubblicata,
        ]
    }
    // indirizzo cambiato → le coordinate salvate non valgono più (si rigeocodifica)
    func addressChanged(from e: Proprieta) -> Bool {
        s(address) != e.address || s(zone) != e.zone || s(city) != e.city
    }
}


extension String { func ifEmpty(_ f: String) -> String { isEmpty ? f : self } }

// ── Campi inline (stile HoloField, senza etichetta: sta nella colonna a sinistra)
struct InlineField: View {
    var placeholder: String = ""
    @Binding var text: String
    var font: Font = .system(size: 13)
    var multiline: Bool = false

    var body: some View {
        Group {
            if multiline {
                TextField(placeholder, text: $text, axis: .vertical).lineLimit(3...16)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain).font(font).foregroundStyle(Color(hex: 0xe8f2ff))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.32), lineWidth: 1))
    }
}

struct InlinePicker: View {
    let opts: [(String, String)]
    let sel: String
    let set: (String) -> Void

    /// Un valore scritto sul DB ma assente dall'elenco — «Local», «Piso»,
    /// «Ático»: il vocabolario spagnolo del mercato di Ibiza, che la lista
    /// italiana non prevede — si aggiunge in coda al menu. Senza, il campo
    /// appariva vuoto e l'immobile sembrava senza tipologia, pur avendola.
    private var voci: [(String, String)] {
        sel.isEmpty || opts.contains { $0.0 == sel } ? opts : opts + [(sel, sel)]
    }

    var body: some View {
        Menu {
            ForEach(voci, id: \.0) { o in Button(o.1) { set(o.0) } }
        } label: {
            HStack(spacing: 8) {
                Text(voci.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 13))
                    .foregroundStyle(sel.isEmpty ? Holo.labelDim : Color(hex: 0xe8f2ff)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Holo.labelDim)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.32), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

// ── Miniature foto in modifica (già caricate / in attesa di upload) ──
private struct ThumbBox<Content: View>: View {
    let caption: String?
    /// nil = sola lettura: la crocetta non compare.
    var onDelete: (() -> Void)?
    var altezza: CGFloat = 92
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0c1220))
                content
            }
            .frame(height: altezza)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if let caption {
                    Text(caption).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(6)
                }
            }

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(.black.opacity(0.6)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain).padding(5).help("Rimuovi foto")
            }
        }
    }
}

// ── Foto scaricate una volta sola ───────────────────────────────────────────
//
// La stessa immagine compare nella galleria grande, nella striscia sotto e
// nella griglia di gestione: senza cache erano tre scaricamenti a foto, e ogni
// riordino o eliminazione li rifaceva tutti, con la pagina che si impastava.
// Qui si scarica una volta per sessione e chi arriva mentre il download è in
// corso aspetta lo stesso task invece di aprirne un altro.
@MainActor
final class FotoCache {
    static let shared = FotoCache()
    // Si tengono i byte scaricati, non gli NSImage: il costo vero è la rete, e
    // il JPEG compresso in memoria pesa una frazione della bitmap decodificata.
    private let memoria = NSCache<NSString, NSData>()
    private var inCorso: [String: Task<Data?, Never>] = [:]

    private init() { memoria.totalCostLimit = 300 * 1024 * 1024 }

    func dati(_ path: String) async -> Data? {
        if let d = memoria.object(forKey: path as NSString) { return d as Data }
        let t: Task<Data?, Never>
        if let esistente = inCorso[path] {
            t = esistente
        } else {
            t = Task.detached { try? await HubAPI.downloadProprietaPhoto(path: path) }
            inCorso[path] = t
        }
        let data = await t.value
        inCorso[path] = nil
        if let data { memoria.setObject(data as NSData, forKey: path as NSString, cost: data.count) }
        return data
    }

    func immagine(_ path: String) async -> NSImage? {
        guard let d = await dati(path) else { return nil }
        return NSImage(data: d)
    }

    /// Dopo un'eliminazione: il path non esiste più, tenerlo in cache
    /// significherebbe mostrare una foto cancellata se ne rientra uno uguale.
    func dimentica(_ path: String) {
        memoria.removeObject(forKey: path as NSString)
        inCorso[path] = nil
    }
}

struct RemotePhotoThumb: View {
    let path: String
    var altezza: CGFloat = 92
    /// nil in sola lettura: la galleria si sfoglia, non si modifica.
    var onDelete: (() -> Void)?
    @State private var img: NSImage?
    @State private var loaded = false

    var body: some View {
        ThumbBox(caption: nil, onDelete: onDelete, altezza: altezza) {
            if let img { Image(nsImage: img).resizable().scaledToFill() }
            else if !loaded { ProgressView().controlSize(.small) }
            else { Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Csb.secFg.opacity(0.5)) }
        }
        .task(id: path) {
            if let d = await FotoCache.shared.dati(path) { img = NSImage(data: d) }
            loaded = true
        }
    }
}

struct LocalPhotoThumb: View {
    let url: URL
    var altezza: CGFloat = 92
    let onDelete: () -> Void

    var body: some View {
        ThumbBox(caption: "Nuova", onDelete: onDelete, altezza: altezza) {
            if let img = NSImage(contentsOf: url) { Image(nsImage: img).resizable().scaledToFill() }
            else { Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Csb.secFg.opacity(0.5)) }
        }
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
    // Controparte collegata all'anagrafica: senza questo legame la transazione
    // non comparirebbe nella scheda del contatto, resterebbe solo testo libero.
    @State private var contatti: [Contatto] = []
    @State private var clienteId: String?

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
                // Collegando un contatto, l'operazione compare nel suo storico.
                VStack(alignment: .leading, spacing: 5) {
                    Text("CONTATTO IN RUBRICA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                    Menu {
                        Button("Nessuno") { clienteId = nil }
                        ForEach(contatti) { c in
                            Button(c.ragione_sociale) {
                                clienteId = c.id
                                if counterparty.trimmingCharacters(in: .whitespaces).isEmpty {
                                    counterparty = c.ragione_sociale
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(contatti.first { $0.id == clienteId }?.ragione_sociale ?? "Nessuno")
                                .font(.system(size: 13)).foregroundStyle(Holo.text).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Csb.secFg)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
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
        .frame(width: 500, height: 540)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .task { contatti = (try? await HubAPI.listContatti()) ?? [] }
    }

    private func save() async {
        saving = true
        func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let body: [String: Any?] = [
            "proprieta_id": proprietaId, "event_type": event.rawValue, "event_date": f.string(from: date),
            "price": Int(price), "counterparty": s(counterparty), "agent": s(agent), "notes": s(notes),
            "cliente_id": clienteId,
        ]
        do {
            try await HubAPI.addStorico(body)
            // Rescissione, devoluzione e ritiro tolgono l'immobile dal mercato:
            // aggiorno lo stato così griglia e filtro lo vedono subito ritirato.
            if event.ritiraImmobile {
                try? await HubAPI.updateProprieta(id: proprietaId, fields: ["status": "ritirata"])
            }
            await onSaved(); dismiss()
        }
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
        let anns: [PropAnnotation] = items.compactMap { p in
            guard let la = p.latitude, let lo = p.longitude else { return nil }
            return PropAnnotation(propId: p.id,
                                  coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo),
                                  title: p.title, subtitle: p.price.map { LeadFmt.euro($0) })
        }
        // ridisegna solo se l'insieme è cambiato (altrimenti si chiuderebbe il callout aperto)
        let newIds = Set(anns.map(\.propId))
        guard newIds != context.coordinator.shownIds else { return }
        context.coordinator.shownIds = newIds
        mv.removeAnnotations(mv.annotations)
        mv.addAnnotations(anns)
        // al primo caricamento inquadra tutti i pin; poi rispetta lo zoom dell'utente
        if !context.coordinator.didFit, !anns.isEmpty {
            context.coordinator.didFit = true
            mv.showAnnotations(anns, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var shownIds = Set<String>()
        var didFit = false

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // gruppo di pin vicini: pastiglia con il conteggio
            if let cluster = annotation as? MKClusterAnnotation {
                let id = "propCluster"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
                v.glyphText = "\(cluster.memberAnnotations.count)"
                v.displayPriority = .required
                return v
            }
            guard annotation is PropAnnotation else { return nil }
            let id = "prop"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.annotation = annotation
            v.canShowCallout = true
            v.markerTintColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
            v.glyphImage = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)
            // senza questi due MapKit nasconde i marker che si sovrappongono
            v.displayPriority = .required
            v.clusteringIdentifier = "prop"
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
