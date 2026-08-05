import SwiftUI

// ============================================================================
// Chiusura mensile — il controllo che impedisce all'archivio di ripetersi
//
// L'archivio 2024-2026 è arrivato a luglio 2026 senza 61 movimenti su 74 di un
// conto: nessuno li aveva mai messi, e nessuno se n'era accorto per un anno.
// Da quando Beds24 non c'è più, le prenotazioni OTA si inseriscono a mano — la
// stessa strada.
//
// Questa scheda non sincronizza niente: mette una accanto all'altra le due
// facce dello stesso mese — cosa dicono le prenotazioni e cosa dicono i conti —
// e segna quello che non torna. Mezz'ora al mese, e il buco silenzioso diventa
// impossibile.
// ============================================================================

struct ChiusuraMensile: View {
    let prenotazioni: [Prenotazione]
    let movimenti: [TesMovimento]

    @State private var mese: String = ""

    /// I mesi che hanno qualcosa dentro, dal più recente. Niente calendario:
    /// si sceglie fra quelli che esistono davvero.
    private var mesi: [String] {
        let a = prenotazioni.compactMap { $0.checkout?.prefix(7) }.map(String.init)
        let b = movimenti.map { String($0.data.prefix(7)) }
        return Array(Set(a + b)).sorted(by: >)
    }
    private var meseScelto: String { mese.isEmpty ? (mesi.first ?? "") : mese }

    /// Prenotazioni che finiscono nel mese: è il check-out che fa maturare
    /// l'incasso, non il check-in.
    private var partenze: [Prenotazione] {
        prenotazioni
            .filter { ($0.checkout ?? "").hasPrefix(meseScelto) && $0.status != "cancellata" }
            .sorted { ($0.checkout ?? "") < ($1.checkout ?? "") }
    }
    private var entrateMese: [TesMovimento] {
        movimenti.filter { $0.data.hasPrefix(meseScelto) && $0.tipo == "entrata" }
    }

    // ── Quello che non torna ────────────────────────────────────────────────
    /// Ospiti già partiti che non hanno pagato tutto.
    private var nonSaldate: [Prenotazione] {
        partenze.filter { $0.paid_cents < $0.amount_cents }
    }
    /// Soldi entrati che non hanno una prenotazione dietro. Sulle spese è
    /// normale; su un'entrata vuol dire o un incasso non collegato, o un
    /// movimento scritto a mano che raddoppia quello della prenotazione.
    private var entrateSenzaPrenotazione: [TesMovimento] {
        entrateMese.filter { $0.prenotazione_id == nil && !categoriaDiGiro($0.categoria) }
    }
    private func categoriaDiGiro(_ c: String?) -> Bool {
        let s = (c ?? "").lowercased()
        return s.hasPrefix("giro:") || ["deposito", "apporto", "debito"].contains(s)
    }

