import Foundation

// ─── Modelli WhatsApp ────────────────────────────────────────────────────────

struct WAAgent: Identifiable, Decodable, Equatable {
    let id: String
    var project_slug: String
    var display_name: String
    var phone_number: String?
    var enabled: Bool
    var connection_status: String
    var connection_error: String?
    var last_seen_at: String?
    var model: String
    var system_prompt: String
    var knowledge: String
    var greeting: String?
    var max_agent_messages: Int
    var escalation_keywords: [String]
    var listing_url_template: String?

    var connesso: Bool { connection_status == "connesso" }
}

struct WAConversation: Identifiable, Decodable, Equatable {
    let id: String
    var project_slug: String
    var wa_jid: String
    var phone: String?
    var customer_name: String?
    var status: String
    var agent_enabled: Bool
    var agent_msg_count: Int
    var summary: String?
    var lead_id: String?
    var last_message_at: String?
    var created_at: String?

    var titolo: String { customer_name?.isEmpty == false ? customer_name! : (telefono ?? "Sconosciuto") }

    /// Numero chiamabile, se c'è. WhatsApp indirizza molte chat con un LID
    /// (`2696…@lid`): è un identificatore privato, non un numero, e mostrarlo
    /// come telefono significa dare cifre che non corrispondono a nessuno.
    var telefono: String? {
        guard wa_jid.hasSuffix("@s.whatsapp.net") || phone?.hasPrefix("+") == true,
              let p = phone, !p.isEmpty else { return nil }
        return p
    }
}

struct WAMessage: Identifiable, Decodable, Equatable {
    let id: String
    var direction: String   // in | out
    var author: String      // cliente | agente | umano
    var body: String
    var created_at: String?

    var daCliente: Bool { direction == "in" }
}

/// Stato di una conversazione, con colore per il badge.
enum WAStatus: String, CaseIterable {
    case attiva, qualificata, escalata, chiusa
    var label: String {
        switch self {
        case .attiva: return "Attiva"
        case .qualificata: return "Qualificata"
        case .escalata: return "Da seguire"
        case .chiusa: return "Chiusa"
        }
    }
    var hue: Double {
        switch self {
        case .attiva: return 210
        case .qualificata: return 145
        case .escalata: return 35
        case .chiusa: return 250
        }
    }
    static func from(_ raw: String?) -> WAStatus { WAStatus(rawValue: raw ?? "") ?? .attiva }
}

/// Preferenza per contatto: chi risponde a questa persona.
/// Vive in una tabella sua, agganciata al numero, così la scelta sopravvive
/// all'azzeramento della conversazione.
struct WAContatto: Identifiable, Decodable, Equatable {
    let id: String
    var project_slug: String
    var wa_jid: String
    var nome: String?
    var telefono: String?
    var agente_attivo: Bool
    var nota: String?
}

// ─── API Supabase ────────────────────────────────────────────────────────────

extension HubAPI {
    static func getWAAgent(slug: String) async throws -> WAAgent? {
        let rows: [WAAgent] = try await sb.fetch("wa_agents?select=*&project_slug=eq.\(slug)")
        return rows.first
    }

    static func updateWAAgent(slug: String, fields: [String: Any?]) async throws {
        var body = fields; body["updated_at"] = isoNowString()
        try await sb.mutate("wa_agents?project_slug=eq.\(slug)", method: "PATCH", body: body)
    }

    static func listWAConversations(slug: String) async throws -> [WAConversation] {
        try await sb.fetch(
            "wa_conversations?select=*&project_slug=eq.\(slug)&order=last_message_at.desc.nullslast&limit=300")
    }

    static func listWAMessages(conversationId: String) async throws -> [WAMessage] {
        try await sb.fetch(
            "wa_messages?select=*&conversation_id=eq.\(conversationId)&order=created_at.asc&limit=500")
    }

    static func listWAContatti(slug: String) async throws -> [WAContatto] {
        try await sb.fetch("wa_contatti?select=*&project_slug=eq.\(slug)&order=updated_at.desc&limit=500")
    }

    static func setAgenteContatto(id: String, attivo: Bool) async throws {
        try await sb.mutate("wa_contatti?id=eq.\(id)", method: "PATCH",
                            body: ["agente_attivo": attivo, "updated_at": isoNowString()])
    }

    /// Crea la preferenza se il contatto non l'ha ancora: capita quando la
    /// conversazione è più vecchia della tabella contatti.
    @discardableResult
    static func creaContatto(slug: String, jid: String, nome: String?, telefono: String?, attivo: Bool) async throws -> WAContatto {
        try await sb.insertReturning("wa_contatti", body: [
            "project_slug": slug, "wa_jid": jid, "nome": nome,
            "telefono": telefono, "agente_attivo": attivo,
        ])
    }

    static func updateWAConversation(id: String, fields: [String: Any?]) async throws {
        try await sb.mutate("wa_conversations?id=eq.\(id)", method: "PATCH", body: fields)
    }
}

// ─── Client HTTP verso il ponte Baileys ──────────────────────────────────────

/// Parla col servizio Node su Hetzner: QR, stato sessione, invio manuale.
/// L'URL e il token stanno in `integrations`, così non sono compilati nell'app.
@MainActor
final class WABridge {
    static let shared = WABridge()

