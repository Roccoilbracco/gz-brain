import SwiftUI

// ============================================================================
// Il racconto di una scheda — passi numerati, scritti e correggibili dall'app
//
// Serve dove i numeri da soli non bastano: come funziona la contabilità, o
// perché una riga dell'archivio è marcata «doppione». Sta in `storico_racconto`
// e non nel codice, così si corregge senza ricompilare — e chi legge fra sei
// mesi trova la spiegazione accanto ai numeri, non in una chat.
//
// Una scheda per `scheda`: "tesoreria" è la guida, "gioia" la ricostruzione del
// conto di Massimo.
// ============================================================================

struct PassoRacconto: Identifiable, Decodable, Equatable {
    let id: String
    var scheda: String
    var ordine: Int
    var titolo: String
    var testo: String
}

extension HubAPI {
    static func listRacconto(_ scheda: String) async throws -> [PassoRacconto] {
        try await sb.fetch("storico_racconto?select=*&scheda=eq.\(scheda)&order=ordine.asc&limit=200")
    }
    @discardableResult
    static func creaPasso(_ f: [String: Any?]) async throws -> PassoRacconto {
        try await sb.insertReturning("storico_racconto", body: f)
    }
    static func salvaPasso(id: String, _ f: [String: Any?]) async throws {
        try await sb.mutate("storico_racconto?id=eq.\(id)", method: "PATCH", body: f)
    }
    static func cancellaPasso(id: String) async throws {
        try await sb.mutate("storico_racconto?id=eq.\(id)", method: "DELETE")
    }
}

/// I passi di una scheda, in lettura e in modifica. `intestazione` a `nil` toglie
/// la riga di titolo: serve quando la scheda è già una pagina sua.
struct RaccontoBox: View {
    let scheda: String
    var intestazione: String? = nil
    var sottotitolo: String = ""
    /// Aperto la prima volta. Nelle pagine dedicate conviene lasciarlo aperto.
    @State var aperto: Bool = true

    @State private var passi: [PassoRacconto] = []
    @State private var modifica = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = intestazione {
                HStack(spacing: 10) {
                    Button { withAnimation(.easeInOut(duration: 0.18)) { aperto.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: aperto ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(PSE.faint)
                            Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1)
                                .foregroundStyle(PSE.faint)
                            if !sottotitolo.isEmpty {
                                Text(sottotitolo).font(.system(size: 10.5))
                                    .foregroundStyle(PSE.faint.opacity(0.75))
                            }
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    if aperto { comandi }
                }
            } else if aperto {
                HStack { Spacer(minLength: 0); comandi }.padding(.bottom, 8)
            }

            if aperto {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(passi.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider().overlay(PSE.line) }
                        if modifica { rigaModifica(i) } else { riga(i + 1, p.titolo, p.testo) }
                    }
                    if passi.isEmpty {
                        Text("Nessun passo scritto.").font(.system(size: 11.5))
                            .foregroundStyle(PSE.faint).padding(14)
                    }
                }
                .padding(.top, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
                .padding(.top, intestazione == nil ? 0 : 8)
            }
        }
        .task { passi = (try? await HubAPI.listRacconto(scheda)) ?? [] }
    }

    private var comandi: some View {
        HStack(spacing: 8) {
            if modifica {
                Button { Task { await aggiungi() } } label: {
                    Label("Aggiungi passo", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PSE.dim)
                }.buttonStyle(.plain)
                Button { Task { await salva() } } label: {
                    Text("Fatto").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(PSE.accent.opacity(0.9)))
                }.buttonStyle(.plain)
            } else {
                Button { modifica = true } label: {
                    Label("Modifica", systemImage: "pencil")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PSE.dim)
                }.buttonStyle(.plain)
            }
        }
    }

    private func riga(_ n: Int, _ titolo: String, _ testo: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(n)").font(.system(size: 10, weight: .heavy)).foregroundStyle(PSE.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(PSE.accent.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(titolo).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.text)
                Text(.init(testo)).font(.system(size: 11.5)).foregroundStyle(PSE.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    /// In modifica: titolo, testo e i comandi per spostare o togliere. Nel testo
    /// il grassetto si scrive con **due asterischi**, come nelle note.
    private func rigaModifica(_ i: Int) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(i + 1)").font(.system(size: 10, weight: .heavy)).foregroundStyle(PSE.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(PSE.accent.opacity(0.15)))
            VStack(alignment: .leading, spacing: 6) {
                TextField("Titolo del passo", text: $passi[i].titolo)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, weight: .semibold))
                TextEditor(text: $passi[i].testo)
                    .font(.system(size: 11.5)).foregroundStyle(PSE.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 76).padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PSE.line, lineWidth: 1))
            }
            VStack(spacing: 5) {
                bottoncino("arrow.up", PSE.faint) { sposta(i, -1) }
                bottoncino("arrow.down", PSE.faint) { sposta(i, 1) }
                bottoncino("trash", PSE.neg) { Task { await cancella(i) } }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func bottoncino(_ icona: String, _ colore: Color,
                            _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Image(systemName: icona).font(.system(size: 10, weight: .bold))
                .foregroundStyle(colore).frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func sposta(_ i: Int, _ verso: Int) {
        let j = i + verso
        guard passi.indices.contains(j) else { return }
        passi.swapAt(i, j)
    }

    private func aggiungi() async {
        let n = (passi.map(\.ordine).max() ?? 0) + 1
        if let p = try? await HubAPI.creaPasso(["scheda": scheda, "ordine": n,
                                                "titolo": "Nuovo passo", "testo": ""]) {
            passi.append(p)
        }
    }

    private func cancella(_ i: Int) async {
        guard passi.indices.contains(i) else { return }
        try? await HubAPI.cancellaPasso(id: passi[i].id)
        passi.remove(at: i)
    }

    /// Salva tutto in blocco: l'ordine lo detta la posizione in elenco, così
    /// spostare un passo con le frecce basta e avanza.
    private func salva() async {
        for (i, p) in passi.enumerated() {
            try? await HubAPI.salvaPasso(id: p.id,
                                         ["ordine": i + 1, "titolo": p.titolo, "testo": p.testo])
        }
        modifica = false
        passi = (try? await HubAPI.listRacconto(scheda)) ?? passi
    }
}