    private var attesoDaPartenze: Int { partenze.reduce(0) { $0 + $1.amount_cents } }
    private var incassatoDaPartenze: Int { partenze.reduce(0) { $0 + $1.paid_cents } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            intestazione
            HStack(spacing: 10) {
                card("PARTENZE DEL MESE", "\(partenze.count)", PSE.text)
                card("VALORE DELLE PARTENZE", eurc(attesoDaPartenze), PSE.dim)
                card("INCASSATO", eurc(incassatoDaPartenze),
                     incassatoDaPartenze >= attesoDaPartenze ? PSE.pos : PSE.warn)
                card("ANCORA DA INCASSARE", eurc(attesoDaPartenze - incassatoDaPartenze),
                     attesoDaPartenze - incassatoDaPartenze == 0 ? PSE.pos : PSE.warn)
            }

            if nonSaldate.isEmpty && entrateSenzaPrenotazione.isEmpty {
                riquadro(PSE.pos, "checkmark.seal.fill",
                         "Il mese torna: ogni ospite partito ha pagato, e ogni euro entrato ha una prenotazione dietro.")
            }

            if !nonSaldate.isEmpty {
                sezione("PARTITI SENZA AVER PAGATO TUTTO", PSE.warn) {
                    riga(nonSaldate.map {
                        ($0.checkout ?? "", $0.guest_name ?? "—",
                         "\($0.struttura ?? "") · \($0.camera ?? "")",
                         $0.amount_cents - $0.paid_cents, PSE.warn)
                    })
                }
            }

            if !entrateSenzaPrenotazione.isEmpty {
                sezione("ENTRATE SENZA UNA PRENOTAZIONE DIETRO", PSE.accent) {
                    riga(entrateSenzaPrenotazione.map {
                        ($0.data, $0.descrizione ?? "—", $0.categoria ?? "—",
                         $0.importo_cents, PSE.accent)
                    })
                }
                Text("Se una di queste è l'incasso di un soggiorno, va collegata alla prenotazione invece che scritta a mano: così com'è, il soldo rischia di comparire due volte.")
                    .font(.system(size: 11)).foregroundStyle(PSE.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sezione("LE CARTE DEL MESE", PSE.faint) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("L'estratto conto della banca e il riepilogo pagamenti di Booking del mese. Servono a chiudere il cerchio: gli accrediti sull'estratto devono ritrovarsi tutti fra le partenze qui sopra. È il controllo che all'archivio è mancato per un anno.")
                        .font(.system(size: 11.5)).foregroundStyle(PSE.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    AllegatiBox(store: AllegatiStore(entita: .dossier,
                                                     entitaId: uuidDelMese(meseScelto)),
                                titolo: "ESTRATTI E REPORT DI \(meseScelto)")
                        .id(meseScelto)
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var intestazione: some View {
        HStack(spacing: 10) {
            Text("CHIUSURA MENSILE").font(.system(size: 9.5, weight: .heavy)).tracking(1)
                .foregroundStyle(PSE.faint)
            PSESegmented(items: mesi.prefix(8).map { ($0, etichetta($0)) },
                         selection: Binding(get: { meseScelto }, set: { mese = $0 }))
            Spacer(minLength: 0)
        }
    }

    private func etichetta(_ m: String) -> String {
        let mesi = ["", "gen", "feb", "mar", "apr", "mag", "giu",
                    "lug", "ago", "set", "ott", "nov", "dic"]
        let p = m.split(separator: "-")
        guard p.count == 2, let n = Int(p[1]), n >= 1, n <= 12 else { return m }
        return "\(mesi[n]) \(p[0].suffix(2))"
    }

    private func riquadro(_ colore: Color, _ icona: String, _ testo: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icona).font(.system(size: 11)).foregroundStyle(colore)
            Text(testo).font(.system(size: 11.5)).foregroundStyle(PSE.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(colore.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(colore.opacity(0.28), lineWidth: 1))
    }

    private func sezione<C: View>(_ t: String, _ c: Color,
                                  @ViewBuilder _ contenuto: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(c)
            contenuto()
        }
    }

    private func riga(_ voci: [(String, String, String, Int, Color)]) -> some View {
        VStack(spacing: 0) {
            ForEach(voci.indices, id: \.self) { i in
                if i > 0 { Divider().overlay(PSE.line) }
                HStack(spacing: 10) {
                    Text(voci[i].0).font(.system(size: 11.5)).foregroundStyle(PSE.dim)
                        .monospacedDigit().frame(width: 92, alignment: .leading)
                    Text(voci[i].1).font(.system(size: 11.5)).foregroundStyle(PSE.text)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(voci[i].2).font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                        .lineLimit(1).frame(width: 190, alignment: .leading)
                    Text(eurc(voci[i].3)).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(voci[i].4).monospacedDigit()
                        .frame(width: 96, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 11).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(PSE.line, lineWidth: 1))
    }

    private func card(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(v).font(.system(size: 16, weight: .bold)).foregroundStyle(c).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }
}

/// Un uuid stabile per il fascicolo di un mese: sempre lo stesso per lo stesso
/// mese, così gli allegati si ritrovano. `entita_id` è una colonna uuid e una
/// sigla parlante non ci entrerebbe.
func uuidDelMese(_ mese: String) -> String {
    // «2026-08» → 202608, che riempie le prime sei cifre dell'ultimo gruppo.
    let cifre = String(mese.filter(\.isNumber).prefix(6))
    let coda = cifre.padding(toLength: 12, withPad: "0", startingAt: 0)
    return "c1050000-0000-4000-8000-\(coda)"
}
