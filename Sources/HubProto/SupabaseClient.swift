import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    /// Qualcosa è stato scritto sul database. Ogni pagina che tiene dei dati in
    /// memoria si rimette in pari da sola: prima ciascuna caricava una volta
    /// all'apertura, così segnare un pagamento nelle prenotazioni lasciava la
    /// Tesoreria coi numeri di prima finché non si riavviava l'app.
    static let datiCambiati = Notification.Name("gz.brain.datiCambiati")
}

/// Mini client PostgREST — legge la config.json di GZ Brain.
/// Contesto nativo (no browser/webview): ok usare la secret key.
struct SupabaseClient {
    let baseURL: URL
    let secretKey: String

    static let shared: SupabaseClient? = try? SupabaseClient.fromHubConfig()

    /// Mette le credenziali sulla richiesta.
    ///
    /// Le chiavi storiche sono JWT e viaggiano su entrambi gli header; quelle
    /// nuove (`sb_secret_…`) non lo sono, e su `Authorization` la piattaforma
    /// prova comunque a decodificarle e risponde «Invalid JWT». Vanno solo su
    /// `apikey`. Il controllo sul prefisso fa sì che l'app funzioni prima e
    /// dopo la rotazione, senza doverla ricompilare in mezzo al guado.
    private func firmaLaRichiesta(_ req: inout URLRequest) {
        req.setValue(secretKey, forHTTPHeaderField: "apikey")
        if secretKey.hasPrefix("eyJ") {
            req.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        }
    }

    static func fromHubConfig() throws -> SupabaseClient {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.gz.brain/config.json")
        let data = try Data(contentsOf: path)
        struct Cfg: Decodable { let supabase_url: String; let supabase_secret_key: String }
        let cfg = try JSONDecoder().decode(Cfg.self, from: data)
        guard let url = URL(string: cfg.supabase_url) else {
            throw NSError(domain: "HubProto", code: 1, userInfo: [NSLocalizedDescriptionKey: "supabase_url non valido"])
        }
        return SupabaseClient(baseURL: url, secretKey: cfg.supabase_secret_key)
    }

    private func request(_ pathAndQuery: String, method: String = "GET",
                         prefer: String? = nil, body: [String: Any?]? = nil) throws -> URLRequest {
        // pathAndQuery contiene già la query string PostgREST (es. "projects?select=*")
        guard let url = URL(string: baseURL.absoluteString + "/rest/v1/" + pathAndQuery) else {
            throw NSError(domain: "HubProto", code: 2, userInfo: [NSLocalizedDescriptionKey: "URL non valido: \(pathAndQuery)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        firmaLaRichiesta(&req)
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        }
        return req
    }

    private func run(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "HubProto", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg.prefix(300))"])
        }
        // Ogni scrittura andata a buon fine avvisa tutta l'app. Sta qui e non
        // nei singoli salvataggi perché così non se ne può dimenticare uno:
        // qualunque strada passi da qui.
        if (req.httpMethod ?? "GET") != "GET" {
            Task { @MainActor in NotificationCenter.default.post(name: .datiCambiati, object: nil) }
        }
        return (data, http)
    }

    func fetch<T: Decodable>(_ pathAndQuery: String) async throws -> T {
        let (data, _) = try await run(request(pathAndQuery))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func mutate(_ pathAndQuery: String, method: String, body: [String: Any?]? = nil,
                prefer: String = "return=minimal") async throws {
        _ = try await run(request(pathAndQuery, method: method, prefer: prefer, body: body))
    }

    /// Chiama una funzione Postgres (RPC). Ritorna il JSON grezzo di risposta.
    @discardableResult
    func rpc(_ name: String, args: [String: Any?] = [:]) async throws -> Data {
        let (data, _) = try await run(request("rpc/\(name)", method: "POST", prefer: "return=representation", body: args))
        return data
    }

    /// INSERT che restituisce la riga creata (Prefer: return=representation).
    func insertReturning<T: Decodable>(_ table: String, body: [String: Any?]) async throws -> T {
        let (data, _) = try await run(request(table, method: "POST", prefer: "return=representation", body: body))
        let rows = try JSONDecoder().decode([T].self, from: data)
        guard let first = rows.first else {
            throw NSError(domain: "HubProto", code: 4, userInfo: [NSLocalizedDescriptionKey: "INSERT senza riga di ritorno"])
        }
        return first
    }

    /// INSERT bulk (array JSON): tutte le righe in una sola richiesta, atomica lato PostgREST.
    func insertMany(_ table: String, rows: [[String: Any?]]) async throws {
        guard !rows.isEmpty else { return }
        var req = try request(table, method: "POST", prefer: "return=minimal")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: rows.map { $0.mapValues { $0 ?? NSNull() } })
        _ = try await run(req)
    }

