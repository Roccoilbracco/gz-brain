import SwiftUI

// ============================================================================
// Camere PSE — Tesoreria · Storico contabile (Via Po + Via Romagna)
// Le due stagioni chiuse, prima che la gestione passasse a GZ Brain:
//   2024-2025 → 11/04/2024 → 30/09/2025   (settembre 2025 sta QUI)
//   2025-2026 → 01/10/2025 → 30/06/2026
// Da luglio 2026 in poi i numeri stanno nella tesoreria normale (movimenti,
// prenotazioni): qui dentro non c'è una riga che si ripeta là.
//
// Stessa divisione della Tesoreria: utenze, colazioni, pulizie, mutuo, opera…
// ognuna spaccata per casa, e ogni numero si apre e mostra le righe che lo
// compongono.
//
// Sorgente: le tabelle public.storico_* , caricate dal libro maestro
// GESTION_PSE_MASTER_2024-2026.xlsx. Si può correggere (vedi StoricoEdit),
// ma la modifica resta dentro le storico_*. I dati da ottobre 2025 a giugno
// 2026 vengono da chat di WhatsApp: ogni riga porta la sua `fonte` e il flag
// `verificato`.
// ============================================================================

struct StoricoMovimento: Identifiable, Decodable, Equatable {
    let id: String
    var periodo: String
    var data: String
    var struttura: String?
    var tipo: String            // entrata | uscita
    var categoria: String?
    var descrizione: String?
    var importo_cents: Int
    var pagato_da: String?
    var fonte: String?
    var verificato: Bool
    /// true = entrata che è solo la faccia «chi ha messo i soldi» di un'uscita
    /// già registrata. Nel vecchio Excel ogni spesa era scritta due volte, così.
    /// Resta salvata ma sta fuori da elenchi e totali: chi ha pagato si legge
    /// sull'uscita (campo pagato_da) e nella scheda Soci.
    var contropartita: Bool
    /// true = la stessa spesa sta già dentro un'altra volta, da un'altra
    /// fonte: la bolletta arrivata sia dall'estratto conto sia dalle fatture.
    /// Come la contropartita, resta salvata ma non entra in elenchi e totali —
    /// cancellarla vorrebbe dire non poter più ricontrollare da dove veniva.
    var doppione: Bool
    var note: String?
}

struct StoricoAffitto: Identifiable, Decodable, Equatable {
    let id: String
    var periodo: String
    var data: String
    var struttura: String?
    var camera: String?
    var notti: Int?
    var canale: String?
    var lordo_cents: Int
    var commissione_cents: Int
    var netto_cents: Int
    var stato: String?
    var fonte: String?
    var note: String?
}

struct StoricoSpesaAlloggio: Identifiable, Decodable, Equatable {
    let id: String
    var periodo: String
    var data: String
    var struttura: String?
    var categoria: String?
    var descrizione: String?
    var importo_cents: Int
    /// Aggiunta il 29/07/26: prima non c'era, e pulizie, colazioni e
    /// lavanderia comparivano tutte come «Da chiarire» pur uscendo dal
    /// conto della società.
    var pagato_da: String?
    var fonte: String?
    var note: String?
}

struct StoricoApporto: Identifiable, Decodable, Equatable {
    let id: String
    var periodo: String
    var data: String
    var socio: String           // Giorgio | Giacomo
    var struttura: String?
    var descrizione: String?
    var categoria: String?
    var importo_cents: Int
    /// Falso = riga registrata ma che NON entra nel conguaglio (rate pagate
    /// con l'incasso degli affitti, rimborsi, doppioni risolti).
    var conta: Bool
    var fonte: String?
    var note: String?
}

struct StoricoPendente: Identifiable, Decodable, Equatable {
    let id: String
    var periodo: String
    var data_avviso: String?
    var concetto: String?
    var importo_cents: Int
    var origine: String?
    var stato: String?
    var note: String?
}

extension HubAPI {
    /// `periodo` = "tutto" legge tutte e due le stagioni insieme.
    private static func filtroPeriodo(_ p: String) -> String {
        p == "tutto" ? "" : "&periodo=eq.\(p)"
    }
    static func listStoricoMovimenti(_ p: String) async throws -> [StoricoMovimento] {
        try await sb.fetch("storico_movimenti?select=*\(filtroPeriodo(p))&order=data.asc&limit=3000")
    }
    static func listStoricoAffitti(_ p: String) async throws -> [StoricoAffitto] {
        try await sb.fetch("storico_affitti?select=*\(filtroPeriodo(p))&order=data.asc&limit=3000")
    }
    static func listStoricoSpeseAlloggio(_ p: String) async throws -> [StoricoSpesaAlloggio] {
        try await sb.fetch("storico_spese_alloggio?select=*\(filtroPeriodo(p))&order=data.asc&limit=3000")
    }
    static func listStoricoApporti(_ p: String) async throws -> [StoricoApporto] {
        try await sb.fetch("storico_apporti_soci?select=*\(filtroPeriodo(p))&order=data.asc&limit=3000")
    }
    /// Tutti e due i periodi: il conguaglio è uno solo, non uno per stagione.
    static func listStoricoApportiTutti() async throws -> [StoricoApporto] {
        try await sb.fetch("storico_apporti_soci?select=*&order=data.asc&limit=2000")
    }
    /// Tutti i movimenti, senza filtro di stagione: servono per numerare le
    /// rate dei mutui. La rata 4 è la quarta del mutuo, non la prima della
    /// stagione in cui si sta guardando.
    static func listStoricoMovimentiTutti() async throws -> [StoricoMovimento] {
        try await sb.fetch("storico_movimenti?select=*&order=data.asc&limit=3000")
    }
    static func listStoricoPendenti(_ p: String) async throws -> [StoricoPendente] {
        try await sb.fetch("storico_pendenti?select=*\(filtroPeriodo(p))&order=data_avviso.asc&limit=500")
    }
}

private let stoYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let stoDay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "dd/MM/yy"; return f }()

private func stoData(_ s: String?) -> String {
    guard let s, let d = stoYmd.date(from: String(s.prefix(10))) else { return "" }
    return stoDay.string(from: d)
}

// ── Le case, nell'ordine delle colonne ──────────────────────────────────────
enum StoCasa: String, CaseIterable, Identifiable {
    case viaPo = "Via Po", viaRomagna = "Via Romagna", mixto = "Mixto"
    var id: String { rawValue }
    var breve: String { self == .mixto ? "Comune" : rawValue }
}

// ── I gruppi di spesa: gli stessi nomi della Tesoreria ──────────────────────
// Le categorie del libro maestro sono tante e scritte a mano in due lingue.
// Qui si riducono ai gruppi che il commercialista (e Giorgio) leggono davvero.
enum StoGruppo: String, CaseIterable, Identifiable {
    case acquisto = "Acquisto immobili"
    case opera = "Opera e arredo"
    case cambioUso = "Cambio d'uso e pratiche"
    case mutuo = "Mutuo"
    case utenze = "Utenze"
    case pulizie = "Pulizie e lavanderia"
    case colazioni = "Colazioni"
    case tasse = "Tasse (TARI/IMU)"
    case commercialista = "Commercialista e banca"
    case manutenzione = "Manutenzione"
    case prelievi = "Prelievi da chiarire"
    case assicurazioni = "Assicurazioni"
    case prestiti = "Prestiti e restituzioni"
    case altro = "Altro"
    var id: String { rawValue }

    /// Dove finisce ogni categoria scritta nel libro maestro.
    static func da(_ categoria: String?) -> StoGruppo {
        switch (categoria ?? "").lowercased() {
        case "spese aquisto inmobile": return .acquisto
        case "tecnici casa", "materiali", "aredo casa": return .opera
        case "cambio d'uso": return .cambioUso
        case "mutuo — rata", "mutuo — gastos", "mutuo liquidità", "mutuo": return .mutuo
        case "luce", "gas", "acqua", "internet": return .utenze
        case "pulizie", "limpieza", "lavanderia": return .pulizie
        case "colazioni", "colazione": return .colazioni
        case "tase", "tasse", "tari", "imu": return .tasse
        case "commercialista", "spese bancarie": return .commercialista
        case "manutenzione": return .manutenzione
        case "prelievo": return .prelievi
        case "prestito a socio": return .prestiti
        case "asicurazioni", "assicurazioni": return .assicurazioni
        case "restituzione prestiti", "recupero liquidita aquisto", "rata prestito agos",
             "prestito agos": return .prestiti
        default: return .altro
        }
    }
}

// I due blocchi in cui si divide la spesa. La domanda che si fa Giorgio è
// «quanto è costato comprare e sistemare le case» contro «quanto costa
// tenerle in piedi»: sono due cose diverse e vanno lette separate.
enum StoBlocco: String, CaseIterable, Identifiable {
    case investimento = "INVESTIMENTO — comprare e sistemare le case"
    case gestione = "GESTIONE — far girare le case"
    case finanziamento = "FINANZIAMENTO — soldi restituiti"
    var id: String { rawValue }
    var gruppi: [StoGruppo] {
        switch self {
        case .investimento: return [.acquisto, .opera, .cambioUso]
        case .gestione: return [.mutuo, .utenze, .pulizie, .colazioni, .tasse, .assicurazioni,
                                .manutenzione, .commercialista, .prelievi, .altro]
        case .finanziamento: return [.prestiti]
        }
    }
    var sottotitolo: String {
        switch self {
        case .investimento: return "Prezzo delle case più tutta l'opera, i materiali e l'arredo. Sono soldi che restano dentro l'immobile."
        case .gestione: return "Mutuo, utenze, pulizie, colazioni, tasse e resto: quanto costa tenere aperte le due case."
        case .finanziamento: return "Restituzioni: il mutuo di liquidità ridato ai soci e i prestiti senza interessi rimborsati. Non è né investimento né costo — sono soldi che tornano a chi li aveva messi."
        }
    }
    var colore: Color {
        switch self {
        case .investimento: return PSE.accent
        case .gestione: return PSE.warn
        case .finanziamento: return PSE.dim
        }
    }
}

/// Come si raggruppa il «a chi»: sulle spese o sugli apporti dei soci.
enum ModoFornitori { case no, spese, apporti }

