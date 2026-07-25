import SwiftUI

// ============================================================================
// Tutte le prenotazioni, in tabella e cercabili.
// L'elenco del giorno risponde a «chi c'è oggi»; questa tabella risponde a
// «dov'è finita la prenotazione di quel signore che aveva chiamato», che è la
// domanda per cui prima toccava scorrere il calendario giorno per giorno.
// Si scrive un pezzo di nome (o di camera, o l'importo, o una data) e la riga
// esce; cliccandola si apre lo stesso drawer del resto della pagina, da cui si
// modifica o si cancella.
// ============================================================================

private let tabYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let tabGiorno: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "dd/MM/yy"; return f }()

/// Testo confrontabile: senza accenti e in minuscolo, così «Lucía» si trova
/// scrivendo «lucia» e «Işık» scrivendo «isik».
private func tabFold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "İ", with: "i")
        .lowercased()
}

struct PrenotazioniTabella: View {
    let items: [Prenotazione]
    /// Filtro casa già scelto in cima alla pagina: la tabella lo rispetta.
    let struttura: Struttura?
    let onSelect: (Prenotazione) -> Void

    /// Un filtro solo, non due incrociati: «attive» mescolava chi è in casa
    /// adesso, chi deve ancora arrivare e chi è già partito, ed era la cosa che
    /// rendeva la lista illeggibile. Queste sei voci si escludono a vicenda e
    /// rispondono ognuna a una domanda precisa.
    enum Filtro: String, CaseIterable, Identifiable {
        case inCasa, inArrivo, daConfermare, cancellate, passate, tutto
        var id: String { rawValue }
        var label: String {
            switch self {
            case .inCasa: return "In casa"
            case .inArrivo: return "In arrivo"
            case .daConfermare: return "Da confermare"
            case .cancellate: return "Cancellate"
            case .passate: return "Passate"
            case .tutto: return "Tutto"
            }
        }
        var spiega: String {
            switch self {
            case .inCasa: return "Chi sta soggiornando oggi: arrivato e non ancora ripartito."
            case .inArrivo: return "Deve ancora arrivare."
            case .daConfermare: return "In attesa di conferma, a qualsiasi data."
            case .cancellate: return "Cancellate: restano in archivio, fuori dai conti."
            case .passate: return "Già ripartiti."
            case .tutto: return "Tutte le prenotazioni, cancellate comprese."
            }
        }
        /// Ordine più utile per ciascuna vista: chi è in casa si legge per
        /// partenza (chi libera la camera prima), il passato dal più recente.
        var ordineIniziale: (Colonna, Bool) {
            switch self {
            case .inCasa: return (.checkout, true)
            case .inArrivo, .daConfermare, .tutto: return (.checkin, true)
            case .cancellate, .passate: return (.checkin, false)
            }
        }
    }
    enum Colonna: String { case ospite, casa, checkin, checkout, notti, importo, saldo, stato }

    @State private var q = ""
    @State private var filtro: Filtro = .inCasa
    @State private var ordine: Colonna = .checkout
    @State private var crescente = true
    @FocusState private var cercaAttivo: Bool

    // larghezze colonne
    private let wCasa: CGFloat = 190, wData: CGFloat = 86, wNotti: CGFloat = 44
    private let wCanale: CGFloat = 76, wSoldi: CGFloat = 82, wStato: CGFloat = 108

    private var oggi: Date { Calendar.current.startOfDay(for: Date()) }
    private func data(_ s: String?) -> Date? { s.flatMap { tabYmd.date(from: String($0.prefix(10))) } }

    // ── selezione ────────────────────────────────────────────────────────────
    private var filtrate: [Prenotazione] { selezionate(filtro).sorted(by: prima) }
    /// Quante righe ha ciascun filtro, con la ricerca già applicata: il numero
    /// sul bottone è sempre quello che si vedrà cliccandolo.
    private func conta(_ f: Filtro) -> Int { selezionate(f).count }