    private var base: String?
    private var token: String?
    private var loaded = false

    struct Stato: Decodable {
        var connected: Bool
        var qr: String?
        var phone: String?
    }

    private struct KV: Decodable { let key: String; let value: String }

    /// Legge base URL e token dalle integrazioni. Il ponte può non essere ancora
    /// configurato: in quel caso le chiamate falliscono con un messaggio chiaro
    /// invece di piantare la UI.
    private func ensureConfig() async throws {
        if loaded { return }
        let rows: [KV] = try await HubAPI.sb.fetch(
            "integrations?select=key,value&key=in.(wa_bridge_url,wa_api_token)")
        base = rows.first { $0.key == "wa_bridge_url" }?.value
        token = rows.first { $0.key == "wa_api_token" }?.value
        loaded = true
    }

    /// Da richiamare dopo aver cambiato URL o token nelle Connessioni API.
    func invalidate() { loaded = false; base = nil; token = nil }

    /// Distinguere i due casi conta: "non l'abbiamo ancora installato" è uno
    /// stato normale del progetto, "è installato ma non risponde" è un guasto.
    enum Errore: LocalizedError {
        case nonConfigurato
        case indirizzoNonValido
        case nonRaggiungibile(String)
        case rispostaKO(Int)

        var errorDescription: String? {
            switch self {
            case .nonConfigurato:
                return "Il servizio WhatsApp non è ancora attivo"
            case .indirizzoNonValido:
                return "L'indirizzo del servizio WhatsApp non è valido"
            case .nonRaggiungibile:
                return "Il servizio WhatsApp non risponde"
            case .rispostaKO(let code):
                return code == 401
                    ? "Il servizio WhatsApp ha rifiutato le credenziali"
                    : "Il servizio WhatsApp ha risposto con un errore (\(code))"
            }
        }

        /// Cosa può fare l'utente, in una riga.
        var rimedio: String {
            switch self {
            case .nonConfigurato:
                return "Va installato sul server: finché non c'è, qui puoi comunque preparare l'agente."
            case .indirizzoNonValido:
                return "Correggilo in Impostazioni → Connessioni API."
            case .nonRaggiungibile(let dettaglio):
                return "Controlla che sia acceso sul server. (\(dettaglio))"
            case .rispostaKO(let code):
                return code == 401
                    ? "Il token in Connessioni API non coincide con quello del server."
                    : "Riprova tra poco; se insiste, guarda i log del servizio."
            }
        }
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         timeout: TimeInterval = 20) async throws -> Data {
        try await ensureConfig()
        guard let base, let token, !base.isEmpty else { throw Errore.nonConfigurato }
        guard let url = URL(string: base.hasSuffix("/") ? base + path : base + "/" + path) else {
            throw Errore.indirizzoNonValido
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            // Rete, DNS, connessione rifiutata: il servizio c'è in configurazione
            // ma non risponde — caso diverso dal non averlo ancora installato.
            throw Errore.nonRaggiungibile((error as NSError).localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Errore.rispostaKO((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    /// True se l'indirizzo del servizio è stato inserito nelle Connessioni API.
    /// Serve alla UI per capire se ha senso offrire il bottone "Collega".
    func configurato() async -> Bool {
        try? await ensureConfig()
        return !(base ?? "").isEmpty && !(token ?? "").isEmpty
    }

    func stato(slug: String) async throws -> Stato {
        try JSONDecoder().decode(Stato.self, from: await request("qr/\(slug)"))
    }

    /// Scollega il numero: logout da WhatsApp e credenziali cancellate sul
    /// server. Dopo, la sessione riparte e genera un QR nuovo.
    func scollega(slug: String) async throws {
        _ = try await request("scollega/\(slug)", method: "POST")
    }

    func riavvia(slug: String) async throws {
        _ = try await request("restart/\(slug)", method: "POST")
    }

    /// Conferma una visita: il servizio manda al cliente il messaggio definitivo
    /// nella sua lingua e aggiorna lo stato. Passa da qui e non dal database
    /// diretto, perché la conferma senza avviso al cliente non serve a nulla.
    func confermaVisita(id: String) async throws {
        _ = try await request("conferma-visita/\(id)", method: "POST")
    }

    /// Scheda tecnica in PDF: la stessa che il cliente riceve dopo la conferma
    /// di una visita. La genera il servizio, non l'app, perché servono i
    /// riquadri della mappa, il font cinese e la cache delle traduzioni.
    ///
    /// Timeout largo di proposito: al primo PDF di un immobile le quattro
    /// traduzioni vanno generate e da sole prendono una trentina di secondi.
    /// Dalla seconda volta sono in cache e la risposta arriva in meno di uno.
    func schedaPDF(proprietaId: String, agenzia: [String: Any] = [:]) async throws -> Data {
        try await request("scheda-pdf/\(proprietaId)", method: "POST",
                          body: ["agenzia": agenzia], timeout: 120)
    }

    func invia(slug: String, jid: String, testo: String, conversationId: String) async throws {
        _ = try await request("send/\(slug)", method: "POST",
                              body: ["jid": jid, "text": testo, "conversation_id": conversationId])
    }
}
