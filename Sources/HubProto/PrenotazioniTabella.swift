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
private let tabGiornoBreve: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "EEE d MMM"; return f }()

/// Testo confrontabile: senza accenti e in minuscolo, così «Lucía» si trova
/// scrivendo «lucia» e «Işık» scrivendo «isik».
private func tabFold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "İ", with: "i")
        .lowercased()
}

struct PrenotazioniTabella<Striscia: View>: View {
    let items: [Prenotazione]
    /// Filtro casa già scelto in cima alla pagina: la tabella lo rispetta.
    let struttura: Struttura?
    /// Giorno scelto sulla striscia del calendario (o cliccando il planning):
    /// il filtro «giorno» lo segue, così questa tabella ha preso il posto
    /// dell'elenco del giorno che stava qui sopra e diceva le stesse righe.
    let giorno: Date
    let onSelect: (Prenotazione) -> Void
    /// La striscia dei giorni sta qui dentro, non in una sezione a parte:
    /// serve solo a muovere questo elenco, e separarle voleva dire due scatole
    /// per una cosa sola.
    @ViewBuilder let striscia: () -> Striscia

    /// Un filtro solo, non due incrociati: «attive» mescolava chi è in casa
    /// adesso, chi deve ancora arrivare e chi è già partito, ed era la cosa che
    /// rendeva la lista illeggibile. Queste sei voci si escludono a vicenda e
    /// rispondono ognuna a una domanda precisa.
    enum Filtro: String, CaseIterable, Identifiable {
        case giorno, inCasa, inArrivo, daConfermare, cancellate, passate, tutto
        var id: String { rawValue }
        var label: String {
            switch self {
            case .giorno: return "Giorno scelto"
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
            case .giorno: return "Arrivi, partenze e chi è in casa nel giorno scelto sulla striscia del calendario."
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
            case .giorno, .inArrivo, .daConfermare, .tutto: return (.checkin, true)
            case .cancellate, .passate: return (.checkin, false)
            }
        }
    }
    enum Colonna: String { case ospite, casa, checkin, checkout, notti, importo, saldo, stato }