    private func selezionate(_ f: Filtro) -> [Prenotazione] {
        let termini = tabFold(q).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return items.filter { b in
            if let s = struttura, b.struttura != s.rawValue { return false }
            guard passa(b, f) else { return false }
            guard !termini.isEmpty else { return true }
            // Ogni parola cercata deve comparire da qualche parte nella riga:
            // così «michele king» trova Michele in Camera King.
            let fieno = tabFold(riga(b))
            return termini.allSatisfy { fieno.contains($0) }
        }
    }
    private func passa(_ b: Prenotazione, _ f: Filtro) -> Bool {
        let annullata = b.status == "cancellata"
        let ci = data(b.checkin), co = data(b.checkout)
        switch f {
        // «In casa» si legge dalle date, non dallo stato: è chi dorme qui
        // stanotte, che lo stato sia stato aggiornato a mano o no.
        case .inCasa:       guard !annullata, let ci, let co else { return false }
                            return ci <= oggi && oggi < co
        case .inArrivo:     guard !annullata, let ci else { return false }
                            return ci > oggi
        case .daConfermare: return b.status == "in_attesa"
        case .cancellate:   return annullata
        case .passate:      guard !annullata, let co else { return false }
                            return co <= oggi
        case .tutto:        return true
        }
    }
    /// Tutto quello su cui si può cercare, in una stringa sola.
    private func riga(_ b: Prenotazione) -> String {
        var p = [b.guest_name, b.camera ?? "", Struttura.from(b.struttura).label, b.source ?? "",
                 b.guest_phone ?? "", b.guest_email ?? "", b.notes ?? "", BookingStatus.from(b.status).label]
        if let d = data(b.checkin) { p.append(tabGiorno.string(from: d)) }
        if let d = data(b.checkout) { p.append(tabGiorno.string(from: d)) }
        p.append(eur(b.amount_cents))
        p.append(String(b.amount_cents / 100))
        return p.joined(separator: " ")
    }
    private func prima(_ a: Prenotazione, _ b: Prenotazione) -> Bool {
        // A parità di valore vince sempre l'arrivo più vicino: senza questo le
        // righe uguali (tutte le «Diretto» da 70 €) si scambiavano di posto a
        // ogni ridisegno.
        func ordina<T: Comparable>(_ x: T, _ y: T) -> Bool {
            if x == y { return (a.checkin ?? "") < (b.checkin ?? "") }
            return crescente ? x < y : x > y
        }
        switch ordine {
        case .ospite:   return ordina(tabFold(a.guest_name), tabFold(b.guest_name))
        case .casa:     return ordina(a.struttura + (a.camera ?? ""), b.struttura + (b.camera ?? ""))
        case .checkin:  return ordina(a.checkin ?? "", b.checkin ?? "")
        case .checkout: return ordina(a.checkout ?? "", b.checkout ?? "")
        case .notti:    return ordina(nights(a.checkin, a.checkout) ?? 0, nights(b.checkin, b.checkout) ?? 0)
        case .importo:  return ordina(a.amount_cents, b.amount_cents)
        case .saldo:    return ordina(a.amount_cents - a.paid_cents, b.amount_cents - b.paid_cents)
        case .stato:    return ordina(pesoStato(a.status), pesoStato(b.status))
        }
    }
    /// Ordine di lettura degli stati: prima quelli che chiedono un'azione.
    private func pesoStato(_ s: String?) -> Int {
        switch BookingStatus.from(s) {
        case .in_attesa: return 0
        case .in_casa: return 1
        case .confermata: return 2
        case .partita: return 3
        case .cancellata: return 4
        }
    }