/// Da una descrizione scritta a mano tira fuori a chi sono andati i soldi.
/// Non è magia: è un elenco di nomi che ricorrono nel libro. Quello che non
/// riconosce finisce in «Altri», che è onesto e si vede.
///
/// Due regole, imparate sbagliando:
///
/// 1. **Vince chi compare prima nella descrizione**, non chi sta prima in
///    questo elenco. «Enel Energia — SDD scad. 26/11/25 (utenza Paoletti
///    Sara)» è una bolletta della luce, non un pagamento a Francesco
///    Paoletti; «AON S.p.A. — assicurazione Via Po (polizza intestata a
///    Sara Paoletti)» è l'assicurazione della casa. Chi scrive il libro
///    mette davanti il nome di chi ha preso i soldi, e in fondo i dettagli.
/// 2. **La chiave si cerca a inizio parola.** Senza questo «obi» si trovava
///    dentro «M-OBI-LI» e dentro «IMM-OBI-LIARIA UMBERTO»: 5.680 € di
///    mobili e la provvigione dell'agenzia finivano da OBI. Solo a inizio
///    parola, non anche in fondo, se no «braccialarg» non prenderebbe più
///    «Braccialarghe».
func storicoFornitore(_ d: String?) -> String {
    let t = (d ?? "").lowercased()
    let nomi: [(String, String)] = [
        ("vallasciani", "Uriel Vallasciani"), ("uriel", "Uriel Vallasciani"),
        ("maroni", "Maroni Francesco"), ("pistolesi", "Idroimpianti Pistolesi"),
        ("idroimpianti", "Idroimpianti Pistolesi"), ("micucci", "Gilberto Micucci"),
        ("micucii", "Gilberto Micucci"), ("paoletti", "Francesco Paoletti"),
        ("edif", "Edif"), ("ikea", "IKEA"), ("obi", "OBI"),
        ("color city", "Color City"), ("leroy", "Leroy Merlin"), ("said", "Said"),
        ("angelo", "Angelo muratore"), ("romagnoli", "Domenico Romagnoli"),
        ("kurti", "Kurti Refik"), ("refik", "Kurti Refik"), ("timi", "Timi"),
        ("esatec", "Esatec Progetti"), ("crm spa", "CRM Spa"), ("cementor", "Cementor"),
        ("donatella", "Donatella"), ("anastasi", "Massimo Anastasi"),
        ("bricofer", "Bricofer"), ("bricoio", "Brico Io"), ("comet", "Comet"),
        ("amazon", "Amazon"), ("geberit", "Geberit"), ("tennacola", "Tennacola"),
        ("stefano", "Stefano"), ("diomedi", "Ferramenta Diomedi"),
        ("braccialarg", "Ferramenta Braccialarghe"), ("edilcasa", "Edilcasa Caccamo"),
        ("hfb", "Ancona HFB"), ("energia", "Enel / Energia"), ("enel", "Enel / Energia"),
        ("plenitude", "Plenitude"), ("wind tre", "Wind Tre"), ("nexi", "Nexi"),
        ("unipol", "Unipol"), ("assifirmum", "Assifirmum"), ("bucalossi", "Bucalossi"),
        ("aon", "AON Assicurazioni"),
        ("commercialista", "Commercialista Fausto"), ("notaio", "Notaio Ciotola"),
        ("ciotola", "Notaio Ciotola"), ("carifermo", "Carifermo"), ("bper", "BPER"),
        ("eco elpidiense", "Eco Elpidiense"), ("proshop", "Pro Shop"),
        ("mazzoni", "Mazzoni Adriano"), ("esotec", "Esotec Strovegli"),
        ("loredana", "Loredana"), ("valentina", "Valentina Di Feo"),
        ("pomioli", "Pomioli"), ("gennaro", "Gennaro e ragazzi"),
        ("karim", "Karim Ilyas"), ("immobiliaria umberto", "Immobiliare Umberto"),
        ("acquisto locale", "Acquisto immobile"), ("compra inmueble", "Acquisto immobile"),
        ("idrozeta", "Idrozeta"), ("cartelli", "Insegne e cartelli"),
        ("registratore cassa", "Registratore di cassa"), ("prelievo", "Prelievo contante"),
        // Aggiunti passando in rassegna cos'era finito in «Altri» (29/07/26).
        ("switch luce", "Switch Luce & Gas"),
        ("megawatt", "Megawatt Luce-Gas"), ("booking", "Booking.com"),
        ("agenzia entrate", "Agenzia Entrate"), ("f24", "Agenzia Entrate"),
        // «agos» da solo prendeva anche «COLAZIONI MESE AGOSTO».
        ("agos ducato", "Prestito Agos"),
        // Mestieri: nel libro vecchio il nome non c'è, c'è il mestiere. È
        // comunque meglio di «Altri»: si vede quanto è costato l'idraulico.
        ("fontanero", "Idraulico (fontanero)"), ("elettricista", "Elettricista"),
        ("electricista", "Elettricista"), ("carpintero", "Carpentiere"),
        ("muratore", "Muratore")
    ]
    guard !t.isEmpty else { return "Altri" }
    var vince: (posizione: Int, nome: String)? = nil
    for (chiave, nome) in nomi {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: chiave)
        guard let r = t.range(of: pattern, options: .regularExpression) else { continue }
        let dove = t.distance(from: t.startIndex, to: r.lowerBound)
        // A parità di posizione tiene il primo dell'elenco: ci si arriva solo
        // con due chiavi che sono lo stesso nome scritto in due modi.
        if vince == nil || dove < vince!.posizione { vince = (dove, nome) }
    }
    return vince?.nome ?? "Altri"
}

/// Finestra di dettaglio aperta da un numero qualsiasi della pagina.
struct StoricoDettaglio: Identifiable {
    let id: String
    let titolo: String
    let nota: String
    let righe: [DettaglioRiga]
    let totale: Int
    /// «A chi abbiamo pagato»: un blocco per fornitore, spaccato per casa e
    /// con lo storico dei suoi pagamenti sotto.
    var perFornitore: [FornitoreTotale] = []
}

struct FornitoreTotale: Identifiable {
    let nome: String
    let totale: Int
    let viaPo: Int
    let viaRomagna: Int
    let comune: Int
    let righe: [DettaglioRiga]
    /// Chi ha pagato questo fornitore, dal più grosso al più piccolo.
    var paganti: [(nome: String, importo: Int)] = []
    var id: String { nome }
}

/// I nomi come stanno scritti nel foglio vecchio sono sigle; qui diventano
/// leggibili. «Ver nota» vuol dire che chi ha pagato non è mai stato scritto.
func nomePagante(_ p: String?) -> String {
    switch (p ?? "").trimmingCharacters(in: .whitespaces) {
    case "Conto Proprieta":            return "Conto società"
    case "Conto BPER Giacomo-Giorgio": return "Conto BPER"
    case "Conto Affittacamere Massimo":return "Conto Massimo"
    case "Conto Giacomo":              return "Conto Giacomo"
    case "Cassa contanti":             return "Contanti"
    case "Affiti":                     return "Incasso affitti"
    case "Ver nota", "Por identificar", "": return "Da chiarire"
    case let altro:                    return altro
    }
}

/// «Rata mutuo Via Po RATA N. 7» → 7. Zero vuol dire che il numero non c'è:
/// o non è mai stato scritto, o è scritto «N. 0», che è lo stesso.
private func numeroScritto(_ d: String?) -> Int {
    guard let d, let r = d.range(of: #"RATA\s*N\.?\s*\d+"#,
                                 options: [.regularExpression, .caseInsensitive])
    else { return 0 }
    return Int(d[r].filter(\.isNumber)) ?? 0
}

/// Il numero di ogni rata di mutuo, casa per casa, come lo chiama la banca:
///   • dove il numero c'è già scritto — Via Po, «RATA N. 4» — si tiene quello;
///   • le rate della stessa casa rimaste senza numero sono il preammortamento,
///     pagato mentre la banca erogava a stati d'avanzamento: solo interessi,
///     non rate di ammortamento, e si contano a parte;
///   • dove la banca non ha numerato niente — Via Romagna — si numera in
///     ordine di data, che lì è l'unico ordine che esiste.
/// Fuori restano spese, commissioni e perizie: non sono rate, non si numerano.
func numeriRata(_ tutti: [StoricoMovimento]) -> [String: String] {
    let rate = tutti.filter {
        $0.tipo == "uscita" && ($0.categoria ?? "").lowercased().contains("rata")
    }
    var out: [String: String] = [:]
    for (_, casa) in Dictionary(grouping: rate, by: { $0.struttura ?? "—" }) {
        let ord = casa.sorted { $0.data < $1.data }
        let numerate = ord.filter { numeroScritto($0.descrizione) > 0 }
        guard !numerate.isEmpty else {
            for (i, m) in ord.enumerated() { out[m.id] = "Rata \(i + 1)/\(ord.count)" }
            continue
        }
        for m in numerate { out[m.id] = "Rata \(numeroScritto(m.descrizione))/\(numerate.count)" }
        let pre = ord.filter { numeroScritto($0.descrizione) == 0 }
        for (i, m) in pre.enumerated() { out[m.id] = "Preammortamento \(i + 1)/\(pre.count)" }
    }
    return out
}

@MainActor final class StoricoModel: ObservableObject {
    @Published var movimenti: [StoricoMovimento] = []
    @Published var affitti: [StoricoAffitto] = []
    @Published var spese: [StoricoSpesaAlloggio] = []
    @Published var apporti: [StoricoApporto] = []
    @Published var pendenti: [StoricoPendente] = []
    /// Apporti di tutti e due i periodi: servono per il conguaglio, che è
    /// complessivo e non ha senso spezzato per stagione.
    @Published var apportiTutti: [StoricoApporto] = []
    /// Numero di rata per id, su tutte e due le stagioni (vedi `numeriRata`).
    @Published var numeroRata: [String: String] = [:]
    @Published var loading = true
    private var caricato: String? = nil

    /// Rilettura forzata: serve dopo aver modificato una riga.
    func reload(_ periodo: String) async { caricato = nil; await load(periodo) }

    func load(_ periodo: String) async {
        // Niente scorciatoia sulla cache: se si è corretto qualcosa — da qui o
        // da fuori — i grafici delle due sezioni devono dire subito la verità.
        loading = movimenti.isEmpty
        async let m = HubAPI.listStoricoMovimenti(periodo)
        async let a = HubAPI.listStoricoAffitti(periodo)
        async let s = HubAPI.listStoricoSpeseAlloggio(periodo)
        async let p = HubAPI.listStoricoApporti(periodo)
        async let d = HubAPI.listStoricoPendenti(periodo)
        movimenti = ((try? await m) ?? []).filter { !$0.contropartita && !$0.doppione }
        affitti = (try? await a) ?? []
        spese = (try? await s) ?? []
        apporti = (try? await p) ?? []
        pendenti = (try? await d) ?? []
        apportiTutti = (try? await HubAPI.listStoricoApportiTutti()) ?? []
        numeroRata = numeriRata((try? await HubAPI.listStoricoMovimentiTutti()) ?? [])
        caricato = periodo
        loading = false
    }

    // ── Affitti ──
    func affitti(_ casa: StoCasa?) -> [StoricoAffitto] {
        casa == nil ? affitti : affitti.filter { $0.struttura == casa!.rawValue }
    }
    func lordo(_ casa: StoCasa? = nil) -> Int { affitti(casa).reduce(0) { $0 + $1.lordo_cents } }
    func commissioni(_ casa: StoCasa? = nil) -> Int { affitti(casa).reduce(0) { $0 + $1.commissione_cents } }
    func nettoAffitti(_ casa: StoCasa? = nil) -> Int { affitti(casa).reduce(0) { $0 + $1.netto_cents } }
    var notti: Int { affitti.reduce(0) { $0 + ($1.notti ?? 0) } }
    func notti(_ casa: StoCasa?) -> Int { affitti(casa).reduce(0) { $0 + ($1.notti ?? 0) } }
    func soggiorni(_ casa: StoCasa?) -> Int { affitti(casa).count }

    // ── Spese di alloggio (pulizie, lavanderia, colazioni, extra) ──
    func spese(_ casa: StoCasa?, gruppo: StoGruppo? = nil) -> [StoricoSpesaAlloggio] {
        spese.filter { r in
            (casa == nil || r.struttura == casa!.rawValue) &&
            (gruppo == nil || StoGruppo.da(r.categoria) == gruppo)
        }
    }
    func totSpese(_ casa: StoCasa? = nil, gruppo: StoGruppo? = nil) -> Int {
        spese(casa, gruppo: gruppo).reduce(0) { $0 + $1.importo_cents }
    }

