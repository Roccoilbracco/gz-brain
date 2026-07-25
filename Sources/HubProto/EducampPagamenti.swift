import SwiftUI

// ============================================================================
// Educamp — chi ha pagato e chi no.
// I movimenti di cassa non hanno un campo «ospite»: l'unico aggancio è la
// descrizione scritta a mano («Bonifico — Elias Fiore (Educamp agosto)»).
// Qui si ricostruisce l'abbinamento leggendo quella descrizione, si spalma
// l'incassato sui mesi dell'ospite e si dice, riga per riga, quanto manca.
// Niente si salva a database: si ricalcola a ogni caricamento, così basta
// aggiungere un movimento perché la tabella Educamp si aggiorni da sola.
// ============================================================================

/// Quattro stati, non due: qui quasi nessuno è moroso davvero. Gli ospiti
/// pagano l'affitto puntuali e le utenze arrivano dopo, quindi «ha pagato
/// l'affitto, mancano le utenze» va distinto sia da «pagato tutto» sia da
/// «non ha versato niente», altrimenti la tabella sarebbe tutta ambra.
enum StatoPagamento { case pagato, affittoOk, acconto, nulla }

/// Esito per una riga ospite-mese: quanto è arrivato e da quali movimenti.
struct EducampSaldoRiga {
    var pagato_cents: Int = 0
    var dovuto_affitto_cents: Int = 0
    var dovuto_utenze_cents: Int = 0
    /// Movimenti che hanno contribuito: (data, descrizione, quota su questa riga)
    var fonti: [(data: String, desc: String, quota: Int)] = []

    var dovuto_cents: Int { dovuto_affitto_cents + dovuto_utenze_cents }
    var residuo: Int { max(0, dovuto_cents - pagato_cents) }
    /// Quello che arriva copre prima l'affitto e poi le utenze: è l'ordine in
    /// cui si chiedono i soldi, e rende leggibile un versamento parziale.
    var pagato_affitto: Int { min(pagato_cents, dovuto_affitto_cents) }
    var pagato_utenze: Int { max(0, pagato_cents - dovuto_affitto_cents) }
    var residuo_affitto: Int { max(0, dovuto_affitto_cents - pagato_affitto) }
    var residuo_utenze: Int { max(0, dovuto_utenze_cents - pagato_utenze) }

    /// Un euro di tolleranza: gli arrotondamenti del mese a 30 giorni non devono
    /// far sembrare moroso chi ha pagato tutto.
    var stato: StatoPagamento {
        if dovuto_cents <= 0 { return .nulla }
        if residuo <= 100 { return .pagato }
        if pagato_cents <= 0 { return .nulla }
        return residuo_affitto <= 100 ? .affittoOk : .acconto
    }
}

/// Movimento che parla di Educamp ma di cui non si capisce l'ospite: va
/// mostrato, altrimenti sono soldi incassati che spariscono dal conto.
struct EducampMovNonAbbinato: Identifiable {
    let id: String
    let data: String
    let desc: String
    let importo: Int
}

// ── Normalizzazione testo ───────────────────────────────────────────────────
// I nomi turchi e spagnoli arrivano con segni diversi a seconda di chi scrive
// («Şerife» / «Serife», «Işık» / «Isik», «Lucía» / «Lucia»): si confronta tutto
// senza accenti, minuscolo, spezzato in parole.
private func eduFold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "İ", with: "i")
        .lowercased()
}
private func eduParole(_ s: String) -> [String] {
    eduFold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
}

private let EDU_MESI: [(String, Int)] = [
    ("gennaio", 1), ("febbraio", 2), ("marzo", 3), ("aprile", 4), ("maggio", 5), ("giugno", 6),
    ("luglio", 7), ("agosto", 8), ("settembre", 9), ("ottobre", 10), ("novembre", 11), ("dicembre", 12),
]

@MainActor
enum EducampPagamenti {

