import SwiftUI

// ── Quadratura contabile ─────────────────────────────────────────────────────
// Ogni notte alle 03:40 il database si controlla da solo (cron
// `quadratura-notturna` → `public.quadratura_notturna()`) e scrive in
// `public.quadrature` una riga per ogni cosa che non torna.
//
// Questa vista è il motivo per cui quel controllo serve a qualcosa: un report
// che nessuno apre è come non averlo. Mostra solo l'ultima esecuzione — le
// precedenti restano in tabella per storia, ma qui interessa lo stato di adesso.

struct Quadratura: Identifiable, Decodable, Equatable {
    let id: String
    var eseguita_il: String
    var controllo: String
    var gravita: String            // errore | attenzione | info
    var oggetto: String?
    var dettaglio: String?
    var importo_cents: Int?
    var data_riferimento: String?
}

extension HubAPI {
    /// Le righe dell'ultima esecuzione. Si scarica un blocco recente e si tiene
    /// solo il gruppo con il timestamp più alto: le esecuzioni sono atomiche,
    /// quindi tutte le righe di una nottata condividono lo stesso `eseguita_il`.
    static func listQuadraturaUltima() async throws -> [Quadratura] {
        let tutte: [Quadratura] = try await sb.fetch(
            "quadrature?select=*&order=eseguita_il.desc&limit=400")
        guard let ultima = tutte.first?.eseguita_il else { return [] }
        return tutte.filter { $0.eseguita_il == ultima }
    }

    /// Rilancia i controlli adesso, senza aspettare la notte.
    @discardableResult
    static func eseguiQuadratura() async throws -> Int {
        let d = try await sb.rpc("quadratura_notturna")
        return Int(String(data: d, encoding: .utf8) ?? "") ?? 0
    }
}

struct QuadraturaView: View {
    @ObservedObject private var nascosti = NumeriCoperti.shared
    @State private var righe: [Quadratura] = []
    @State private var loading = true
    @State private var inCorso = false
    @State private var errore: String?

    private var errori: [Quadratura] { righe.filter { $0.gravita == "errore" } }
    private var attenzioni: [Quadratura] { righe.filter { $0.gravita == "attenzione" } }

    /// Somma di quello che le anomalie di livello «errore» valgono in denaro:
    /// è il numero che dice se la nottata va guardata subito o dopo il caffè.
    private var soldiInBallo: Int { errori.compactMap(\.importo_cents).reduce(0, +) }

    private var quando: String {
        guard let iso = righe.first?.eseguita_il else { return "—" }
        let inp = ISO8601DateFormatter()
        inp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = inp.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMMM 'alle' HH:mm"
        return f.string(from: d)
    }

    var body: some View {
        ContenitoreScorrevole(scorre: true) {
            VStack(alignment: .leading, spacing: 14) {
                intestazione

                if loading {
                    HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 40)
                } else if let errore {
                    SectionCard(title: "Impossibile leggere la quadratura", icon: "exclamationmark.triangle") {
                        Text(errore).font(.system(size: 12)).foregroundStyle(PSE.dim)
                    }
                } else if righe.isEmpty {
                    tuttoTorna
                } else {
                    if !errori.isEmpty {
                        gruppo("Da sistemare", righe: errori, tinta: PSE.neg, icona: "exclamationmark.octagon")
                    }
                    if !attenzioni.isEmpty {
                        gruppo("Da guardare", righe: attenzioni, tinta: PSE.warn, icona: "eye")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .task { await carica() }
    }

    private var intestazione: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quadratura contabile")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(PSE.ink)
                Text("ultimo controllo: \(quando)")
                    .font(.system(size: 11)).foregroundStyle(PSE.faint)
            }
            Spacer(minLength: 8)

            if !errori.isEmpty {
                StatusPill(label: "\(errori.count) da sistemare", tint: PSE.neg)
            }
            if !attenzioni.isEmpty {
                StatusPill(label: "\(attenzioni.count) da guardare", tint: PSE.warn)
            }
            if soldiInBallo > 0 {
                StatusPill(label: nascosti.attivo ? "•••" : euro(soldiInBallo), tint: PSE.neg)
            }

            GhostButton(label: inCorso ? "Controllo…" : "Ricontrolla", icon: "arrow.clockwise") {
                Task { await esegui() }
            }
            .disabled(inCorso)
            .opacity(inCorso ? 0.6 : 1)
        }
    }

    private var tuttoTorna: some View {
        SectionCard(title: "Tutto torna", icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nessuna anomalia nell'ultimo controllo.")
                    .font(.system(size: 12.5)).foregroundStyle(PSE.text)
                Text("Vengono verificati: catena dei saldi di ogni conto, soggiorni finiti non saldati o non passati in cassa, movimenti senza importo, doppioni e bollette aperte.")
                    .font(.system(size: 11)).foregroundStyle(PSE.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func gruppo(_ titolo: String, righe gruppo: [Quadratura], tinta: Color, icona: String) -> some View {
        SectionCard(title: titolo, count: gruppo.count, icon: icona) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(gruppo.enumerated()), id: \.element.id) { idx, r in
                    if idx > 0 { Rectangle().fill(PSE.line).frame(height: 1).padding(.vertical, 9) }
                    riga(r, tinta: tinta)
                }
            }
        }
    }

    private func riga(_ r: Quadratura, tinta: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tinta).frame(width: 6, height: 6).padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(r.controllo)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink)
                    if let o = r.oggetto, !o.isEmpty {
                        Text(o).font(.system(size: 11)).foregroundStyle(PSE.dim)
                    }
                }
                if let d = r.dettaglio, !d.isEmpty {
                    Text(d)
                        .font(.system(size: 11.5)).foregroundStyle(PSE.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if let c = r.importo_cents, c != 0 {
                    Text(nascosti.attivo ? "•••" : euro(c))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(tinta)
                }
                if let d = r.data_riferimento {
                    Text(giornoBreve(d)).font(.system(size: 10)).foregroundStyle(PSE.faint)
                }
            }
        }
    }

    // ── Dati ─────────────────────────────────────────────────────────────────
    private func carica() async {
        loading = true; errore = nil
        do { righe = try await HubAPI.listQuadraturaUltima() }
        catch { errore = error.localizedDescription }
        loading = false
    }

    private func esegui() async {
        inCorso = true
        do {
            _ = try await HubAPI.eseguiQuadratura()
            righe = try await HubAPI.listQuadraturaUltima()
            errore = nil
        } catch { errore = error.localizedDescription }
        inCorso = false
    }

    // ── Formato ──────────────────────────────────────────────────────────────
    private func euro(_ cents: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "it_IT")
        f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return (f.string(from: NSNumber(value: Double(cents) / 100)) ?? "0") + " €"
    }

    private func giornoBreve(_ iso: String) -> String {
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3 else { return iso }
        return "\(p[2])/\(p[1])/\(String(p[0]).suffix(2))"
    }
}