    @State private var q = ""
    @State private var filtro: Filtro = .giorno
    /// Quale pastiglia del riepilogo ha l'elenco aperto: i numeri della
    /// giornata non dicono a che camera si riferiscono, e ricavarlo voleva dire
    /// rileggersi la tabella riga per riga.
    @State private var pastigliaAperta: String?
    @State private var ordine: Colonna = .checkin
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
    /// Ruolo della prenotazione nel giorno scelto: arriva, è già dentro, o parte.
    /// Vuoto se quel giorno non la riguarda.
    private func ruolo(_ b: Prenotazione, _ d: Date) -> String? {
        guard b.status != "cancellata", let ci = data(b.checkin), let co = data(b.checkout) else { return nil }
        let g = Calendar.current.startOfDay(for: d)
        if ci == g { return "arrivo" }
        if co == g { return "partenza" }
        return (ci < g && g < co) ? "in casa" : nil
    }
    private func passa(_ b: Prenotazione, _ f: Filtro) -> Bool {
        let annullata = b.status == "cancellata"
        let ci = data(b.checkin), co = data(b.checkout)
        switch f {
        case .giorno:       return ruolo(b, giorno) != nil
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
        // Le case restano separate: prima tutta Via Po, poi tutta Via Romagna.
        // Sono due gestioni diverse e leggerle mescolate non serve a niente;
        // l'ordinamento scelto vale dentro ciascuna casa.
        if a.struttura != b.struttura { return pesoCasa(a.struttura) < pesoCasa(b.struttura) }
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
    private func pesoCasa(_ s: String) -> Int { s == Struttura.viaPo.rawValue ? 0 : 1 }
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
        // Stessa scatola pieghevole di tutte le altre sezioni della pagina:
        // aperta di partenza, perché è l'elenco su cui si lavora.
        return PSEPieghevole("TUTTE LE PRENOTAZIONI",
                             valore: "\(list.count) di \(items.count)",
                             colore: PSE.ink, coloreValore: PSE.accent,
                             nota: etichetta(filtro), grande: true, aperta: true) {
            contenuto(list).padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
    private func contenuto(_ list: [Prenotazione]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            striscia()
            if filtro == .giorno { riepilogoGiorno }
            HStack(spacing: 10) {
                filtri
                campoRicerca
            }
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
    // ── La giornata in una riga ──────────────────────────────────────────────
    // Chi arriva, chi parte, chi resta, e i soldi che si muovono quel giorno:
    // sono le cose che si vanno a contare a mano sull'elenco, ogni volta.
    private var riepilogoGiorno: some View {
        let delGiorno = selezionate(.giorno)
        let arrivi = delGiorno.filter { ruolo($0, giorno) == "arrivo" }
        let partenze = delGiorno.filter { ruolo($0, giorno) == "partenza" }
        let restano = delGiorno.filter { ruolo($0, giorno) == "in casa" }
        // Da riscuotere all'arrivo: il saldo aperto di chi entra oggi.
        let daRiscuotere = arrivi.reduce(0) { $0 + max(0, $1.amount_cents - $1.paid_cents) }
        let daSaldare = partenze.reduce(0) { $0 + max(0, $1.amount_cents - $1.paid_cents) }
        let daRiscuotereRighe = arrivi.filter { $0.amount_cents > $0.paid_cents }
        let daSaldareRighe = partenze.filter { $0.amount_cents > $0.paid_cents }
        return HStack(spacing: 8) {
            pastiglia("ARRIVI", "\(arrivi.count)", PSE.pos, arrivi.isEmpty ? nil : arrivi.map { nomeBreve($0.guest_name) }.joined(separator: ", "), arrivi)
            pastiglia("PARTENZE", "\(partenze.count)", PSE.warn, partenze.isEmpty ? nil : partenze.map { nomeBreve($0.guest_name) }.joined(separator: ", "), partenze)
            pastiglia("RESTANO", "\(restano.count)", PSE.dim, nil, restano)
            if daRiscuotere > 0 {
                pastiglia("DA RISCUOTERE AL CHECK-IN", restante(daRiscuotere), PSE.warn, "Saldo aperto di chi arriva oggi", daRiscuotereRighe, soldi: true)
            }
            if daSaldare > 0 {
                pastiglia("DA SALDARE AL CHECK-OUT", restante(daSaldare), PSE.neg, "Saldo aperto di chi parte oggi", daSaldareRighe, soldi: true)
            }
            if partenze.count > 0 {
                pastiglia("PULIZIE", "\(partenze.count)", PSE.accent, "Una per ogni camera che si libera", partenze)
            }
            Spacer(minLength: 0)
        }
    }
    private func nomeBreve(_ n: String) -> String { n.split(separator: " ").first.map(String.init) ?? n }
    /// Un saldo aperto sotto l'euro va scritto con i centesimi: la pastiglia
    /// diceva «€0» quando restavano 25 centesimi da incassare, e uno zero in
    /// una casella che esiste solo se c'è qualcosa da riscuotere si legge come
    /// un errore del programma. È la stessa regola della colonna saldo.
    private func restante(_ cents: Int) -> String { cents < 100 ? eurc(cents) : eur(cents) }
    /// Il numero e, dietro, le righe che lo compongono: si clicca e si vedono le
    /// camere, e da lì si va sulla prenotazione senza passare dalla tabella.
    private func pastiglia(_ t: String, _ v: String, _ c: Color, _ aiuto: String?,
                           _ righe: [Prenotazione] = [], soldi: Bool = false) -> some View {
        let apribile = !righe.isEmpty
        let aperta = Binding(get: { pastigliaAperta == t },
                             set: { pastigliaAperta = $0 ? t : nil })
        // Niente `.disabled` sulla pastiglia vuota: sbiadirebbe il numero, e uno
        // zero sbiadito si legge come «dato mancante» invece che come «oggi non
        // arriva nessuno». Resta accesa, semplicemente non si apre.
        return Button {
            guard apribile else { return }
            pastigliaAperta = pastigliaAperta == t ? nil : t
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(t).font(.system(size: 8, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                        .lineLimit(1)
                    if apribile {
                        Image(systemName: "chevron.down").font(.system(size: 6, weight: .black))
                            .foregroundStyle(c.opacity(0.7))
                    }
                }
                Text(v).font(.system(size: 15, weight: .bold)).foregroundStyle(c).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(pastigliaAperta == t ? c.opacity(0.12) : PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c.opacity(pastigliaAperta == t ? 0.6 : 0.25), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(apribile ? "\(aiuto ?? t.capitalized) — clicca per vedere le camere" : (aiuto ?? t.capitalized))
        .popover(isPresented: aperta, arrowEdge: .bottom) {
            elencoCamere(t, righe, colore: c, soldi: soldi)
        }
    }

    /// Le righe si leggono per casa e per camera, non nell'ordine in cui
    /// tornano dal database: si apre l'elenco per sapere «quale stanza», e senza
    /// un ordine la stanza va cercata in mezzo alle altre.
    private func perCamera(_ righe: [Prenotazione]) -> [Prenotazione] {
        righe.sorted { a, b in
            let sa = Struttura.from(a.struttura), sb = Struttura.from(b.struttura)
            if sa != sb { return sa.label < sb.label }
            let ca = a.camera ?? "", cb = b.camera ?? ""
            // Chi non ha ancora una camera va in fondo: è una cosa da sistemare,
            // non una stanza dove andare.
            if ca.isEmpty != cb.isEmpty { return cb.isEmpty }
            if ca != cb { return ca < cb }
            return a.guest_name < b.guest_name
        }
    }

    /// L'elenco dietro una pastiglia: prima la camera, perché la domanda è
    /// «quale stanza», poi chi ci sta e quanto manca.
    private func elencoCamere(_ titolo: String, _ righe: [Prenotazione], colore: Color, soldi: Bool) -> some View {
        let ordinate = perCamera(righe)
        return VStack(alignment: .leading, spacing: 0) {
            Text(titolo).font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(colore)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ForEach(Array(ordinate.enumerated()), id: \.element.id) { i, b in
                let str = Struttura.from(b.struttura)
                let saldo = max(0, b.amount_cents - b.paid_cents)
                Button {
                    pastigliaAperta = nil
                    onSelect(b)
                } label: {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hue: str.hue/360, saturation: 0.42, brightness: 0.74))
                            .frame(width: 2.5, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.camera ?? "Camera da assegnare")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink).lineLimit(1)
                            Text("\(str.label) · \(b.guest_name)")
                                .font(.system(size: 10)).foregroundStyle(PSE.faint).lineLimit(1)
                        }
                        Spacer(minLength: 10)
                        if soldi, saldo > 0 {
                            Text(saldo < 100 ? eurc(saldo) : eur(saldo))
                                .font(.system(size: 11.5, weight: .bold)).monospacedDigit().foregroundStyle(colore)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(PSE.faint)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Apri la prenotazione di \(b.guest_name)")
                if i < ordinate.count - 1 { Divider().overlay(PSE.line).padding(.leading, 14) }
            }
            Spacer(minLength: 10)
        }
        .frame(width: 260)
        .background(PSE.panel)
    }

    private var filtri: some View {
        HStack(spacing: 8) {
            ForEach(Filtro.allCases) { f in chip(f) }
            Spacer(minLength: 8)
        }
    }
    /// Il filtro «giorno» porta scritta la data che sta guardando: se sposti la
    /// striscia del calendario devi vederlo dal bottone, non indovinarlo.
    private func etichetta(_ f: Filtro) -> String {
        guard f == .giorno else { return f.label }
        return Calendar.current.isDateInToday(giorno) ? "Oggi" : tabGiornoBreve.string(from: giorno).capitalized
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
                Text(etichetta(f)).font(.system(size: 11, weight: attivo ? .bold : .medium))
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
            if filtro == .giorno { thFisso("").frame(width: 62) }
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
                // Col filtro «giorno» serve sapere se arriva, se è già dentro o
                // se parte: era l'unica cosa che l'elenco del giorno diceva in
                // più, e resta qui.
                if filtro == .giorno, let r = ruolo(b, giorno) {
                    Text(r.uppercased()).font(.system(size: 8, weight: .heavy)).tracking(0.5)
                        .foregroundStyle(r == "arrivo" ? PSE.pos : r == "partenza" ? PSE.warn : PSE.dim)
                        .frame(width: 62, alignment: .leading)
                }
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
                // Sotto l'euro si scrivono i centesimi: un residuo di 0,25
                // arrotondato diventava «€0», che sembra un errore.
                Text(saldo == 0 ? "saldato" : (saldo < 100 ? eurc(saldo) : eur(saldo)))
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

// ── Elenco aperto da una card del riepilogo ─────────────────────────────────
// Un totale che non si può aprire è un numero da prendere per buono: qui ci
// sono le righe che lo compongono, e da ognuna si va alla prenotazione.
struct ElencoPrenotazioni: Identifiable {
    let id = UUID()
    let titolo: String
    let sottotitolo: String
    let righe: [Prenotazione]
}

struct ElencoPrenotazioniSheet: View {
    let elenco: ElencoPrenotazioni
    let onClose: () -> Void
    let onSelect: (Prenotazione) -> Void

    private var totale: Int { elenco.righe.reduce(0) { $0 + $1.amount_cents } }
    private var incassato: Int { elenco.righe.reduce(0) { $0 + $1.paid_cents } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(elenco.titolo).font(.system(size: 15, weight: .bold)).foregroundStyle(PSE.ink)
                    Text(elenco.sottotitolo).font(.system(size: 11)).foregroundStyle(PSE.dim)
                }
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 14, trailing: 16))

            if elenco.righe.isEmpty {
                EmptyStateCard(icon: "tray", text: "Nessuna prenotazione in questa voce.").padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(elenco.righe) { b in
                                Button { onSelect(b) } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(b.guest_name).font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(PSE.ink).lineLimit(1)
                                            Text([Struttura.from(b.struttura).label, b.camera].compactMap { $0 }.joined(separator: " · "))
                                                .font(.system(size: 10)).foregroundStyle(PSE.faint).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(prettyDate(b.checkin)) → \(prettyDate(b.checkout))")
                                            .font(.system(size: 10.5)).foregroundStyle(PSE.dim)
                                            .frame(width: 150, alignment: .leading)
                                        Text(eur(b.amount_cents)).font(.system(size: 12.5, weight: .bold))
                                            .foregroundStyle(PSE.text).monospacedDigit()
                                            .frame(width: 80, alignment: .trailing)
                                        Text(b.amount_cents > b.paid_cents ? eurc(b.amount_cents - b.paid_cents) : "saldato")
                                            .font(.system(size: b.amount_cents > b.paid_cents ? 12 : 10, weight: .semibold))
                                            .foregroundStyle(b.amount_cents > b.paid_cents ? PSE.warn : PSE.pos.opacity(0.8))
                                            .monospacedDigit().frame(width: 80, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 9).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Clicca per aprire la prenotazione")
                                Divider().overlay(PSE.line).padding(.leading, 16)
                            }
                        }
                    }
                    HStack {
                        Text("\(elenco.righe.count) PRENOTAZIONI").font(.system(size: 10, weight: .heavy))
                            .tracking(0.8).foregroundStyle(PSE.ink)
                        Spacer()
                        Text("totale \(eur(totale))").font(.system(size: 11)).foregroundStyle(PSE.dim)
                        Text("incassato \(eur(incassato))").font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.pos)
                        if totale > incassato {
                            Text("da incassare \(eur(totale - incassato))")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.warn)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Color.white.opacity(0.04))
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(PSE.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
                .padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 760, height: 520)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
    }
}