    // ── Storage (/storage/v1/object) ──
    @discardableResult
    func uploadFile(bucket: String, path: String, data: Data, contentType: String) async throws -> String {
        let url = baseURL.appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        firmaLaRichiesta(&req)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")
        req.httpBody = data
        _ = try await run(req)
        return path
    }

    func downloadFile(bucket: String, path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
        var req = URLRequest(url: url)
        firmaLaRichiesta(&req)
        let (data, _) = try await run(req)
        return data
    }

    /// Indirizzo diretto di un file in un bucket pubblico: serve a chi legge in
    /// streaming (i video) invece di scaricare tutto prima di partire.
    func publicURL(bucket: String, path: String) -> URL? {
        let quote = path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: baseURL.absoluteString + "/storage/v1/object/public/\(bucket)/\(quote)")
    }

    func deleteFile(bucket: String, path: String) async throws {
        let url = baseURL.appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        firmaLaRichiesta(&req)
        _ = try await run(req)
    }

    /// Count via header Content-Range con Prefer: count=exact (come restCount in db.ts)
    func count(_ pathAndQuery: String) async throws -> Int {
        var req = try request(pathAndQuery, prefer: "count=exact")
        req.setValue("0-0", forHTTPHeaderField: "Range")
        let (_, http) = try await run(req)
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int($0) })
        else { return 0 }
        return total
    }
}

// ─── API di dominio (port di lib/projects.ts + lib/leads.ts) ───

enum HubAPI {
    static var sb: SupabaseClient {
        get throws {
            guard let c = SupabaseClient.shared else {
                throw NSError(domain: "HubProto", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "config.json mancante — crea ~/Library/Application Support/dev.gz.brain/config.json"])
            }
            return c
        }
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    static func listProjects() async throws -> [Project] {
        try await sb.fetch("projects?select=*&order=sort_order.asc")
    }

    static func getProject(slug: String) async throws -> Project? {
        let rows: [Project] = try await sb.fetch("projects?select=*&slug=eq.\(enc(slug))")
        return rows.first
    }

    /// Riordina i progetti: scrive sort_order = posizione nell'array.
    static func reorderProjects(_ ids: [String]) async throws {
        let now = isoNow()
        for (i, id) in ids.enumerated() {
            try await sb.mutate("projects?id=eq.\(enc(id))", method: "PATCH",
                                 body: ["sort_order": i, "updated_at": now])
        }
    }

    static func listRecentEvents(days: Int = 14) async throws -> [HubEvent] {
        let since = isoNow(addingDays: -days)
        return try await sb.fetch("hub_events?select=*&created_at=gte.\(enc(since))&order=created_at.desc&limit=500")
    }

    /// Audit log fire-and-forget: non blocca l'operazione principale
    static func logEvent(projectId: String?, kind: String, message: String) async {
        try? await sb.mutate("hub_events", method: "POST",
                             body: ["project_id": projectId, "kind": kind, "message": message])
    }

    /// Crea un nuovo progetto e ritorna la riga creata.
    @discardableResult
    static func createProject(_ fields: [String: Any?]) async throws -> Project {
        let p: Project = try await sb.insertReturning("projects", body: fields)
        await logEvent(projectId: p.id, kind: "project_created", message: "Creato progetto \(p.name)")
        return p
    }

    static func updateProject(id: String, fields: [String: Any?], name: String) async throws {
        var body = fields
        body["updated_at"] = isoNow()
        try await sb.mutate("projects?id=eq.\(enc(id))", method: "PATCH", body: body)
        await logEvent(projectId: id, kind: "project_updated", message: "Aggiornato progetto \(name)")
    }

    // ── Leads ──

