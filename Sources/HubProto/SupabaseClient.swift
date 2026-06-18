import Foundation

/// Mini client PostgREST — legge la stessa config.json di UNVRS Hub (Tauri).
/// Contesto nativo (no browser/webview): ok usare la secret key.
struct SupabaseClient {
    let baseURL: URL
    let secretKey: String

    static let shared: SupabaseClient? = try? SupabaseClient.fromHubConfig()

    static func fromHubConfig() throws -> SupabaseClient {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.unvrslabs.hub/config.json")
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
        req.setValue(secretKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
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

    /// INSERT che restituisce la riga creata (Prefer: return=representation).
    func insertReturning<T: Decodable>(_ table: String, body: [String: Any?]) async throws -> T {
        let (data, _) = try await run(request(table, method: "POST", prefer: "return=representation", body: body))
        let rows = try JSONDecoder().decode([T].self, from: data)
        guard let first = rows.first else {
            throw NSError(domain: "HubProto", code: 4, userInfo: [NSLocalizedDescriptionKey: "INSERT senza riga di ritorno"])
        }
        return first
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
                    NSLocalizedDescriptionKey: "config.json mancante — esegui scripts/setup-config.sh di unvrs-hub"])
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

    static func listRecentEvents(days: Int = 14) async throws -> [HubEvent] {
        let since = isoNow(addingDays: -days)
        return try await sb.fetch("hub_events?select=*&created_at=gte.\(enc(since))&order=created_at.desc&limit=500")
    }

    /// Audit log fire-and-forget: non blocca l'operazione principale
    static func logEvent(projectId: String?, kind: String, message: String) async {
        try? await sb.mutate("hub_events", method: "POST",
                             body: ["project_id": projectId, "kind": kind, "message": message])
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

    static func createCommessa(_ fields: [String: Any?]) async throws {
        try await sb.mutate("commesse", method: "POST", body: fields)
    }

    static func deleteCommessa(id: String) async throws {
        try await sb.mutate("commesse?id=eq.\(enc(id))", method: "DELETE")
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(Double(days) * 86_400))
    }
}
