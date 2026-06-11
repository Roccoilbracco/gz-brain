import Foundation

struct Project: Decodable, Identifiable {
    let id: String
    let slug: String
    let name: String
    let description: String?
    let status: String
    let hue: Double
    let sort_order: Int?
}

struct HubEvent: Decodable, Identifiable {
    let id: Int64
    let project_id: String?
    let kind: String
    let message: String?
    let created_at: String
}

/// Conta eventi per giorno sugli ultimi `days` giorni. Indice 0 = giorno più vecchio.
/// (port di bucketEventsByDay in lib/helpers.ts)
func bucketEventsByDay(_ events: [HubEvent], days: Int, today: Date = Date()) -> [Int] {
    var buckets = [Int](repeating: 0, count: days)
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: today) ?? today
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter()
    for e in events {
        guard let d = iso.date(from: e.created_at) ?? isoPlain.date(from: e.created_at) else { continue }
        let diff = Int(floor(end.timeIntervalSince(d) / 86_400))
        if diff >= 0 && diff < days { buckets[days - 1 - diff] += 1 }
    }
    return buckets
}