    /// Lista leads: cerca su ragione_sociale (ilike), stato opzionale, paginazione server-side.
    /// Senza filtro: prima i clienti (chiuso_vinto), poi gli altri — come listLeads in leads.ts.
    static func listLeads(projectId: String, search: String? = nil, status: String? = nil,
                          limit: Int = 50, offset: Int = 0) async throws -> [Lead] {
        func bucket(_ statusFilter: String, _ l: Int, _ o: Int) async throws -> [Lead] {
            var q = "leads?select=*&project_id=eq.\(enc(projectId))&\(statusFilter)&order=ragione_sociale.asc&limit=\(l)&offset=\(o)"
            if let search, !search.isEmpty { q += "&ragione_sociale=ilike.*\(enc(search))*" }
            return try await sb.fetch(q)
        }
        if let status { return try await bucket("status=eq.\(enc(status))", limit, offset) }
        let clienti = try await bucket("status=eq.chiuso_vinto", 2000, 0)
        let fromClienti = offset < clienti.count ? Array(clienti[offset..<min(clienti.count, offset + limit)]) : []
        let remaining = limit - fromClienti.count
        if remaining <= 0 { return fromClienti }
        let othersOffset = max(0, offset - clienti.count)
        let others = try await bucket("status=neq.chiuso_vinto", remaining, othersOffset)
        return fromClienti + others
    }

    // ── Clienti & Commesse ──

    /// Clienti con le loro commesse annidate (PostgREST embedding via FK).
    static func listClienti(search: String? = nil) async throws -> [Cliente] {
        var q = "clienti?select=*,commesse(id,nome,tipo,stato)&order=ragione_sociale.asc&limit=2000"
        if let search, !search.isEmpty { q += "&ragione_sociale=ilike.*\(enc(search))*" }
        return try await sb.fetch(q)
    }

    static func getCliente(id: String) async throws -> Cliente? {
        let rows: [Cliente] = try await sb.fetch("clienti?select=*,commesse(*)&id=eq.\(enc(id))")
        return rows.first
    }