    // ── Movimenti (opera, mutui, utenze, finanziamento) ──
    func mov(_ casa: StoCasa?, tipo: String? = nil, gruppo: StoGruppo? = nil) -> [StoricoMovimento] {
        movimenti.filter { r in
            (casa == nil || r.struttura == casa!.rawValue) &&
            (tipo == nil || r.tipo == tipo!) &&
            (gruppo == nil || StoGruppo.da(r.categoria) == gruppo)
        }
    }
    func totMov(_ casa: StoCasa? = nil, tipo: String? = nil, gruppo: StoGruppo? = nil) -> Int {
        mov(casa, tipo: tipo, gruppo: gruppo).reduce(0) { $0 + $1.importo_cents }
    }
    /// Uscite del gruppo, contando anche le spese di alloggio dove il gruppo
    /// coincide (pulizie e colazioni stanno in due tabelle diverse ma per chi
    /// legge sono la stessa voce).
    func usciteGruppo(_ g: StoGruppo, casa: StoCasa? = nil) -> Int {
        totMov(casa, tipo: "uscita", gruppo: g) + totSpese(casa, gruppo: g)
    }
    var usciteDaVerificare: Int {
        movimenti.filter { $0.tipo == "uscita" && !$0.verificato }.reduce(0) { $0 + $1.importo_cents }
    }

    // ── Soci ──
    func apporti(_ socio: String, soloConta: Bool = true) -> [StoricoApporto] {
        apporti.filter { $0.socio == socio && (!soloConta || $0.conta) }
    }
    func apportiDi(_ socio: String) -> Int { apporti(socio).reduce(0) { $0 + $1.importo_cents } }
    var pendenteTotale: Int { pendenti.reduce(0) { $0 + $1.importo_cents } }

    // ── Conguaglio: su tutto lo storico, non solo su questo periodo ──
    func totaleSocio(_ socio: String) -> Int {
        apportiTutti.filter { $0.socio == socio && $0.conta }.reduce(0) { $0 + $1.importo_cents }
    }
    var conguaglio: Int { (totaleSocio("Giorgio") - totaleSocio("Giacomo")) / 2 }

    // ── Da dove sono arrivati i soldi ──────────────────────────────────────
    /// Entrate vere per origine (le contropartite dei soci stanno fuori:
    /// quelle sono nella tabella apporti).
    func entrateDa(_ chi: String) -> Int {
        movimenti.filter { $0.tipo == "entrata" && ($0.pagato_da ?? "") == chi }.reduce(0) { $0 + $1.importo_cents }
    }
    var mutuiErogati: Int { entrateDa("Mutuo") }
    var prestitiRicevuti: Int { entrateDa("Prestito Infrutifero") }
    /// Il prestito Agos: intestato a Giacomo ma lo rimborsa il conto della
    /// società, rata dopo rata. Va segnato a parte e in grande.
    var prestitoAgos: Int { entrateDa("Prestito Agos") }
    var agosRimborsato: Int {
        movimenti.filter { $0.categoria == "Rata prestito Agos" }.reduce(0) { $0 + $1.importo_cents }
    }
    /// I 24.000 € dell'Agos si possono leggere in due modi, e il conguaglio
    /// cambia parecchio. Qui sotto tutti e due, per poter scegliere.
    ///
    /// A) Sono un apporto di Giacomo e il prestito se lo gestisce lui.
    ///    Allora i suoi apporti salgono di 24.000 — ma le rate che la società
    ///    ha già pagato al posto suo (contanti inclusi) gliele deve rendere,
    ///    e metà di quei soldi li aveva messi Giorgio.
    var conguaglioAgosSuoi: Int {
        (totaleSocio("Giorgio") - (totaleSocio("Giacomo") + prestitoAgos)) / 2 + agosRimborsato / 2
    }
    /// B) È un prestito preso dalla società, che lo rimborsa dal conto.
    ///    Non è apporto di nessuno dei due: il debito che resta se lo dividono.
    ///    È lo scenario attivo oggi.
    var conguaglioAgosSocieta: Int { conguaglio }
    var affittiReinvestiti: Int { entrateDa("Affiti") }
    /// Restituito a banche, prestatori e soci.
    var restituito: Int { usciteGruppo(.prestiti) }
    /// Quello che hanno messo i due soci in QUESTO periodo, già al netto delle
    /// restituzioni. (Il conguaglio invece è su tutto lo storico: è un'altra cosa.)
    var messoDaiSoci: Int { apportiDi("Giorgio") + apportiDi("Giacomo") }
    var apportiDelPeriodo: [StoricoApporto] { apporti.filter { $0.conta } }

    // ── Righe per le finestre di dettaglio ──
    /// La rata come si legge in una finestra di dettaglio: davanti il numero,
    /// e via il testo che quel numero ha appena reso inutile — «Rata mutuo
    /// Via Po RATA N. 7» diventa «Rata 7/12». Quello che resta si tiene:
    /// il numero di finanziamento di Via Romagna sta scritto lì dentro.
    /// Le righe che non sono rate escono come stanno.
    func descrizioneMov(_ m: StoricoMovimento) -> String {
        let testo = m.descrizione ?? "—"
        guard let numero = numeroRata[m.id] else { return testo }
        var resto = testo
            .replacingOccurrences(of: #"RATA\s*N\.?\s*\d+"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^\s*Rata\s+mutuo\s*"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
        if let casa = m.struttura, resto.hasPrefix(casa) { resto.removeFirst(casa.count) }
        resto = resto.trimmingCharacters(in: CharacterSet(charactersIn: " —–-·"))
        return resto.isEmpty ? numero : "\(numero) · \(resto)"
    }
    func righe(_ r: [StoricoMovimento]) -> [DettaglioRiga] {
        r.sorted { $0.data < $1.data }.map {
            DettaglioRiga(id: $0.id, data: stoData($0.data), ymd: $0.data,
                          descrizione: descrizioneMov($0),
                          extra: [$0.struttura, $0.categoria].compactMap { $0 }.joined(separator: " · "),
                          casa: $0.struttura ?? "", pagatoDa: nomePagante($0.pagato_da),
                          importo: $0.importo_cents, positivo: $0.tipo == "entrata")
        }
    }
    func righe(_ r: [StoricoSpesaAlloggio]) -> [DettaglioRiga] {
        r.sorted { $0.data < $1.data }.map {
            DettaglioRiga(id: $0.id, data: stoData($0.data), ymd: $0.data,
                          descrizione: $0.descrizione ?? "—",
                          extra: [$0.struttura, $0.categoria].compactMap { $0 }.joined(separator: " · "),
                          casa: $0.struttura ?? "", pagatoDa: nomePagante($0.pagato_da),
                          importo: $0.importo_cents, positivo: false)
        }
    }
    func righe(_ r: [StoricoAffitto], netto: Bool = false) -> [DettaglioRiga] {
        r.sorted { $0.data < $1.data }.map {
            let notti = $0.notti.map { "\($0) notti" } ?? ""
            return DettaglioRiga(id: $0.id, data: stoData($0.data), ymd: $0.data,
                                 descrizione: [$0.camera, $0.canale].compactMap { $0 }.joined(separator: " · "),
                                 extra: [$0.struttura ?? "", notti].filter { !$0.isEmpty }.joined(separator: " · "),
                                 importo: netto ? $0.netto_cents : $0.lordo_cents, positivo: true)
        }
    }
    func righe(_ r: [StoricoApporto]) -> [DettaglioRiga] {
        r.sorted { $0.data < $1.data }.map {
            DettaglioRiga(id: $0.id, data: stoData($0.data), ymd: $0.data,
                          descrizione: $0.descrizione ?? "—",
                          extra: [$0.struttura, $0.conta ? nil : "fuori conguaglio"].compactMap { $0 }.joined(separator: " · "),
                          casa: $0.struttura ?? "", importo: abs($0.importo_cents), positivo: $0.importo_cents >= 0)
        }
    }
}

enum StoricoTab: String, CaseIterable, Identifiable {
    case riepilogo = "Riepilogo", perCasa = "Per casa", affitti = "Affitti"
    case movimenti = "Movimenti", soci = "Soci", pendenti = "Da incassare"
    var id: String { rawValue }
}

struct StoricoView: View {
    /// "2024-2025" oppure "2025-2026".
    let periodo: String
    @StateObject private var model = StoricoModel()
    @State private var tab: StoricoTab = .riepilogo
    @State private var casa: StoCasa? = nil
    /// La scheda di modifica la apre la Tesoreria: qui dentro siamo in uno
    /// ScrollView e di tutti i .sheet appesi a quella vista ne funziona uno
    /// solo, quindi ci passiamo attraverso.
    let apriModifica: (StoricoEditTarget) -> Void
    @State private var dettaglio: StoricoDettaglio? = nil

