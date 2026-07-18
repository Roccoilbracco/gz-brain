import SwiftUI

/// Riga della tabella `integrations`. Leggiamo di proposito SOLO la chiave e la
/// data: il segreto non deve mai tornare indietro dal server verso l'app, così
/// non finisce in memoria, nei log o in uno screenshot. Sappiamo se una chiave
/// è configurata, non quanto vale.
struct IntegrationKey: Decodable, Identifiable, Equatable {
    let key: String
    let updated_at: String?
    var id: String { key }
}

extension HubAPI {
    static func listIntegrationKeys() async throws -> [IntegrationKey] {
        try await sb.fetch("integrations?select=key,updated_at&order=key")
    }

    /// Upsert: `key` è la primary key, quindi merge-duplicates aggiorna il valore
    /// esistente invece di fallire con un conflitto.
    static func setIntegration(key: String, value: String) async throws {
        try await sb.mutate(
            "integrations",
            method: "POST",
            body: ["key": key, "value": value, "updated_at": isoNowString()],
            prefer: "resolution=merge-duplicates,return=minimal")
    }

    /// `key` arriva sempre dalla lista fissa `CONNESSIONI` (identificatori
    /// snake_case), mai da input libero: nessun carattere da percent-encodare.
    static func deleteIntegration(key: String) async throws {
        try await sb.mutate("integrations?key=eq.\(key)", method: "DELETE")
    }
}

/// Le connessioni che l'app sa gestire. L'elenco è fisso: `key` finisce in una
/// query, quindi non deve mai arrivare da input libero dell'utente.
private struct ConnDef: Identifiable {
    let key: String
    let label: String
    let hint: String
    let icon: String
    var id: String { key }
}

private let CONNESSIONI: [ConnDef] = [
    .init(key: "anthropic_api_key",
          label: "Anthropic (Claude)",
          hint: "Fa funzionare gli agenti WhatsApp. Da console.anthropic.com → API Keys. Inizia per sk-ant-",
          icon: "sparkles"),
    .init(key: "wa_api_token",
          label: "Ponte WhatsApp — token",
          hint: "Token che protegge il servizio Baileys su Hetzner. Inventane uno lungo e casuale.",
          icon: "message.fill"),
    .init(key: "wa_bridge_url",
          label: "Ponte WhatsApp — indirizzo",
          hint: "Dove risponde il servizio, es. https://wa.camerepse.it — serve all'app per il QR e per l'invio manuale.",
          icon: "link"),
    .init(key: "beds24_refresh_token",
          label: "Beds24",
          hint: "Sincronizza le prenotazioni OTA (Airbnb, Booking) con Camere PSE.",
          icon: "calendar"),
]

// ─── Card "Connessioni API" nelle Impostazioni ───────────────────────────────
struct ConnessioniAPICard: View {
    @State private var configurate: Set<String> = []
    @State private var aggiornate: [String: String] = [:]
    @State private var editing: String?
    @State private var draft = ""
    @State private var saving = false
    @State private var errore: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("CONNESSIONI API").font(.system(size: 10, weight: .heavy)).tracking(2)
                        .foregroundStyle(Holo.hsl(217, 90, 70))
                    Spacer()
                    IconButton(icon: "arrow.clockwise", help: "Ricarica") { Task { await load() } }
                }

                Text("Le chiavi sono salvate su Supabase e lette dai servizi al momento dell'uso. L'app non le rilegge mai: puoi solo sostituirle o rimuoverle.")
                    .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)

                if let errore {
                    Text(errore).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad))
                }

                VStack(spacing: 10) {
                    ForEach(CONNESSIONI) { c in riga(c) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(maxWidth: 700)
        .task { await load() }
    }

    @ViewBuilder
    private func riga(_ c: ConnDef) -> some View {
        let ok = configurate.contains(c.key)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: c.icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ok ? Color(hex: 0x34d399) : Holo.labelDim)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(c.label).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Holo.titleText)
                    Text(ok ? "Configurata\(aggiornate[c.key].map { " · \($0)" } ?? "")" : "Non configurata")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ok ? Color(hex: 0x9af0c5) : Holo.subDim)
                }

                Spacer(minLength: 8)

                if editing != c.key {
                    Button(ok ? "Sostituisci" : "Inserisci") {
                        draft = ""; errore = nil
                        withAnimation(.easeOut(duration: 0.15)) { editing = c.key }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Holo.hsl(210, 90, 72))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Holo.hsl(210, 90, 65).opacity(0.4), lineWidth: 1))

                    if ok {
                        IconButton(icon: "trash", help: "Rimuovi la chiave", danger: true) {
                            Task { await rimuovi(c.key) }
                        }
                    }
                }
            }

            Text(c.hint).font(.system(size: 10)).foregroundStyle(Holo.labelDim)

            if editing == c.key {
                HStack(spacing: 8) {
                    // SecureField: la chiave non è mai in chiaro sullo schermo.
                    SecureField("Incolla qui la chiave", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Holo.text)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x0d152c).opacity(0.75)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Holo.hsl(210, 90, 65).opacity(0.3), lineWidth: 1))

                    Button(saving ? "Salvo…" : "Salva") { Task { await salva(c.key) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0b1020))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Holo.hsl(150, 70, 60)))
                        .disabled(saving || draft.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Annulla") { editing = nil; draft = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Holo.subDim)
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func load() async {
        do {
            let rows = try await HubAPI.listIntegrationKeys()
            configurate = Set(rows.map(\.key))
            aggiornate = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, shortDate($0.updated_at)) })
            errore = nil
        } catch { errore = "Non riesco a leggere le connessioni: \(error.localizedDescription)" }
    }

    private func salva(_ key: String) async {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            try await HubAPI.setIntegration(key: key, value: value)
            draft = ""; editing = nil; errore = nil
            await load()
        } catch { errore = "Salvataggio fallito: \(error.localizedDescription)" }
    }

    private func rimuovi(_ key: String) async {
        do {
            try await HubAPI.deleteIntegration(key: key)
            await load()
        } catch { errore = "Rimozione fallita: \(error.localizedDescription)" }
    }

    private func shortDate(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter.flexible.date(from: iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

extension ISO8601DateFormatter {
    /// Supabase restituisce timestamp con i frazionari; il parser di default no.
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