    // ── vista ────────────────────────────────────────────────────────────────
    var body: some View {
        let list = filtrate
        return VStack(alignment: .leading, spacing: 10) {
            intestazione(list)
            filtri
            if list.isEmpty {
                EmptyStateCard(icon: "magnifyingglass",
                               text: q.isEmpty ? "Nessuna prenotazione in «\(filtro.label.lowercased())»."
                                               : "Nessuna prenotazione per «\(q)» in «\(filtro.label.lowercased())». Prova con meno parole, o cambia filtro qui sopra.")
            } else {
                // Niente lista che scorre dentro la pagina che scorre: la rotella
                // finiva nella lista invece che nella pagina, e il pannello di
                // dettaglio si apriva vuoto quando la riga veniva da qui. La
                // tabella è lunga quanto le sue righe, e a tenerla corta ci
                // pensano i filtri.
                VStack(spacing: 0) {
                    testata
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                        riga(b, dispari: i.isMultiple(of: 2))
                        if i < list.count - 1 { Divider().overlay(PSE.line).padding(.leading, 14) }
                    }
                    totali(list)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func intestazione(_ list: [Prenotazione]) -> some View {
        HStack(spacing: 10) {
            Text("TUTTE LE PRENOTAZIONI").font(.system(size: 13.5, weight: .bold)).foregroundStyle(PSE.ink)
            Text("· \(list.count) di \(items.count)").font(.system(size: 11)).foregroundStyle(PSE.faint)
            Spacer()
            campoRicerca
        }
    }
    private var campoRicerca: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.faint)
            TextField("Cerca nome, camera, telefono, importo, data…", text: $q)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(PSE.ink)
                .focused($cercaAttivo)
                .frame(width: 300)
                .onSubmit { }
            if !q.isEmpty {
                Button { q = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(PSE.faint)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(PSE.surface))
        .overlay(Capsule().strokeBorder(cercaAttivo ? PSE.accent.opacity(0.7) : PSE.line, lineWidth: 1))
    }
    private var filtri: some View {
        HStack(spacing: 8) {
            ForEach(Filtro.allCases) { f in chip(f) }
            Spacer()
            Text(filtro.spiega).font(.system(size: 10.5)).foregroundStyle(PSE.faint).lineLimit(1)
        }
    }
    private func chip(_ f: Filtro) -> some View {
        let attivo = filtro == f
        let n = conta(f)
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                filtro = f
                (ordine, crescente) = f.ordineIniziale
            }
        } label: {
            HStack(spacing: 6) {
                Text(f.label).font(.system(size: 11, weight: attivo ? .bold : .medium))
                    .foregroundStyle(attivo ? PSE.ink : (n == 0 ? PSE.faint : PSE.dim))
                Text("\(n)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .foregroundStyle(attivo ? PSE.ink.opacity(0.85) : PSE.faint)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(attivo ? PSE.accent.opacity(0.75) : PSE.surface))
            .overlay(Capsule().strokeBorder(attivo ? Color.clear : PSE.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(f.spiega)
    }

    private var testata: some View {
        HStack(spacing: 10) {
            th("OSPITE", .ospite).frame(maxWidth: .infinity, alignment: .leading)
            th("CASA · CAMERA", .casa).frame(width: wCasa, alignment: .leading)
            th("ARRIVO", .checkin).frame(width: wData, alignment: .leading)
            th("PARTENZA", .checkout).frame(width: wData, alignment: .leading)
            th("NOTTI", .notti).frame(width: wNotti, alignment: .trailing)
            thFisso("CANALE").frame(width: wCanale, alignment: .leading)
            th("TOTALE", .importo).frame(width: wSoldi, alignment: .trailing)
            th("SALDO", .saldo).frame(width: wSoldi, alignment: .trailing)
            th("STATO", .stato).frame(width: wStato, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(PSE.surface)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    /// Intestazione cliccabile: ordina, e ricliccata inverte.
    private func th(_ t: String, _ c: Colonna) -> some View {
        let on = ordine == c
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                if on { crescente.toggle() } else { ordine = c; crescente = true }
            }
        } label: {
            HStack(spacing: 3) {
                Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.9)
                    .foregroundStyle(on ? PSE.ink : PSE.faint)
                Image(systemName: crescente ? "chevron.up" : "chevron.down")
                    .font(.system(size: 6.5, weight: .black)).foregroundStyle(PSE.accent)
                    .opacity(on ? 1 : 0)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func thFisso(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.9).foregroundStyle(PSE.faint)
    }

    private func riga(_ b: Prenotazione, dispari: Bool) -> some View {
        let st = BookingStatus.from(b.status)
        let str = Struttura.from(b.struttura)
        let saldo = max(0, b.amount_cents - b.paid_cents)
        let pay = payState(amount: b.amount_cents, paid: b.paid_cents)
        let annullata = st == .cancellata
        return Button { onSelect(b) } label: {
            HStack(spacing: 10) {
                Text(b.guest_name).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(annullata ? PSE.faint : PSE.ink)
                    .strikethrough(annullata, color: PSE.faint)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(hue: str.hue/360, saturation: 0.42, brightness: 0.74))
                        .frame(width: 2.5, height: 12)
                    Text([str.label, b.camera].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(PSE.dim).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(width: wCasa, alignment: .leading)
                cella(dataBreve(b.checkin)).frame(width: wData, alignment: .leading)
                cella(dataBreve(b.checkout)).frame(width: wData, alignment: .leading)
                Text(nights(b.checkin, b.checkout).map { "\($0)" } ?? "—")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(PSE.dim)
                    .frame(width: wNotti, alignment: .trailing)
                Text((b.source ?? "—").capitalized).font(.system(size: 10)).foregroundStyle(PSE.faint)
                    .lineLimit(1).frame(width: wCanale, alignment: .leading)
                Text(eur(b.amount_cents)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .foregroundStyle(annullata ? PSE.faint : PSE.text)
                    .frame(width: wSoldi, alignment: .trailing)
                // Il saldo è la colonna che dice se c'è ancora da chiedere soldi:
                // zero in verde spento, resto nel colore del pagamento.
                Text(saldo == 0 ? "saldato" : eur(saldo))
                    .font(.system(size: saldo == 0 ? 10 : 12, weight: saldo == 0 ? .medium : .bold)).monospacedDigit()
                    .foregroundStyle(annullata ? PSE.faint : (saldo == 0 ? PSE.pos.opacity(0.8) : PSE.payment(pay)))
                    .frame(width: wSoldi, alignment: .trailing)
                pill(st).frame(width: wStato, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(dispari ? Color.clear : Color.white.opacity(0.018))
            .overlay(alignment: .leading) {
                Rectangle().fill(st == .in_attesa ? PSE.warn : Color.clear).frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(b.guest_name) · \(prettyDate(b.checkin)) → \(prettyDate(b.checkout)) · \(eur(b.amount_cents)) — clicca per aprire, modificare o cancellare")
    }
    private func cella(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).monospacedDigit().foregroundStyle(PSE.text.opacity(0.85))
    }
    private func dataBreve(_ s: String?) -> String {
        guard let d = data(s) else { return "—" }
        return tabGiorno.string(from: d)
    }
    private func pill(_ st: BookingStatus) -> some View {
        let c = st == .in_attesa ? PSE.warn : PSE.status(st)
        return HStack(spacing: 5) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(st.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(c).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(Capsule().fill(c.opacity(0.13)))
        .overlay(Capsule().strokeBorder(c.opacity(0.3), lineWidth: 1))
    }

    /// Riga di chiusura: i totali sono di quello che si sta guardando, non di
    /// tutto il database — se filtri Booking di agosto, sono quelli.
    private func totali(_ list: [Prenotazione]) -> some View {
        let tot = list.reduce(0) { $0 + $1.amount_cents }
        let inc = list.reduce(0) { $0 + $1.paid_cents }
        let notti = list.reduce(0) { $0 + (nights($1.checkin, $1.checkout) ?? 0) }
        return HStack(spacing: 14) {
            Text("\(list.count) prenotazioni · \(notti) notti")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PSE.dim)
            Spacer()
            valore("TOTALE", eur(tot), PSE.text)
            valore("INCASSATO", eur(inc), PSE.pos)
            valore("DA INCASSARE", eur(max(0, tot - inc)), max(0, tot - inc) > 0 ? PSE.warn : PSE.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(PSE.surface)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .top)
    }
    private func valore(_ t: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
            Text(v).font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(c)
        }
    }
}