    /// Il nome che si legge in pagina, e le date esatte che copre.
    private var etichetta: String {
        switch periodo {
        case "2024-2025": return "Aprile 2024 – Settembre 2025"
        case "2025-2026": return "Ottobre 2025 – Giugno 2026"
        default: return "Riassunto · Aprile 2024 – Giugno 2026"
        }
    }
    private var intervallo: String {
        switch periodo {
        case "2024-2025": return "11/04/2024 → 30/09/2025"
        case "2025-2026": return "01/10/2025 → 30/06/2026"
        default: return "11/04/2024 → 30/06/2026 · le due stagioni insieme"
        }
    }
    private var eRiassunto: Bool { periodo == "tutto" }
    private var avviso: String? {
        periodo != "2024-2025"
        ? "I dati di questo periodo vengono in gran parte da chat di WhatsApp: ci sono arrotondamenti e stime. Ogni riga porta la sua fonte; il pallino arancio segna quello che nessuno ha ancora contrastato con estratti o fatture."
        : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            barra
            separazione
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                switch tab {
                case .riepilogo: riepilogo
                case .perCasa: perCasa
                case .affitti: affittiTab
                case .movimenti: movimentiTab
                case .soci: sociTab
                case .pendenti: pendentiTab
                }
            }
        }
        .padding(.horizontal, 2)
        .task(id: periodo) { await model.load(periodo) }
        .sheet(item: $dettaglio) { d in
            StoricoDettaglioSheet(d: d, onClose: { dettaglio = nil },
                                  bersaglio: rigaArchivio, modifica: apriModifica)
        }
        // Salvato o cancellato qualcosa: i numeri qui si rifanno da soli.
        .onReceive(NotificationCenter.default.publisher(for: .datiCambiati)) { _ in
            Task { await model.reload(periodo) }
        }
    }

    private var barra: some View {
        HStack(spacing: 10) {
            PSESegmented(items: StoricoTab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
            if tab == .affitti || tab == .movimenti {
                PSESegmented(items: [(nil, "Tutte")] + StoCasa.allCases.map { (Optional($0), $0.breve) },
                             selection: $casa)
            }
            Spacer(minLength: 0)
            if tab == .riepilogo { bottoneReport(nil) }
            if let nuovo = nuovaRiga {
                Button { apriModifica(nuovo) } label: {
                    Label("Aggiungi", systemImage: "plus").font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(PSE.accent.opacity(0.9)))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            Text(intervallo).font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.faint).monospacedDigit()
        }
    }

    /// Che riga si aggiunge, secondo la scheda aperta. Nel Riepilogo e in
    /// «Per casa» non si aggiunge niente: sono viste, non elenchi.
    private var nuovaRiga: StoricoEditTarget? {
        if eRiassunto { return nil }
        switch tab {
        case .affitti: return .affitto(nil)
        case .movimenti: return .movimento(nil)
        case .soci: return .apporto(nil)
        case .pendenti: return .pendente(nil)
        default: return nil
        }
    }

    /// Sta scritto in ogni scheda, non solo nel Riepilogo: chi arriva qui da
    /// una tabella deve capire subito che questi numeri non c'entrano con la
    /// gestione di oggi. È archivio, si consulta e basta.
    private var separazione: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").font(.system(size: 11)).foregroundStyle(PSE.accent)
            Text("**Archivio separato.** Contabilità chiusa del periodo, in tabelle sue. Questi numeri non entrano in nessun saldo, prenotazione, servizio o «da incassare» di Camere PSE. Si possono correggere — clic su una riga — ma la correzione resta qui dentro.")
                .font(.system(size: 11)).foregroundStyle(PSE.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.accent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.accent.opacity(0.25), lineWidth: 1))
    }

    /// Dall'`id` di una riga di dettaglio alla riga vera dell'archivio. Le righe
    /// di dettaglio portano l'id della riga da cui nascono, quindi basta
    /// cercarlo: quello che non si trova è un totale o un separatore, calcolato
    /// al volo, e resta giustamente non modificabile.
    private func rigaArchivio(_ r: DettaglioRiga) -> StoricoEditTarget? {
        if let m = model.movimenti.first(where: { $0.id == r.id }) { return .movimento(m) }
        if let s = model.spese.first(where: { $0.id == r.id })     { return .spesa(s) }
        if let a = model.affitti.first(where: { $0.id == r.id })   { return .affitto(a) }
        // Il conguaglio fra i soci guarda tutte le stagioni insieme: le sue
        // righe stanno in `apportiTutti`, non nel periodo aperto.
        if let p = model.apporti.first(where: { $0.id == r.id })   { return .apporto(p) }
        if let p = model.apportiTutti.first(where: { $0.id == r.id }) { return .apporto(p) }
        if let p = model.pendenti.first(where: { $0.id == r.id })  { return .pendente(p) }
        return nil
    }

    // ── apertura finestre ──────────────────────────────────────────────────
    private func apri(_ titolo: String, _ nota: String, _ righe: [DettaglioRiga], _ totale: Int,
                      fornitori: ModoFornitori = .no) {
        guard !righe.isEmpty else { return }
        var perF: [FornitoreTotale] = []
        if fornitori != .no {
            // Nelle spese conta l'importo; negli apporti le restituzioni vanno
            // in negativo, se no un socio sembra aver messo più di quanto ha messo.
            let dentro = fornitori == .spese ? righe.filter { !$0.positivo } : righe
            func val(_ r: DettaglioRiga) -> Int {
                fornitori == .spese ? r.importo : (r.positivo ? r.importo : -r.importo)
            }
            perF = Dictionary(grouping: dentro, by: { storicoFornitore($0.descrizione) })
                .map { nome, rr in
                    func q(_ c: String) -> Int { rr.filter { $0.casa == c }.reduce(0) { $0 + val($1) } }
                    let paganti = Dictionary(grouping: rr.filter { !$0.pagatoDa.isEmpty },
                                             by: { $0.pagatoDa })
                        .map { (nome: $0.key, importo: $0.value.reduce(0) { $0 + val($1) }) }
                        .filter { $0.importo != 0 }
                        .sorted { $0.importo > $1.importo }
                    return FornitoreTotale(nome: nome, totale: rr.reduce(0) { $0 + val($1) },
                                           viaPo: q("Via Po"), viaRomagna: q("Via Romagna"), comune: q("Mixto"),
                                           righe: rr.sorted { $0.ymd < $1.ymd }, paganti: paganti)
                }
                .filter { $0.totale != 0 }
                .sorted { $0.totale > $1.totale }
        }
        // Movimenti e spese di alloggio arrivano qui una lista dietro l'altra:
        // in ordine di data si leggono come un estratto conto. Se anche una
        // sola riga non porta la data si lascia l'ordine di chi ha chiamato.
        let inOrdine = righe.allSatisfy { !$0.ymd.isEmpty } ? righe.sorted { $0.ymd < $1.ymd } : righe
        dettaglio = StoricoDettaglio(id: titolo, titolo: titolo, nota: nota, righe: inOrdine,
                                     totale: totale, perFornitore: perF)
    }

    // ══ RIEPILOGO ══════════════════════════════════════════════════════════
    private var riepilogo: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let avviso { avvisoBox(avviso) }
            sezione("ATTIVITÀ DI AFFITTO") { cardsAffitto }
            affittiVsCosti
            confronto
            ForEach([StoBlocco.investimento, .gestione]) { b in blocco(b) }
            sezione("SOCI E CREDITI") { cardsSoci }
        }
    }

    private var cardsAffitto: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                cardClic("INCASSI LORDI", eurc(model.lordo()), PSE.pos) {
                    apri("Incassi lordi", "Tutti i soggiorni del periodo, importo pieno prima della commissione.",
                         model.righe(model.affitti), model.lordo())
                }
                cardClic("COMMISSIONI", inUscita(model.commissioni()), model.commissioni() > 0 ? PSE.neg : PSE.faint) {
                    let r = model.affitti.filter { $0.commissione_cents > 0 }
                    apri("Commissioni delle piattaforme", "Quanto si è tenuto Booking su ogni soggiorno.",
                         r.map { DettaglioRiga(id: $0.id, data: stoData($0.data),
                                               descrizione: [$0.camera, $0.canale].compactMap { $0 }.joined(separator: " · "),
                                               extra: $0.struttura ?? "", importo: $0.commissione_cents, positivo: false) },
                         model.commissioni())
                }
                cardClic("INCASSI NETTI", eurc(model.nettoAffitti()), PSE.text) {
                    apri("Incassi netti", "Quello che è arrivato davvero, tolta la commissione.",
                         model.righe(model.affitti, netto: true), model.nettoAffitti())
                }
                cardClic("SPESE DI ALLOGGIO", inUscita(model.totSpese()), model.totSpese() > 0 ? PSE.neg : PSE.faint) {
                    apri("Spese di alloggio", "Pulizie, lavanderia, colazioni ed extra legati ai soggiorni.",
                         model.righe(model.spese), model.totSpese())
                }
                let ris = model.nettoAffitti() - model.totSpese()
                card("RISULTATO", eurc(ris), ris >= 0 ? PSE.pos : PSE.neg)
            }
            HStack(spacing: 10) {
                card("SOGGIORNI", "\(model.affitti.count)", PSE.text)
                card("NOTTI", "\(model.notti)", PSE.text)
                cardClic("VIA PO (LORDO)", eurc(model.lordo(.viaPo)), PSE.text) {
                    apri("Affitti Via Po", "", model.righe(model.affitti(.viaPo)), model.lordo(.viaPo))
                }
                cardClic("VIA ROMAGNA (LORDO)", eurc(model.lordo(.viaRomagna)), PSE.text) {
                    apri("Affitti Via Romagna", "", model.righe(model.affitti(.viaRomagna)), model.lordo(.viaRomagna))
                }
                card("MEDIA A NOTTE", model.notti > 0 ? eurc(model.lordo() / model.notti) : "—", PSE.text)
            }
        }
    }

    /// La domanda vera: l'affitto che abbiamo incassato è bastato a pagare
    /// mutuo e utenze? Due barre, una sotto l'altra, sulla stessa scala.
    private var affittiVsCosti: some View {
        let gen = model.nettoAffitti()
        let mutuo = model.usciteGruppo(.mutuo)
        let utenze = model.usciteGruppo(.utenze)
        let costi = mutuo + utenze
        let scala = CGFloat(max(gen, costi, 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("L'AFFITTO È BASTATO A PAGARE MUTUO E UTENZE?")
                    .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                targhetta(etichetta)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                cardClic("GENERATO DAGLI AFFITTI", eurc(gen), PSE.pos) {
                    apri("Affitti netti", "Tutto quello che gli ospiti hanno pagato, tolte le commissioni.",
                         model.righe(model.affitti, netto: true), gen)
                }
                cardClic("MUTUO", inUscita(mutuo), mutuo > 0 ? PSE.neg : PSE.faint) { apriGruppo(.mutuo, casa: nil) }
                cardClic("UTENZE", inUscita(utenze), utenze > 0 ? PSE.neg : PSE.faint) { apriGruppo(.utenze, casa: nil) }
                card("RESTA", (gen - costi >= 0 ? "" : "−") + eurc(abs(gen - costi)),
                     gen - costi >= 0 ? PSE.pos : PSE.neg)
            }
            VStack(spacing: 7) {
                barraConfronto("Affitti incassati", gen, scala, PSE.pos)
                barraConfronto("Mutuo + utenze", costi, scala, PSE.neg)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
            tabellaAffittiVsCosti
        }
    }

    private func barraConfronto(_ titolo: String, _ v: Int, _ scala: CGFloat, _ colore: Color) -> some View {
        HStack(spacing: 10) {
            Text(titolo).font(.system(size: 11)).foregroundStyle(PSE.dim)
                .frame(width: 140, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04))
                    RoundedRectangle(cornerRadius: 4).fill(colore.opacity(0.6))
                        .frame(width: max(2, g.size.width * CGFloat(v) / scala))
                }
            }
            .frame(height: 16)
            Text(eurc(v)).font(.system(size: 12, weight: .bold)).foregroundStyle(colore)
                .monospacedDigit().frame(width: 100, alignment: .trailing)
        }
    }

    /// Lo stesso conto, casa per casa: chi si ripaga e chi no.
    private var tabellaAffittiVsCosti: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("CASA · \(periodo)").font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(["AFFITTI", "MUTUO", "UTENZE", "RESTA"], id: \.self) { t in
                    Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                        .frame(width: 110, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider().overlay(PSE.line)
            ForEach([StoCasa.viaPo, .viaRomagna]) { c in
                let g = model.nettoAffitti(c), mu = model.usciteGruppo(.mutuo, casa: c), ut = model.usciteGruppo(.utenze, casa: c)
                HStack(spacing: 10) {
                    Text(c.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(eurc(g)).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.pos)
                        .monospacedDigit().frame(width: 110, alignment: .trailing)
                    cella(mu, larghezza: 110) { apriGruppo(.mutuo, casa: c) }
                    cella(ut, larghezza: 110) { apriGruppo(.utenze, casa: c) }
                    Text((g - mu - ut >= 0 ? "" : "−") + eurc(abs(g - mu - ut)))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(g - mu - ut >= 0 ? PSE.pos : PSE.neg)
                        .monospacedDigit().frame(width: 110, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider().overlay(PSE.line).padding(.leading, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── I due blocchi: investimento contro gestione ────────────────────────
    private func totBlocco(_ b: StoBlocco, casa: StoCasa? = nil) -> Int {
        b.gruppi.reduce(0) { $0 + model.usciteGruppo($1, casa: casa) }
    }

    /// La barra di confronto: quanto delle uscite è finito dentro le case e
    /// quanto se n'è andato in gestione. È la risposta in una riga sola.
    private var confronto: some View {
        let inv = totBlocco(.investimento), ges = totBlocco(.gestione), fin = totBlocco(.finanziamento)
        // Le restituzioni non entrano nel totale né nella percentuale: sono
        // soldi tornati a chi li aveva messi, non una spesa.
        let tot = max(1, inv + ges)
        return VStack(alignment: .leading, spacing: 10) {
            Text("DOVE SONO ANDATI I SOLDI").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
            HStack(spacing: 10) {
                cardClic("INVESTIMENTO NELLE CASE", eurc(inv), PSE.accent) { apriBlocco(.investimento, casa: nil) }
                cardClic("GESTIONE", eurc(ges), PSE.warn) { apriBlocco(.gestione, casa: nil) }
                card("TOTALE SPESO", eurc(inv + ges), PSE.text)
                card("QUOTA INVESTIMENTO", "\(Int((Double(inv) / Double(tot) * 100).rounded()))%", PSE.accent)
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 4).fill(PSE.accent.opacity(0.75))
                        .frame(width: max(2, g.size.width * CGFloat(inv) / CGFloat(tot)))
                    RoundedRectangle(cornerRadius: 4).fill(PSE.warn.opacity(0.7))
                }
            }
            .frame(height: 14)
            if fin != 0 {
                Button { apriBlocco(.finanziamento, casa: nil) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.uturn.left").font(.system(size: 10)).foregroundStyle(PSE.faint)
                        Text("Restituzioni: \(eurc(fin)) tornati ai soci e a chi aveva prestato. Non sono una spesa e restano fuori dal totale qui sopra.")
                            .font(.system(size: 11)).foregroundStyle(PSE.faint)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(PSE.faint)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Un blocco: la ciambella con la sua composizione, e accanto la tabella
    /// per casa. Ogni fetta e ogni cella si aprono.
    private func blocco(_ b: StoBlocco) -> some View {
        let voci = b.gruppi.map { ($0, model.usciteGruppo($0)) }.filter { $0.1 != 0 }
        let tot = totBlocco(b)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(b.rawValue).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                Spacer()
                Text(eurc(tot)).font(.system(size: 13, weight: .bold)).foregroundStyle(b.colore).monospacedDigit()
            }
            Text(b.sottotitolo).font(.system(size: 11)).foregroundStyle(PSE.faint)
            HStack(alignment: .top, spacing: 12) {
                ciambella(voci, totale: tot, colore: b.colore)
                    .frame(width: 300)
                grigliaGruppi(b.gruppi)
            }
            if b == .investimento { comeLabbiamoPagato(tot) }
        }
    }

    /// Sotto l'investimento: chi ci ha messo i soldi. Senza questo sembra che
    /// 322.000 € siano usciti tutti dalle tasche dei due soci.
    private func comeLabbiamoPagato(_ investimento: Int) -> some View {
        let mutui = model.mutuiErogati, prestiti = model.prestitiRicevuti
        let affitti = model.affittiReinvestiti, soci = model.messoDaiSoci
        let banche = mutui + prestiti
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("COME L'ABBIAMO PAGATO").font(.system(size: 9, weight: .heavy)).tracking(0.9).foregroundStyle(PSE.faint)
                Spacer()
            }
            HStack(spacing: 10) {
                cardClic("MUTUI EROGATI", eurc(mutui), PSE.accent) {
                    apri("Mutui erogati", "Quello che la banca ha messo sul conto.",
                         model.righe(model.movimenti.filter { $0.tipo == "entrata" && $0.pagato_da == "Mutuo" }), mutui)
                }
                cardClic("PRESTITI RICEVUTI", eurc(prestiti), PSE.accent) {
                    apri("Prestiti senza interessi", "Soldi prestati da fuori, da restituire.",
                         model.righe(model.movimenti.filter { $0.tipo == "entrata" && $0.pagato_da == "Prestito Infrutifero" }), prestiti)
                }
                cardClic("REINVESTITO DAGLI AFFITTI", eurc(affitti), PSE.pos) {
                    apri("Reinvestito dagli affitti", "Incassi delle camere rimessi dentro invece che presi.",
                         model.righe(model.movimenti.filter { $0.tipo == "entrata" && $0.pagato_da == "Affiti" }), affitti)
                }
                cardClic("MESSO DAI SOCI", eurc(soci), PSE.text) {
                    apri("Messo dai soci — dove è finito",
                         "Giorgio \(eurc(model.apportiDi("Giorgio"))) e Giacomo \(eurc(model.apportiDi("Giacomo"))) in questo periodo, già al netto delle restituzioni. Clic su un nome per vedere i pagamenti.",
                         model.righe(model.apportiDelPeriodo), soci, fornitori: .apporti)
                }
                cardClic("GIÀ RESTITUITO", inUscita(model.restituito), model.restituito > 0 ? PSE.dim : PSE.faint) {
                    apriGruppo(.prestiti, casa: nil)
                }
            }
            if model.prestitoAgos > 0 { rigaAgos }
            Text("Dei \(eurc(investimento)) investiti, **\(eurc(banche))** sono arrivati da banca e prestiti — soldi da restituire, non nostri. Il resto l'hanno messo i soci (\(eurc(soci)), già al netto delle restituzioni) e gli affitti reinvestiti (\(eurc(affitti))). Le cifre non tornano al centesimo perché una parte di questi soldi ha pagato anche la gestione, non solo l'investimento.")
                .font(.system(size: 11)).foregroundStyle(PSE.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
    }

    /// Grafico a ciambella disegnato a mano: niente librerie, stesso stile
    /// scuro del resto della pagina. Ogni fetta apre il suo dettaglio.
    private func ciambella(_ voci: [(StoGruppo, Int)], totale: Int, colore: Color) -> some View {
        let tot = max(1, totale)
        var acc: Double = 0
        var fette: [(StoGruppo, Int, Double, Double, Color)] = []
        for (i, v) in voci.enumerated() {
            let q = Double(v.1) / Double(tot)
            let op = 0.85 - Double(i) * (0.55 / Double(max(1, voci.count)))
            fette.append((v.0, v.1, acc, acc + q, colore.opacity(op)))
            acc += q
        }
        return VStack(spacing: 10) {
            ZStack {
                ForEach(fette.indices, id: \.self) { i in
                    Circle()
                        .trim(from: fette[i].2, to: fette[i].3)
                        .stroke(fette[i].4, style: StrokeStyle(lineWidth: 26, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .padding(16)
                }
                VStack(spacing: 2) {
                    Text(eurc(totale)).font(.system(size: 14, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                    Text("\(voci.count) voci").font(.system(size: 9.5)).foregroundStyle(PSE.faint)
                }
            }
            .frame(height: 150)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(fette.indices, id: \.self) { i in
                    Button {
                        apriGruppo(fette[i].0, casa: nil)
                    } label: {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(fette[i].4).frame(width: 9, height: 9)
                            Text(fette[i].0.rawValue).font(.system(size: 11)).foregroundStyle(PSE.dim).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int((Double(fette[i].1) / Double(tot) * 100).rounded()))%")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(PSE.faint).monospacedDigit()
                            Text(eurc(fette[i].1)).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PSE.text).monospacedDigit().frame(width: 88, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    private func apriBlocco(_ b: StoBlocco, casa: StoCasa?) {
        let m = b.gruppi.flatMap { model.mov(casa, tipo: "uscita", gruppo: $0) }
        let s = b.gruppi.flatMap { model.spese(casa, gruppo: $0) }
        apri(b.rawValue.components(separatedBy: " — ").first ?? b.rawValue, b.sottotitolo,
             model.righe(m) + model.righe(s), totBlocco(b, casa: casa), fornitori: .spese)
    }

    /// Il prestito Agos in evidenza: è la voce più fraintendibile di tutte.
    private var rigaAgos: some View {
        let resta = model.prestitoAgos - model.agosRimborsato
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(PSE.warn)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("PRESTITO AGOS DUCATO").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.warn)
                    Text("conta a parte").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(PSE.warn.opacity(0.85)))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    cardClic("ENTRATO", eurc(model.prestitoAgos), PSE.warn) {
                        apri("Prestito Agos Ducato", "Intestato a Giacomo, versato sul conto della società il 05/06/2025.",
                             model.righe(model.movimenti.filter { $0.pagato_da == "Prestito Agos" }), model.prestitoAgos)
                    }
                    cardClic("GIÀ RIMBORSATO DAL CONTO", inUscita(model.agosRimborsato), PSE.warn) {
                        apri("Rate del prestito Agos", "Addebiti SDD da 318,38 € al mese sul conto Carifermo: le paga la società, non Giacomo.",
                             model.righe(model.movimenti.filter { $0.categoria == "Rata prestito Agos" }), model.agosRimborsato)
                    }
                    card("RESTA DA RIMBORSARE", eurc(resta), PSE.warn)
                }
                Text("È intestato a Giacomo, ma le rate le paga la società: 318,38 €/mese, sette per addebito SDD sul conto Carifermo e tre in contanti (marzo, maggio e giugno 2026). Come lo si conta cambia il conguaglio di oltre 10.000 €, quindi qui sotto ci sono tutti e due i modi.")
                    .font(.system(size: 11)).foregroundStyle(PSE.dim)
                    .fixedSize(horizontal: false, vertical: true)
                scenariAgos
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.warn.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.warn.opacity(0.35), lineWidth: 1))
    }

    /// I due modi di leggere l'Agos, affiancati: quanto deve Giacomo in ognuno.
    private var scenariAgos: some View {
        HStack(alignment: .top, spacing: 10) {
            scenario(
                lettera: "A",
                titolo: "I 24.000 sono suoi",
                sottotitolo: "Apporto di Giacomo, il prestito se lo gestisce lui",
                cifra: model.conguaglioAgosSuoi,
                attivo: false,
                conti: [
                    ("Apporti Giacomo", "\(eurc(model.totaleSocio("Giacomo"))) + \(eurc(model.prestitoAgos)) = \(eurc(model.totaleSocio("Giacomo") + model.prestitoAgos))"),
                    ("Apporti Giorgio", eurc(model.totaleSocio("Giorgio"))),
                    ("Rate già pagate dalla società", "\(eurc(model.agosRimborsato)) → gliele deve rendere")
                ])
            scenario(
                lettera: "B",
                titolo: "È un prestito della società",
                sottotitolo: "Non è apporto di nessuno: il debito lo dividono a metà",
                cifra: model.conguaglioAgosSocieta,
                attivo: true,
                conti: [
                    ("Apporti Giacomo", eurc(model.totaleSocio("Giacomo"))),
                    ("Apporti Giorgio", eurc(model.totaleSocio("Giorgio"))),
                    ("Debito che resta", "\(eurc(model.prestitoAgos - model.agosRimborsato)) a carico dei due")
                ])
        }
        .padding(.top, 2)
    }

    private func scenario(lettera: String, titolo: String, sottotitolo: String,
                          cifra: Int, attivo: Bool, conti: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(lettera).font(.system(size: 9, weight: .black))
                    .foregroundStyle(attivo ? .white : PSE.warn)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(attivo ? PSE.warn : PSE.warn.opacity(0.16)))
                Text(titolo).font(.system(size: 11, weight: .bold)).foregroundStyle(PSE.ink)
                Spacer(minLength: 0)
                if attivo {
                    Text("attivo oggi").font(.system(size: 8, weight: .bold)).foregroundStyle(PSE.warn)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(PSE.warn.opacity(0.16)))
                }
            }
            Text(sottotitolo).font(.system(size: 9.5)).foregroundStyle(PSE.faint)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(PSE.line)
            ForEach(conti.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Text(conti[i].0).font(.system(size: 9.5)).foregroundStyle(PSE.faint)
                    Spacer(minLength: 4)
                    Text(conti[i].1).font(.system(size: 9.5, weight: .medium)).foregroundStyle(PSE.dim)
                        .multilineTextAlignment(.trailing)
                }
            }
            Divider().overlay(PSE.line)
            Text("GIACOMO DEVE A GIORGIO").font(.system(size: 8, weight: .heavy)).tracking(0.6)
                .foregroundStyle(PSE.faint)
            Text(eurc(cifra)).font(.system(size: 19, weight: .bold)).foregroundStyle(PSE.warn)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(attivo ? 0.22 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(PSE.warn.opacity(attivo ? 0.42 : 0.18), lineWidth: attivo ? 1.2 : 1))
    }

    /// Le uscite per gruppo, ognuna spaccata per casa. Ogni cella si apre.
    private func grigliaGruppi(_ soloQuesti: [StoGruppo]) -> some View {
        let gruppi = soloQuesti.filter { model.usciteGruppo($0) != 0 }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("GRUPPO").font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(StoCasa.allCases) { c in
                    Text(c.breve.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
                        .foregroundStyle(PSE.faint).frame(width: 105, alignment: .trailing)
                }
                Text("TOTALE").font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                    .frame(width: 115, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider().overlay(PSE.line)
            ForEach(gruppi) { g in
                rigaGruppo(g)
                Divider().overlay(PSE.line).padding(.leading, 14)
            }
            rigaTotaleGruppi(gruppi)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    private func rigaGruppo(_ g: StoGruppo) -> some View {
        HStack(spacing: 10) {
            Text(g.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.text)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            ForEach(StoCasa.allCases) { c in
                cella(model.usciteGruppo(g, casa: c), larghezza: 105) { apriGruppo(g, casa: c) }
            }
            cella(model.usciteGruppo(g), larghezza: 115, forte: true) { apriGruppo(g, casa: nil) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func rigaTotaleGruppi(_ gruppi: [StoGruppo]) -> some View {
        HStack(spacing: 10) {
            Text("TOTALE").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(StoCasa.allCases) { c in
                let t = gruppi.reduce(0) { $0 + model.usciteGruppo($1, casa: c) }
                Text(eurc(t)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(PSE.neg)
                    .monospacedDigit().frame(width: 105, alignment: .trailing)
            }
            let tot = gruppi.reduce(0) { $0 + model.usciteGruppo($1) }
            Text(eurc(tot)).font(.system(size: 13.5, weight: .bold)).foregroundStyle(PSE.accent)
                .monospacedDigit().frame(width: 115, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white.opacity(0.04))
    }

    /// Una cella di numero: cliccabile se c'è qualcosa dentro.
    private func cella(_ v: Int, larghezza: CGFloat, forte: Bool = false, _ azione: @escaping () -> Void) -> some View {
        Group {
            if v == 0 {
                Text("—").font(.system(size: 12)).foregroundStyle(PSE.faint)
                    .frame(width: larghezza, alignment: .trailing)
            } else {
                Button(action: azione) {
                    Text(eurc(v))
                        .font(.system(size: forte ? 12.5 : 12, weight: forte ? .bold : .semibold))
                        .foregroundStyle(forte ? PSE.ink : PSE.text)
                        .monospacedDigit().frame(width: larghezza, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func apriGruppo(_ g: StoGruppo, casa: StoCasa?) {
        let m = model.mov(casa, tipo: "uscita", gruppo: g)
        let s = model.spese(casa, gruppo: g)
        let dove = casa?.rawValue ?? "tutte le case"
        let nota = s.isEmpty ? "" : "Comprende \(s.count) righe della tabella «spese di alloggio», che in Tesoreria stanno nella scheda Servizi."
        apri("\(g.rawValue) · \(dove)", nota, model.righe(m) + model.righe(s),
             model.usciteGruppo(g, casa: casa), fornitori: .spese)
    }

    private var cardsSoci: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                cardClic("APPORTI GIORGIO", eurc(model.apportiDi("Giorgio")), PSE.text) { apriApporti("Giorgio") }
                cardClic("APPORTI GIACOMO", eurc(model.apportiDi("Giacomo")), PSE.text) { apriApporti("Giacomo") }
                cardClic("CONGUAGLIO TOTALE", eurc(abs(model.conguaglio)), PSE.accent) { apriConguaglio() }
                cardClic("DA INCASSARE", eurc(model.pendenteTotale), PSE.warn) {
                    apri("Da incassare", "Crediti verso clienti e inquilini, tutti da verificare.",
                         model.pendenti.map { DettaglioRiga(id: $0.id, data: stoData($0.data_avviso),
                                                            descrizione: $0.concetto ?? "—", extra: $0.origine ?? "",
                                                            importo: $0.importo_cents, positivo: true) },
                         model.pendenteTotale)
                }
            }
            Text("Le prime due card sono di questo periodo; il conguaglio invece è su tutto lo storico, perché è uno solo. Contano solo le righe marcate «conta»: le rate pagate con l'incasso degli affitti e i rimborsi già risolti restano fuori. Il lavoro dei genitori di Giacomo non è contato (decisione del 27/07/26).")
                .font(.system(size: 11)).foregroundStyle(PSE.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Gli apporti di un socio, raggruppati per dove sono finiti i soldi:
    /// stessa tabella «a chi» delle spese, così si vede chi ha pagato cosa.
    private func apriApporti(_ socio: String) {
        let righe = model.apporti(socio)
        apri("Apporti di \(socio) — dove sono finiti", "Solo le righe che contano nel conguaglio. Le restituzioni stanno dentro col segno meno. Clic su un nome per vedere i pagamenti.",
             model.righe(righe), model.apportiDi(socio), fornitori: .apporti)
    }

    /// Il conguaglio spiegato riga per riga: prima il conto in quattro passi,
    /// poi tutto quello che ha messo ciascuno, poi quello che resta fuori.
    private func apriConguaglio() {
        let g = model.totaleSocio("Giorgio"), gi = model.totaleSocio("Giacomo")
        let chi = g >= gi ? "Giacomo deve a Giorgio" : "Giorgio deve a Giacomo"
        var righe: [DettaglioRiga] = [
            DettaglioRiga(id: "c1", descrizione: "Messo da Giorgio (righe che contano)", extra: "somma", importo: g, positivo: true, mostraSegno: false),
            DettaglioRiga(id: "c2", descrizione: "Messo da Giacomo (righe che contano)", extra: "somma", importo: gi, positivo: true, mostraSegno: false),
            DettaglioRiga(id: "c3", descrizione: "Differenza fra i due", extra: "\(eurc(g)) − \(eurc(gi))", importo: abs(g - gi), positivo: true, mostraSegno: false),
            DettaglioRiga(id: "c4", descrizione: "\(chi) — metà della differenza", extra: "÷ 2", importo: abs(model.conguaglio), positivo: true, mostraSegno: false)
        ]
        righe.append(DettaglioRiga(id: "s1", descrizione: "———  QUELLO CHE HA MESSO GIORGIO  ———", importo: 0, mostraSegno: false))
        righe += model.righe(model.apportiTutti.filter { $0.socio == "Giorgio" && $0.conta })
        righe.append(DettaglioRiga(id: "s2", descrizione: "———  QUELLO CHE HA MESSO GIACOMO  ———", importo: 0, mostraSegno: false))
        righe += model.righe(model.apportiTutti.filter { $0.socio == "Giacomo" && $0.conta })
        let fuori = model.apportiTutti.filter { !$0.conta }
        if !fuori.isEmpty {
            righe.append(DettaglioRiga(id: "s3", descrizione: "———  REGISTRATO MA FUORI DAL CONTO  ———", importo: 0, mostraSegno: false))
            righe += model.righe(fuori)
        }
        dettaglio = StoricoDettaglio(
            id: "conguaglio", titolo: "Conguaglio fra i soci — tutto lo storico",
            nota: "Ognuno dovrebbe metterci la metà. Si sommano gli apporti di uno e dell'altro, si fa la differenza e si divide per due: quella è la cifra che riequilibra. Le restituzioni (il mutuo di liquidità ridato ai soci) stanno dentro con il segno meno, perché sono soldi tornati indietro. In fondo, le righe registrate che NON entrano nel conto e perché.",
            righe: righe, totale: abs(model.conguaglio))
    }

    // ══ REPORT PDF ═════════════════════════════════════════════════════════
    /// Il report di tutto il periodo, o di una casa sola.
    private func report(_ casa: StoCasa?) -> StoricoReport {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; f.locale = Locale(identifier: "it_IT")
        var r = StoricoReport(titolo: casa?.rawValue ?? "Tutte le case",
                              periodo: etichetta, intervallo: intervallo,
                              generatoIl: f.string(from: Date()))
        r.lordo = model.lordo(casa); r.commissioni = model.commissioni(casa); r.netto = model.nettoAffitti(casa)
        r.speseAlloggio = model.totSpese(casa)
        r.soggiorni = model.soggiorni(casa); r.notti = model.notti(casa)
        r.lordoViaPo = model.lordo(.viaPo); r.lordoViaRomagna = model.lordo(.viaRomagna)
        r.mutuo = model.usciteGruppo(.mutuo, casa: casa); r.utenze = model.usciteGruppo(.utenze, casa: casa)
        func righe(_ gruppi: [StoGruppo]) -> [RigaReport] {
            gruppi.compactMap { g in
                let po = casa == nil || casa == .viaPo ? model.usciteGruppo(g, casa: .viaPo) : 0
                let ro = casa == nil || casa == .viaRomagna ? model.usciteGruppo(g, casa: .viaRomagna) : 0
                let co = casa == nil || casa == .mixto ? model.usciteGruppo(g, casa: .mixto) : 0
                return po + ro + co == 0 ? nil : RigaReport(voce: g.rawValue, viaPo: po, viaRomagna: ro, comune: co)
            }
        }
        r.investimento = righe(StoBlocco.investimento.gruppi)
        r.gestione = righe(StoBlocco.gestione.gruppi)
        r.restituzioni = model.usciteGruppo(.prestiti, casa: casa)
        r.giorgio = model.totaleSocio("Giorgio"); r.giacomo = model.totaleSocio("Giacomo")
        r.conguaglio = model.conguaglio
        r.mostraSoci = casa == nil
        r.mutui = model.mutuiErogati; r.prestiti = model.prestitiRicevuti
        r.affittiReinvestiti = model.affittiReinvestiti
        r.messoDaiSoci = model.messoDaiSoci; r.restituito = model.restituito
        // a chi: sull'investimento
        let m = StoBlocco.investimento.gruppi.flatMap { model.mov(casa, tipo: "uscita", gruppo: $0) }
        r.fornitori = Dictionary(grouping: model.righe(m), by: { storicoFornitore($0.descrizione) })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.importo }) }
            .sorted { $0.1 > $1.1 }
        if casa == nil {
            r.case_ = [StoCasa.viaPo, .viaRomagna].map {
                ($0.rawValue, model.nettoAffitti($0), model.usciteGruppo(.mutuo, casa: $0), model.usciteGruppo(.utenze, casa: $0))
            }
        }
        return r
    }

    private func bottoneReport(_ casa: StoCasa?) -> some View {
        Button { StoricoPDF.salva(report(casa)) } label: {
            Label("PDF", systemImage: "arrow.down.doc").font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(PSE.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PSE.line, lineWidth: 1))
                .foregroundStyle(PSE.dim)
        }
        .buttonStyle(.plain)
        .help("Scarica il riepilogo in PDF, pronto da mandare al socio")
    }

    // ══ PER CASA ═══════════════════════════════════════════════════════════
    // Ogni casa raccontata in tre pezzi, nell'ordine in cui uno se li chiede:
    // cosa ha reso · quanto costa tenerla aperta · quanto ci abbiamo messo
    // dentro. In cima il verdetto: si mantiene da sola o no.
    private var perCasa: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([StoCasa.viaPo, .viaRomagna, .mixto]) { c in
                if haQualcosa(c) { bloccoCasa(c) }
            }
        }
    }

    private func haQualcosa(_ c: StoCasa) -> Bool {
        model.nettoAffitti(c) != 0 || StoGruppo.allCases.contains { model.usciteGruppo($0, casa: c) != 0 }
    }

    private func correnti(_ c: StoCasa) -> Int { StoBlocco.gestione.gruppi.reduce(0) { $0 + model.usciteGruppo($1, casa: c) } }
    private func investito(_ c: StoCasa) -> Int { StoBlocco.investimento.gruppi.reduce(0) { $0 + model.usciteGruppo($1, casa: c) } }

    private func bloccoCasa(_ c: StoCasa) -> some View {
        let reso = model.nettoAffitti(c)
        let costi = correnti(c)
        let saldo = reso - costi
        return VStack(alignment: .leading, spacing: 0) {
            testataCasa(c, saldo: saldo)
            Divider().overlay(PSE.line)
            VStack(alignment: .leading, spacing: 14) {
                cardsCasa(c, reso: reso, costi: costi, saldo: saldo)
                if reso > 0 || costi > 0 { barreCasa(reso: reso, costi: costi) }
                elencoCasa("QUANTO COSTA TENERLA APERTA", StoBlocco.gestione.gruppi, c, costi, PSE.warn)
                elencoCasa("QUANTO CI ABBIAMO MESSO DENTRO", StoBlocco.investimento.gruppi, c, investito(c), PSE.accent)
                entrateCasa(c)
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    private func testataCasa(_ c: StoCasa, saldo: Int) -> some View {
        HStack(spacing: 10) {
            Text(c.rawValue.uppercased()).font(.system(size: 13, weight: .heavy)).tracking(1.2).foregroundStyle(PSE.ink)
            targhetta(etichetta)
            if c != .mixto {
                let ok = saldo >= 0
                HStack(spacing: 5) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(ok ? "si mantiene da sola" : "non si mantiene da sola")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(ok ? PSE.pos : PSE.neg)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill((ok ? PSE.pos : PSE.neg).opacity(0.12)))
            }
            Spacer(minLength: 0)
            if c != .mixto, model.soggiorni(c) > 0 {
                Text("\(model.soggiorni(c)) soggiorni · \(model.notti(c)) notti")
                    .font(.system(size: 10.5)).foregroundStyle(PSE.faint).monospacedDigit()
            }
            bottoneReport(c)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func cardsCasa(_ c: StoCasa, reso: Int, costi: Int, saldo: Int) -> some View {
        HStack(spacing: 10) {
            cardClic("HA RESO", eurc(reso), reso > 0 ? PSE.pos : PSE.faint) {
                apri("Affitti netti · \(c.rawValue)", "Quello che hanno pagato gli ospiti, tolte le commissioni.",
                     model.righe(model.affitti(c), netto: true), reso)
            }
            cardClic("COSTI CORRENTI", inUscita(costi), costi > 0 ? PSE.warn : PSE.faint) {
                apriBlocco(.gestione, casa: c)
            }
            card("SALDO CORRENTE", (saldo >= 0 ? "" : "−") + eurc(abs(saldo)), saldo >= 0 ? PSE.pos : PSE.neg)
            cardClic("INVESTITO NELLA CASA", eurc(investito(c)), PSE.accent) {
                apriBlocco(.investimento, casa: c)
            }
        }
    }

    private func barreCasa(reso: Int, costi: Int) -> some View {
        let scala = CGFloat(max(reso, costi, 1))
        return VStack(spacing: 7) {
            barraConfronto("Affitti incassati", reso, scala, PSE.pos)
            barraConfronto("Costi correnti", costi, scala, PSE.warn)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
    }

    /// Un elenco di voci con la loro barretta: si capisce al volo chi pesa.
    @ViewBuilder
    private func elencoCasa(_ titolo: String, _ gruppi: [StoGruppo], _ c: StoCasa, _ totale: Int, _ colore: Color) -> some View {
        let voci = gruppi.map { ($0, model.usciteGruppo($0, casa: c)) }.filter { $0.1 != 0 }
        if !voci.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(titolo).font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                    Spacer()
                    Text(eurc(totale)).font(.system(size: 11.5, weight: .bold)).foregroundStyle(colore).monospacedDigit()
                }
                ForEach(voci, id: \.0) { v in
                    Button { apriGruppo(v.0, casa: c) } label: {
                        HStack(spacing: 10) {
                            Text(v.0.rawValue).font(.system(size: 11.5)).foregroundStyle(PSE.text)
                                .frame(width: 175, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                let q = totale > 0 ? CGFloat(v.1) / CGFloat(totale) : 0
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.04))
                                    RoundedRectangle(cornerRadius: 3).fill(colore.opacity(0.5))
                                        .frame(width: max(2, g.size.width * q))
                                }
                            }
                            .frame(height: 9)
                            Text(totale > 0 ? "\(Int((Double(v.1) / Double(totale) * 100).rounded()))%" : "—")
                                .font(.system(size: 10)).foregroundStyle(PSE.faint)
                                .monospacedDigit().frame(width: 34, alignment: .trailing)
                            Text(eurc(v.1)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.text)
                                .monospacedDigit().frame(width: 92, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(PSE.faint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func entrateCasa(_ c: StoCasa) -> some View {
        let e = model.totMov(c, tipo: "entrata")
        if e != 0 {
            Button { apri("Entrate · \(c.rawValue)", "Mutui, prestiti e rimborsi entrati in cassa. I soldi messi dai soci non stanno qui: sono nella scheda Soci, per non contarli due volte.", model.righe(model.mov(c, tipo: "entrata")), e) } label: {
                HStack(spacing: 8) {
                    Text("DA DOVE SONO ARRIVATI I SOLDI").font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
                    Text("mutui, prestiti, rimborsi").font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    Spacer()
                    Text(eurc(e)).font(.system(size: 11.5, weight: .bold)).foregroundStyle(PSE.pos).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(PSE.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // ══ AFFITTI ════════════════════════════════════════════════════════════
    private var affittiTab: some View {
        let righe = model.affitti(casa)
        return VStack(alignment: .leading, spacing: 10) {
            totali([("Lordo", righe.reduce(0) { $0 + $1.lordo_cents }, PSE.pos),
                    ("Commissioni", righe.reduce(0) { $0 + $1.commissione_cents }, PSE.neg),
                    ("Netto", righe.reduce(0) { $0 + $1.netto_cents }, PSE.text)])
            tabella(["Data", "Casa", "Camera", "Canale", "Notti", "Lordo", "Comm.", "Netto", "Fonte"],
                    [58, 88, 150, 68, 44, 82, 70, 82, 150]) {
                ForEach(righe) { r in
                    rigaTabella([
                        (stoData(r.data), 58, PSE.dim, false), (r.struttura ?? "—", 88, PSE.dim, false),
                        (r.camera ?? "—", 150, PSE.text, false), (r.canale ?? "—", 68, PSE.dim, false),
                        (r.notti.map(String.init) ?? "—", 44, PSE.dim, true),
                        (eurc(r.lordo_cents), 82, PSE.text, true),
                        (r.commissione_cents > 0 ? eurc(r.commissione_cents) : "—", 70, PSE.neg, true),
                        (eurc(r.netto_cents), 82, PSE.pos, true), (r.fonte ?? "—", 150, PSE.faint, false)
                    ], nota: r.note, modifica: { apriModifica(.affitto(r)) })
                }
            }
        }
    }

    // ══ MOVIMENTI ══════════════════════════════════════════════════════════
    private var movimentiTab: some View {
        let mov = model.mov(casa)
        let spe = model.spese(casa)
        let e = mov.filter { $0.tipo == "entrata" }.reduce(0) { $0 + $1.importo_cents }
        let u = mov.filter { $0.tipo == "uscita" }.reduce(0) { $0 + $1.importo_cents } + spe.reduce(0) { $0 + $1.importo_cents }
        return VStack(alignment: .leading, spacing: 10) {
            totali([("Entrate", e, PSE.pos), ("Uscite", u, PSE.neg), ("Netto", e - u, e - u >= 0 ? PSE.pos : PSE.neg)])
            tabella(["Data", "Casa", "Gruppo", "Descrizione", "Importo", "Chi", "Fonte"],
                    [58, 88, 130, 300, 90, 96, 140]) {
                ForEach(mov) { r in
                    rigaTabella([
                        (stoData(r.data), 58, PSE.dim, false), (r.struttura ?? "—", 88, PSE.dim, false),
                        (StoGruppo.da(r.categoria).rawValue, 130, PSE.text, false),
                        (r.descrizione ?? "—", 300, PSE.text, false),
                        ((r.tipo == "entrata" ? "" : "−") + eurc(r.importo_cents), 90,
                         r.tipo == "entrata" ? PSE.pos : PSE.neg, true),
                        (r.pagato_da ?? "—", 96, PSE.dim, false), (r.fonte ?? "—", 140, PSE.faint, false)
                    ], nota: r.note, daVerificare: !r.verificato, modifica: { apriModifica(.movimento(r)) })
                }
                ForEach(spe) { r in
                    rigaTabella([
                        (stoData(r.data), 58, PSE.dim, false), (r.struttura ?? "—", 88, PSE.dim, false),
                        (StoGruppo.da(r.categoria).rawValue, 130, PSE.text, false),
                        (r.descrizione ?? "—", 300, PSE.text, false),
                        ("−" + eurc(r.importo_cents), 90, PSE.neg, true),
                        ("alloggio", 96, PSE.dim, false), (r.fonte ?? "—", 140, PSE.faint, false)
                    ], nota: r.note, modifica: { apriModifica(.spesa(r)) })
                }
            }
        }
    }

    // ══ SOCI ═══════════════════════════════════════════════════════════════
    private var sociTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(["Giorgio", "Giacomo"], id: \.self) { s in
                    cardClic("\(s.uppercased()) (CONTA)", eurc(model.apportiDi(s)), PSE.text) { apriApporti(s) }
                }
                let fuori = model.apporti.filter { !$0.conta }
                cardClic("FUORI CONGUAGLIO", eurc(fuori.reduce(0) { $0 + $1.importo_cents }), PSE.faint) {
                    apri("Righe fuori dal conguaglio",
                         "Registrate ma non contate: rate pagate con l'incasso degli affitti, rimborsi e doppioni già risolti.",
                         model.righe(fuori), fuori.reduce(0) { $0 + $1.importo_cents })
                }
            }
            ForEach(["Giorgio", "Giacomo"], id: \.self) { socio in
                VStack(alignment: .leading, spacing: 6) {
                    Text(socio.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                    tabella(["Data", "Casa", "Descrizione", "Importo", "Conta", "Fonte"], [58, 88, 320, 96, 52, 140]) {
                        ForEach(model.apporti(socio, soloConta: false)) { r in
                            rigaTabella([
                                (stoData(r.data), 58, PSE.dim, false), (r.struttura ?? "—", 88, PSE.dim, false),
                                (r.descrizione ?? "—", 320, r.conta ? PSE.text : PSE.faint, false),
                                ((r.importo_cents < 0 ? "−" : "") + eurc(abs(r.importo_cents)), 96,
                                 r.importo_cents < 0 ? PSE.neg : PSE.text, true),
                                (r.conta ? "sì" : "no", 52, r.conta ? PSE.pos : PSE.faint, false),
                                (r.fonte ?? "—", 140, PSE.faint, false)
                            ], nota: r.note, modifica: { apriModifica(.apporto(r)) })
                        }
                    }
                }
            }
        }
    }

    // ══ DA INCASSARE ═══════════════════════════════════════════════════════
    private var pendentiTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            totali([("Totale da incassare", model.pendenteTotale, PSE.warn)])
            tabella(["Avviso", "Concetto", "Importo", "Origine", "Stato"], [58, 340, 90, 90, 110]) {
                ForEach(model.pendenti) { r in
                    rigaTabella([
                        (stoData(r.data_avviso), 58, PSE.dim, false), (r.concetto ?? "—", 340, PSE.text, false),
                        (eurc(r.importo_cents), 90, PSE.warn, true), (r.origine ?? "—", 90, PSE.faint, false),
                        (r.stato ?? "—", 110, PSE.dim, false)
                    ], nota: r.note, modifica: { apriModifica(.pendente(r)) })
                }
            }
        }
    }

    // ══ PEZZI RIUSABILI ════════════════════════════════════════════════════
    /// Importo che esce, col meno davanti. A zero il meno non si mette: un
    /// «−€0,00» sembra un errore di conto.
    private func inUscita(_ cents: Int) -> String { cents > 0 ? "−" + eurc(cents) : eurc(cents) }

    /// Etichettina col periodo: piccola, ma toglie ogni dubbio su quale
    /// stagione si sta guardando.
    private func targhetta(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).tracking(0.4)
            .foregroundStyle(PSE.accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(PSE.accent.opacity(0.14)))
            .overlay(Capsule().strokeBorder(PSE.accent.opacity(0.3), lineWidth: 1))
    }

    private func avvisoBox(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(PSE.warn)
            Text(t).font(.system(size: 11.5)).foregroundStyle(PSE.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.warn.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.warn.opacity(0.28), lineWidth: 1))
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

    /// Card che si apre: stessa faccia, più la freccetta in alto a destra.
    private func cardClic(_ t: String, _ v: String, _ c: Color, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            card(t, v, c).overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PSE.faint).padding(10)
            }
        }
        .buttonStyle(.plain)
    }

    private func sezione<C: View>(_ titolo: String, @ViewBuilder _ contenuto: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titolo).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
            contenuto()
        }
    }

    private func totali(_ voci: [(String, Int, Color)]) -> some View {
        HStack(spacing: 18) {
            ForEach(voci.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(voci[i].0.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                    Text(eurc(voci[i].1)).font(.system(size: 13, weight: .bold)).foregroundStyle(voci[i].2).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tabella<C: View>(_ intestazione: [String], _ larghezze: [CGFloat], @ViewBuilder _ righe: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ForEach(intestazione.indices, id: \.self) { i in
                    Text(intestazione[i].uppercased())
                        .font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                        .frame(width: larghezze[i], alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(PSE.line)
            LazyVStack(spacing: 0) { righe() }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    private func rigaTabella(_ celle: [(String, CGFloat, Color, Bool)], nota: String?, daVerificare: Bool = false,
                             modifica: (() -> Void)? = nil) -> some View {
        let contenuto = HStack(spacing: 10) {
            ForEach(celle.indices, id: \.self) { i in
                Text(celle[i].0)
                    .font(.system(size: 11.5, weight: celle[i].3 ? .semibold : .regular))
                    .foregroundStyle(celle[i].2).monospacedDigit()
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: celle[i].1, alignment: celle[i].3 ? .trailing : .leading)
            }
            if daVerificare {
                Circle().fill(PSE.warn.opacity(0.75)).frame(width: 5, height: 5)
                    .help("Non contrastato con estratti o fatture")
            }
            Spacer(minLength: 0)
            if modifica != nil {
                Image(systemName: "square.and.pencil").font(.system(size: 10))
                    .foregroundStyle(PSE.faint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Rectangle().fill(Color.white.opacity(0.015)))
        .help(nota ?? "")
        return Group {
            if let modifica {
                Button(action: modifica) { contenuto.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else { contenuto }
        }
    }
}


/// Il dettaglio di un numero: le righe che lo compongono e, quando ha senso,
/// il totale per fornitore — «a chi sono andati i soldi», che è la domanda
/// che uno si fa davanti a 300.000 € di opera.
struct StoricoDettaglioSheet: View {
    let d: StoricoDettaglio
    let onClose: () -> Void
    /// Da una riga di questa finestra alla riga vera dell'archivio, quando c'è:
    /// i totali e i separatori non sono modificabili, una spesa sì. Restituisce
    /// nil per tutto ciò che è calcolato e non esiste in tabella.
    var bersaglio: ((DettaglioRiga) -> StoricoEditTarget?)? = nil
    /// Aprire la scheda di modifica: chiude questa e la passa a chi sa aprirla
    /// (la Tesoreria), perché due sheet uno sopra l'altro qui non convivono.
    var modifica: ((StoricoEditTarget) -> Void)? = nil
    @State private var mostraFornitori = true
    /// Fornitore aperto: sotto il suo nome compaiono tutti i suoi pagamenti.
    @State private var aperto: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(d.titolo).font(.system(size: 14, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                if !d.perFornitore.isEmpty {
                    PSESegmented(items: [(true, "A chi"), (false, "Righe")], selection: $mostraFornitori)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 10, trailing: 16))
            if !d.nota.isEmpty {
                Text(d.nota).font(.system(size: 11)).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(showsIndicators: false) {
                if mostraFornitori && !d.perFornitore.isEmpty { fornitori } else { righe }
            }
            HStack {
                Text("TOTALE").font(.system(size: 11, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
                Spacer()
                Text(eurc(d.totale)).font(.system(size: 15, weight: .bold)).foregroundStyle(PSE.accent).monospacedDigit()
            }
            .padding(.horizontal, 20).padding(.vertical, 12).background(Color.white.opacity(0.04))
        }
        .frame(width: 900, height: 620)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
    }

    /// «Conto società 27.950 · Giorgio 1.415». Se paga uno solo, il nome basta:
    /// ripetere la cifra accanto al totale della riga non aggiunge niente.
    private func chiHaPagato(_ p: [(nome: String, importo: Int)]) -> String {
        if p.count == 1 { return p[0].nome }
        return p.prefix(3).map { "\($0.nome) \(eurc($0.importo))" }.joined(separator: " · ")
             + (p.count > 3 ? " · +\(p.count - 3)" : "")
    }

    private var fornitori: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("A CHI  ·  CHI HA PAGATO").font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(PSE.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(["VIA PO", "VIA ROMAGNA", "COMUNE", "TOTALE"], id: \.self) { t in
                    Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                        .frame(width: t == "TOTALE" ? 110 : 100, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 9)
            Divider().overlay(PSE.line)
            ForEach(d.perFornitore) { f in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { aperto = (aperto == f.nome ? nil : f.nome) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: aperto == f.nome ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(PSE.faint).frame(width: 12)
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(f.nome).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink)
                                .lineLimit(1)
                            if !f.paganti.isEmpty {
                                Text(chiHaPagato(f.paganti))
                                    .font(.system(size: 9.5)).foregroundStyle(PSE.faint).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        soldi(f.viaPo, 100); soldi(f.viaRomagna, 100); soldi(f.comune, 100)
                        Text(eurc(f.totale)).font(.system(size: 13, weight: .bold)).foregroundStyle(PSE.accent)
                            .monospacedDigit().frame(width: 110, alignment: .trailing)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if aperto == f.nome {
                    VStack(spacing: 0) {
                        ForEach(f.righe) { r in
                            apribile(r) {
                                HStack(spacing: 12) {
                                    Text(r.data).font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.dim)
                                        .frame(width: 62, alignment: .leading).monospacedDigit()
                                    Text(r.descrizione).font(.system(size: 11.5)).foregroundStyle(PSE.text)
                                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                    Text(r.casa).font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                                        .frame(width: 82, alignment: .leading)
                                    Text(r.pagatoDa).font(.system(size: 10.5))
                                        .foregroundStyle(r.pagatoDa == "Da chiarire" ? PSE.warn.opacity(0.8) : PSE.faint)
                                        .frame(width: 104, alignment: .leading).lineLimit(1)
                                    importoTocco(eurc(r.importo), PSE.neg, 11.5, 90, r)
                                }
                                .padding(.horizontal, 20).padding(.vertical, 6)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.03))
                }
                Divider().overlay(PSE.line).padding(.leading, 20)
            }
        }
    }

    private func soldi(_ v: Int, _ w: CGFloat) -> some View {
        Text(v == 0 ? "—" : eurc(v))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(v == 0 ? PSE.faint : PSE.text)
            .monospacedDigit().frame(width: w, alignment: .trailing)
    }

    private var righe: some View {
        VStack(spacing: 0) {
            ForEach(d.righe) { r in
                apribile(r) {
                    HStack(spacing: 12) {
                        if !r.data.isEmpty {
                            Text(r.data).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
                                .frame(width: 62, alignment: .leading).monospacedDigit()
                        }
                        Text(r.descrizione).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        if !r.extra.isEmpty {
                            Text(r.extra).font(.system(size: 11)).foregroundStyle(PSE.faint)
                                .frame(width: 170, alignment: .leading).lineLimit(1)
                        }
                        importoTocco((r.mostraSegno ? (r.positivo ? "+" : "−") : "") + eurc(r.importo),
                                     r.positivo ? PSE.pos : PSE.neg, 13, 100, r)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 9)
                }
                Divider().overlay(PSE.line).padding(.leading, 20)
            }
        }
    }

    // ── correggere una cifra da qui ────────────────────────────────────────
    // Una cifra sbagliata la si vede leggendo il dettaglio, non tornando
    // indietro a cercarla nell'elenco: da qui la riga si apre e si corregge.
    // Le righe calcolate (totali, separatori, conguagli) non si aprono: non
    // esistono in nessuna tabella.
    private func target(_ r: DettaglioRiga) -> StoricoEditTarget? {
        guard modifica != nil else { return nil }
        return bersaglio?(r)
    }
    /// La cifra: sottolineata quando è modificabile, così si capisce che si tocca.
    private func importoTocco(_ testo: String, _ colore: Color, _ dim: CGFloat,
                              _ larghezza: CGFloat, _ r: DettaglioRiga) -> some View {
        Text(testo)
            .font(.system(size: dim, weight: .bold)).monospacedDigit()
            .foregroundStyle(colore)
            .underline(target(r) != nil, pattern: .dot, color: colore.opacity(0.5))
            .frame(width: larghezza, alignment: .trailing)
    }
    @ViewBuilder
    private func apribile<C: View>(_ r: DettaglioRiga, @ViewBuilder _ contenuto: () -> C) -> some View {
        if let t = target(r) {
            // Chiudere e riaprire nello stesso istante: la finestra di modifica
            // arriva mentre questa se ne sta ancora andando e non compare. Le si
            // lascia il tempo di uscire di scena.
            Button {
                onClose()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { modifica?(t) }
            } label: {
                contenuto().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clic per correggere questa riga")
        } else {
            contenuto()
        }
    }
}