    // ── Documenti cliente (bucket 'clienti') ──
    static func listClienteDocumenti(_ clienteId: String) async throws -> [ClienteDocumento] {
        try await sb.fetch("cliente_documenti?select=*&cliente_id=eq.\(enc(clienteId))&order=created_at.asc")
    }
    /// Legge un file locale, lo carica nel bucket e registra la riga in cliente_documenti.
    static func addClienteDocumento(clienteId: String, fileURL: URL) async throws {
        let bytes = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.isEmpty ? "pdf" : fileURL.pathExtension
        let ct = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let safe = fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let name = "\(clienteId)/\(UUID().uuidString.prefix(8))-\(safe).\(ext)"
        let path = try await sb.uploadFile(bucket: "clienti", path: name, data: bytes, contentType: ct)
        try await sb.mutate("cliente_documenti", method: "POST", body: [
            "cliente_id": clienteId, "nome": fileURL.lastPathComponent, "path": path,
        ])
    }
    static func deleteClienteDocumento(id: String, path: String?) async throws {
        try await sb.mutate("cliente_documenti?id=eq.\(enc(id))", method: "DELETE")
        if let p = path { try? await sb.deleteFile(bucket: "clienti", path: p) }
    }
    static func downloadClienteFile(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "clienti", path: path)
    }

    /// Crea un cliente manuale; ritorna la riga creata (per collegarci subito una commessa).
    @discardableResult
    static func createCliente(_ fields: [String: Any?]) async throws -> Cliente {
        var body = fields
        body["source"] = "manuale"
        return try await sb.insertReturning("clienti", body: body)
    }

    static func deleteCliente(id: String) async throws {
        try await sb.mutate("clienti?id=eq.\(enc(id))", method: "DELETE")
    }

    /// Aggiorna i dati anagrafici di un cliente (PATCH).
    static func updateCliente(id: String, fields: [String: Any?]) async throws {
        var body = fields
        body["updated_at"] = isoNow()
        try await sb.mutate("clienti?id=eq.\(enc(id))", method: "PATCH", body: body)
    }

    static func createCommessa(_ fields: [String: Any?]) async throws {
        try await sb.mutate("commesse", method: "POST", body: fields)
    }

    // ── Fatturazione: impostazioni azienda ──
    static func getAzienda() async throws -> AziendaSettings? {
        let rows: [AziendaSettings] = try await sb.fetch("azienda_settings?select=*&id=eq.1")
        return rows.first
    }
    static func saveAzienda(_ fields: [String: Any?]) async throws {
        var body = fields
        body["id"] = 1
        body["updated_at"] = isoNow()
        try await sb.mutate("azienda_settings", method: "POST", body: body,
                            prefer: "resolution=merge-duplicates,return=minimal")
    }
    /// Carica logo/firma nel bucket 'azienda', ritorna il path.
    static func uploadAziendaAsset(_ data: Data, name: String, contentType: String) async throws -> String {
        try await sb.uploadFile(bucket: "azienda", path: name, data: data, contentType: contentType)
    }
    static func downloadAzienda(_ path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "azienda", path: path)
    }

    // ── Fatture ──
    static func nextNumero(anno: Int) async throws -> Int {
        struct R: Decodable { let numero: Int }
        let rows: [R] = try await sb.fetch("fatture?select=numero&anno=eq.\(anno)&order=numero.desc&limit=1")
        let next = (rows.first?.numero ?? 0) + 1
        // nel 2026 le fatture 1–6 sono state emesse altrove: si riparte dalla 7
        return anno == 2026 ? Swift.max(next, 7) : next
    }
    static func listFatture(clienteId: String? = nil) async throws -> [Fattura] {
        var q = "fatture?select=*&order=anno.desc,numero.desc&limit=2000"
        if let c = clienteId { q += "&cliente_id=eq.\(enc(c))" }
        return try await sb.fetch(q)
    }
    static func getFatturaRighe(_ id: String) async throws -> [FatturaRiga] {
        try await sb.fetch("fattura_righe?select=*&fattura_id=eq.\(enc(id))&order=ordine.asc")
    }
    static func updateFattura(id: String, fields: [String: Any?]) async throws {
        var body = fields; body["updated_at"] = isoNow()
        try await sb.mutate("fatture?id=eq.\(enc(id))", method: "PATCH", body: body)
    }
    static func updateSpesa(id: String, fields: [String: Any?]) async throws {
        try await sb.mutate("spese?id=eq.\(enc(id))", method: "PATCH", body: fields)
    }
    static func fatturaExists(anno: Int, numero: Int) async throws -> Bool {
        struct R: Decodable { let id: String }
        let rows: [R] = try await sb.fetch("fatture?select=id&anno=eq.\(anno)&numero=eq.\(numero)&limit=1")
        return !rows.isEmpty
    }
    @discardableResult
    static func createFattura(_ fields: [String: Any?], righe: [[String: Any?]]) async throws -> Fattura {
        let f: Fattura = try await sb.insertReturning("fatture", body: fields)
        do {
            try await sb.insertMany("fattura_righe", rows: righe.map { r in
                var r = r; r["fattura_id"] = f.id; return r
            })
        } catch {
            // niente fattura orfana senza righe: rollback e rilancio
            try? await sb.mutate("fatture?id=eq.\(enc(f.id))", method: "DELETE")
            throw error
        }
        return f
    }
    static func setFatturaPdfPath(id: String, path: String) async throws {
        try await sb.mutate("fatture?id=eq.\(enc(id))", method: "PATCH", body: ["pdf_path": path, "updated_at": isoNow()])
    }
    static func uploadFatturaPDF(_ data: Data, anno: Int, numero: Int) async throws -> String {
        try await sb.uploadFile(bucket: "fatture", path: "\(anno)/\(numero).pdf", data: data, contentType: "application/pdf")
    }
    static func downloadFatturaPDF(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "fatture", path: path)
    }
    /// Rimuove dal bucket un PDF orfano (es. dopo il cambio numero di una fattura).
    static func deleteFatturaPDFFile(path: String) async throws {
        try await sb.deleteFile(bucket: "fatture", path: path)
    }
    /// Elimina la fattura e le sue righe (e tenta di rimuovere il PDF dallo storage).
    static func deleteFattura(id: String, pdfPath: String?) async throws {
        try await sb.mutate("fattura_righe?fattura_id=eq.\(enc(id))", method: "DELETE")
        try await sb.mutate("fatture?id=eq.\(enc(id))", method: "DELETE")
        if let p = pdfPath { try? await sb.deleteFile(bucket: "fatture", path: p) }
    }

    static func deleteCommessa(id: String) async throws {
        try await sb.mutate("commesse?id=eq.\(enc(id))", method: "DELETE")
    }

    // ── Spese (fatture passive ricevute/pagate) ──
    static func listSpese() async throws -> [Spesa] {
        try await sb.fetch("spese?select=*&order=data.desc.nullslast,created_at.desc&limit=2000")
    }
    @discardableResult
    static func createSpesa(_ fields: [String: Any?]) async throws -> Spesa {
        try await sb.insertReturning("spese", body: fields)
    }
    static func deleteSpesa(id: String, filePath: String?) async throws {
        try await sb.mutate("spese?id=eq.\(enc(id))", method: "DELETE")
        if let p = filePath { try? await sb.deleteFile(bucket: "spese", path: p) }
    }
    static func uploadSpesaFile(_ data: Data, name: String, contentType: String) async throws -> String {
        try await sb.uploadFile(bucket: "spese", path: name, data: data, contentType: contentType)
    }
    static func downloadSpesaFile(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "spese", path: path)
    }

    // ── Estratti conto (banca) ──
    static func listEstratti() async throws -> [Estratto] {
        try await sb.fetch("estratti_conto?select=*&order=anno.desc,mese.desc&limit=1000")
    }
    @discardableResult
    static func createEstratto(_ fields: [String: Any?]) async throws -> Estratto {
        try await sb.insertReturning("estratti_conto", body: fields)
    }
    static func deleteEstratto(id: String, filePath: String?) async throws {
        try await sb.mutate("estratti_conto?id=eq.\(enc(id))", method: "DELETE")
        if let p = filePath { try? await sb.deleteFile(bucket: "estratti", path: p) }
    }
    static func uploadEstrattoFile(_ data: Data, name: String, contentType: String) async throws -> String {
        try await sb.uploadFile(bucket: "estratti", path: name, data: data, contentType: contentType)
    }
    static func downloadEstrattoFile(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "estratti", path: path)
    }

    // ── Abbinamenti manuali movimento↔spesa/fattura ──
    static func listMatches() async throws -> [MovMatch] {
        try await sb.fetch("mov_match?select=*&limit=5000")
    }
    static func upsertMatch(txId: String, kind: String, refId: String?) async throws {
        try await sb.mutate("mov_match", method: "POST",
                            body: ["tx_id": txId, "kind": kind, "ref_id": refId],
                            prefer: "resolution=merge-duplicates,return=minimal")
    }
    static func deleteMatch(txId: String) async throws {
        try await sb.mutate("mov_match?tx_id=eq.\(enc(txId))", method: "DELETE")
    }

    static func leadStatusCounts(projectId: String) async throws -> [String: Int] {
        struct Row: Decodable { let status: String }
        let rows: [Row] = try await sb.fetch("leads?select=status&project_id=eq.\(enc(projectId))&limit=2000")
        return rows.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    static func leadTipoServizioCounts(projectId: String) async throws -> [String: Int] {
        struct Row: Decodable { let tipo_servizio: String? }
        let rows: [Row] = try await sb.fetch("leads?select=tipo_servizio&project_id=eq.\(enc(projectId))&limit=2000")
        return rows.reduce(into: [:]) { $0[$1.tipo_servizio ?? "—", default: 0] += 1 }
    }

    static func getLead(id: String) async throws -> Lead? {
        let rows: [Lead] = try await sb.fetch("leads?select=*&id=eq.\(enc(id))")
        return rows.first
    }

    static func getLeadDetail(leadId: String) async throws -> (contacts: [LeadContact], notes: [LeadNote], activity: [LeadActivity]) {
        async let c: [LeadContact] = sb.fetch("lead_contacts?select=*&lead_id=eq.\(enc(leadId))&order=created_at.asc")
        async let n: [LeadNote] = sb.fetch("lead_notes?select=*&lead_id=eq.\(enc(leadId))&order=created_at.asc")
        async let a: [LeadActivity] = sb.fetch("lead_activity_log?select=*&lead_id=eq.\(enc(leadId))&order=created_at.desc&limit=50")
        return try await (c, n, a)
    }

    /// PATCH status + INSERT activity_log + hub_event (port di updateLeadStatus)
    static func updateLeadStatus(_ lead: Lead, to status: String) async throws {
        try await sb.mutate("leads?id=eq.\(enc(lead.id))", method: "PATCH",
                            body: ["status": status, "updated_at": isoNow()])
        try? await sb.mutate("lead_activity_log", method: "POST", body: [
            "id": UUID().uuidString.lowercased(), "lead_id": lead.id,
            "event_type": "status_change", "from_value": lead.status, "to_value": status,
        ])
        await logEvent(projectId: lead.project_id, kind: "lead_status",
                       message: "\(lead.ragione_sociale): \(lead.status) → \(status)")
    }

    static func addLeadNote(_ lead: Lead, body: String) async throws {
        try await sb.mutate("lead_notes", method: "POST", body: [
            "id": UUID().uuidString.lowercased(), "lead_id": lead.id, "body": body,
        ])
        await logEvent(projectId: lead.project_id, kind: "lead_note",
                       message: "Nota su \(lead.ragione_sociale)")
    }

    static func leadsTotal() async throws -> Int {
        try await sb.count("leads?select=id")
    }

    private static func isoNow(addingDays days: Int = 0) -> String {
        isoNowString(addingDays: days)
    }
}