    /// Abbina i movimenti alle righe ospite-mese.
    /// - Parameters:
    ///   - righe: le righe del calcolo mensile (una per ospite e mese)
    ///   - movimenti: tutti i movimenti di tesoreria (si filtrano qui dentro)
    /// - Returns: saldo per chiave "mese|ospite" + i movimenti rimasti orfani
    static func calcola(righe: [EducampRiga], movimenti: [TesMovimento])
        -> (saldi: [String: EducampSaldoRiga], orfani: [EducampMovNonAbbinato]) {

        var saldi: [String: EducampSaldoRiga] = [:]
        for r in righe {
            // L'affitto si ricava per differenza dal totale della riga, non da
            // lordo_cents: così la somma dei due pezzi è sempre il numero che
            // la tabella mostra nella colonna «TOT. OSPITE».
            let k = chiave(mese: r.mese, ospite: r.ospite)
            saldi[k, default: EducampSaldoRiga()].dovuto_affitto_cents += max(0, r.totale_ospite_cents - r.utenze_cents)
            saldi[k]?.dovuto_utenze_cents += min(r.utenze_cents, r.totale_ospite_cents)
        }

        // Nomi degli ospiti → parole riconoscibili. Le parole di 3 lettere o
        // meno si scartano: «Nur», «Ünal» abbreviati creerebbero falsi positivi.
        let ospiti = Array(Set(righe.map { $0.ospite }))
        var paroleOspite: [String: Set<String>] = [:]
        for o in ospiti { paroleOspite[o] = Set(eduParole(o).filter { $0.count >= 4 }) }

        // Solo le entrate Educamp: le uscite e gli altri incassi non c'entrano.
        let incassi = movimenti
            .filter { $0.tipo == "entrata" && ($0.categoria ?? "") == "educamp" }
            .sorted { $0.data < $1.data }

        // Mesi disponibili per ciascun ospite, in ordine: l'incasso senza mese
        // scritto si applica al più vecchio non saldato (come fa un estratto).
        var mesiOspite: [String: [String]] = [:]
        for o in ospiti {
            mesiOspite[o] = righe.filter { $0.ospite == o }.map { $0.mese }.sorted()
        }

        var orfani: [EducampMovNonAbbinato] = []

        for m in incassi {
            let desc = m.descrizione ?? ""
            let parole = Set(eduParole(desc))
            // Un movimento può riguardare più persone: «Fabiana e Lucía».
            let coinvolti = ospiti.filter { o in !(paroleOspite[o] ?? []).isDisjoint(with: parole) }
            if coinvolti.isEmpty {
                orfani.append(EducampMovNonAbbinato(id: m.id, data: m.data, desc: desc.isEmpty ? "(senza descrizione)" : desc,
                                                    importo: m.importo_cents))
                continue
            }
            // Mese scritto nella descrizione, se c'è: «Educamp agosto».
            let meseCitato = EDU_MESI.first { parole.contains($0.0) }?.1

            // Pagamento condiviso: si divide in proporzione a quanto ciascuno
            // deve ancora, così chi ha il conto più alto assorbe la quota maggiore.
            let residui = coinvolti.map { o -> Int in
                (mesiOspite[o] ?? []).reduce(0) { $0 + (saldi[chiave(mese: $1, ospite: o)]?.residuo ?? 0) }
            }
            let totResidui = residui.reduce(0, +)
            var quote: [Int] = []
            if coinvolti.count == 1 {
                quote = [m.importo_cents]
            } else if totResidui > 0 {
                quote = residui.map { Int((Double(m.importo_cents) * Double($0) / Double(totResidui)).rounded()) }
                // l'arrotondamento non deve creare o bruciare centesimi
                let diff = m.importo_cents - quote.reduce(0, +)
                if let i = quote.indices.max(by: { quote[$0] < quote[$1] }) { quote[i] += diff }
            } else {
                let q = m.importo_cents / coinvolti.count
                quote = Array(repeating: q, count: coinvolti.count)
                quote[0] += m.importo_cents - q * coinvolti.count
            }

            for (o, quota) in zip(coinvolti, quote) where quota > 0 {
                applica(quota, aOspite: o, mesi: mesiOspite[o] ?? [], meseCitato: meseCitato,
                        mov: m, desc: desc, saldi: &saldi)
            }
        }
        return (saldi, orfani)
    }

    static func chiave(mese: String, ospite: String) -> String { "\(mese)|\(ospite)" }

    /// Applica una somma ai mesi di un ospite: prima il mese citato nella
    /// descrizione, poi a cascata dal più vecchio scoperto. L'eccedenza resta
    /// sull'ultimo mese, così si vede subito se qualcuno ha pagato di più.
    private static func applica(_ importo: Int, aOspite ospite: String, mesi: [String], meseCitato: Int?,
                                mov: TesMovimento, desc: String, saldi: inout [String: EducampSaldoRiga]) {
        var resto = importo
        var ordine = mesi
        if let mc = meseCitato, let idx = mesi.firstIndex(where: { Int($0.suffix(2)) == mc }) {
            // il mese scritto passa davanti, gli altri restano in coda
            ordine = [mesi[idx]] + mesi.enumerated().filter { $0.offset != idx }.map { $0.element }
        }
        for mese in ordine where resto > 0 {
            let k = chiave(mese: mese, ospite: ospite)
            guard var s = saldi[k] else { continue }
            let spazio = s.residuo
            guard spazio > 0 else { continue }
            let q = min(spazio, resto)
            s.pagato_cents += q
            s.fonti.append((data: mov.data, desc: desc, quota: q))
            saldi[k] = s
            resto -= q
        }
        // Resto non collocabile (ha pagato più del dovuto): sull'ultimo mese,
        // così il totale incassato torna con la cassa.
        if resto > 0, let ultimo = ordine.last {
            let k = chiave(mese: ultimo, ospite: ospite)
            if var s = saldi[k] {
                s.pagato_cents += resto
                s.fonti.append((data: mov.data, desc: desc, quota: resto))
                saldi[k] = s
            }
        }
    }
}

// ── Pastiglia di stato: il colpo d'occhio richiesto in tabella ──────────────
struct EducampStatoIcona: View {
    let stato: StatoPagamento
    var body: some View {
        switch stato {
        case .pagato:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .bold))
                .foregroundStyle(PSE.pos)
        case .affittoOk:   // affitto incassato, restano le utenze: cerchio vuoto verde
            Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PSE.pos.opacity(0.75))
        case .acconto:
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 12, weight: .bold))
                .foregroundStyle(PSE.warn)
        case .nulla:
            Image(systemName: "circle").font(.system(size: 11, weight: .regular))
                .foregroundStyle(PSE.faint)
        }
    }
}
