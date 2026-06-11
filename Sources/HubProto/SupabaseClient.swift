import Foundation

/// Mini client PostgREST — legge la stessa config.json di UNVRS Hub (Tauri).
/// Contesto nativo (no browser/webview): ok usare la secret key.
struct SupabaseClient {
    let baseURL: URL
    let secretKey: String

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

    private func request(_ pathAndQuery: String, prefer: String? = nil) -> URLRequest {
        // pathAndQuery contiene già la query string PostgREST (es. "projects?select=*")
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/rest/v1/" + pathAndQuery)!)
        req.setValue(secretKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        return req
    }

    func fetch<T: Decodable>(_ pathAndQuery: String) async throws -> T {
        let (data, _) = try await URLSession.shared.data(for: request(pathAndQuery))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Count via header Content-Range con Prefer: count=exact (come restCount in db.ts)
    func count(_ pathAndQuery: String) async throws -> Int {
        var req = request(pathAndQuery, prefer: "count=exact")
        req.setValue("0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int($0) })
        else { return 0 }
        return total
    }
}
