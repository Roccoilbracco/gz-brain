import Foundation

// ─── Entità Supabase (port di lib/projects.ts e lib/leads.ts) ───

struct Project: Decodable, Identifiable, Equatable {
    let id: String
    var slug: String
    var name: String
    var description: String?
    var status: String
    var hue: Double
    var notes: String?
    var local_path: String?
    var ssh_host: String?
    var ssh_path: String?
    var sort_order: Int?
    var created_at: String?
    var updated_at: String?
}

struct HubEvent: Decodable, Identifiable {
    let id: Int64
    let project_id: String?
    let kind: String
    let message: String?
    let created_at: String
}

struct Lead: Decodable, Identifiable {
    let id: String
    let project_id: String
    let ragione_sociale: String
    let piva: String?
    let id_arera: String?
    let tipo_servizio: String?
    let comune: String?
    let provincia: String?
    let indirizzo: String?
    let dominio: String?
    let sito_web: String?
    let email_info: String?
    let email_commerciale: String?
    let telefoni: String?
    let gruppo: String?
    let natura_giuridica: String?
    let settori: String?
    let latitude: Double?
    let longitude: Double?
    let email: String?
    var status: String
    let created_at: String
    let updated_at: String
    let whatsapp: String?
    let telefono: String?
    let categoria: String?
    let commodity: String?
    let macroarea: String?

    var siteURL: String? { sito_web ?? dominio.map { "https://\($0)" } }
    var emailAddr: String? { email ?? email_info ?? email_commerciale }
    var phoneNum: String? { telefono ?? whatsapp ?? telefoni }
}

struct LeadContact: Decodable, Identifiable {
    let id: String
    let lead_id: String
    let full_name: String?
    let role: String?
    let linkedin_url: String?
    let is_legal_rep: Bool?
    let created_at: String
}

struct LeadNote: Decodable, Identifiable {
    let id: String
    let lead_id: String
    let body: String
    let created_at: String
}

struct LeadActivity: Decodable, Identifiable {
    let id: String
    let lead_id: String
    let event_type: String
    let from_value: String?
    let to_value: String?
    let created_at: String
}

let LEAD_STATUSES = [
    "da_contattare", "call_fissata", "call_effettuata", "demo_fissata",
    "demo_effettuata", "proposta_inviata", "negoziazione", "chiuso_vinto", "perso",
]

let PROJECT_STATUSES = ["live", "dev", "setup", "pausa"]

let STATUS_LABELS: [String: String] = [
    "da_contattare": "Da contattare", "call_fissata": "Call fissata",
    "call_effettuata": "Call effettuata", "demo_fissata": "Demo fissata",
    "demo_effettuata": "Demo effettuata", "proposta_inviata": "Proposta inviata",
    "negoziazione": "Negoziazione", "chiuso_vinto": "Cliente", "perso": "Perso",
]

// Temperatura per status (hot = ambra, cold = blu) — come TEMP in ProgettoDettaglio.tsx
let LEAD_TEMP: [String: (temp: Int, hot: Bool)] = [
    "da_contattare": (24, false), "call_fissata": (40, false), "call_effettuata": (52, false),
    "demo_fissata": (66, true), "demo_effettuata": (74, true), "proposta_inviata": (85, true),
    "negoziazione": (90, true), "chiuso_vinto": (98, true),
]

// ─── Date helpers ───

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Date? {
    // PostgREST emette timestamp con o senza frazioni, a volte senza timezone
    isoFrac.date(from: s) ?? isoPlain.date(from: s)
        ?? isoFrac.date(from: s + "Z") ?? isoPlain.date(from: s + "Z")
}

func isoNowString(addingDays days: Int = 0) -> String {
    isoFrac.string(from: Date().addingTimeInterval(Double(days) * 86_400))
}

/// Cartella temp dedicata all'app (0700, svuotata all'uscita): i PDF di fatture
/// ed estratti non restano nella temp condivisa con nomi prevedibili.
func appTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unvrs-brain", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return dir
}

func formatDateIT(_ s: String, time: Bool = true) -> String {
    guard let d = parseISO(s) else { return s }
    let f = DateFormatter()
    f.locale = Locale(identifier: "it_IT")
    f.dateFormat = time ? "dd/MM/yy, HH:mm" : "dd/MM"
    return f.string(from: d)
}

/// Conta date ISO per giorno sugli ultimi `days` giorni. Indice 0 = giorno più vecchio.
func bucketISODatesByDay(_ isoDates: [String?], days: Int, today: Date = Date()) -> [Int] {
    var buckets = [Int](repeating: 0, count: days)
    let cal = Calendar.current
    let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: today) ?? today
    for s in isoDates {
        guard let s, let d = parseISO(s) else { continue }
        let diff = Int(floor(end.timeIntervalSince(d) / 86_400))
        if diff >= 0 && diff < days { buckets[days - 1 - diff] += 1 }
    }
    return buckets
}

/// (port di bucketEventsByDay in lib/helpers.ts)
func bucketEventsByDay(_ events: [HubEvent], days: Int, today: Date = Date()) -> [Int] {
    bucketISODatesByDay(events.map { $0.created_at }, days: days, today: today)
}

/// Bucket tipo servizio → Dual/Elettrico/Gas (port di groupTipoServizio)
func groupTipoServizio(_ counts: [String: Int]) -> (dual: Int, elet: Int, gas: Int, total: Int) {
    var dual = 0, elet = 0, gas = 0
    for (k, v) in counts {
        let kl = k.lowercased()
        if kl.contains("dual") { dual += v }
        else if kl.contains("elett") || (kl.contains("ele") && !kl.contains("gas")) { elet += v }
        else { gas += v }
    }
    return (dual, elet, gas, dual + elet + gas)
}

func validateProject(name: String, slug: String, status: String, hue: Double) -> [String] {
    var errs: [String] = []
    if name.trimmingCharacters(in: .whitespaces).isEmpty { errs.append("Il nome è obbligatorio") }
    if slug.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == nil {
        errs.append("Slug non valido (kebab-case)")
    }
    if !PROJECT_STATUSES.contains(status) { errs.append("Stato sconosciuto") }
    if hue < 0 || hue > 360 { errs.append("Hue fuori range 0-360") }
    return errs
}
