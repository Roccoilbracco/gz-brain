import Foundation

// ============================================================================
// I dati definitivi di un contratto, e come diventano testo.
//
// Il borrador porta le parole, questo porta i numeri. In mezzo c'è `riempi`,
// che sostituisce i {{segnaposto}}: alcuni sono un valore secco (il nome, il
// NIF), altri sono un blocco intero che esiste solo se serve — la tabella dei
// canoni se il canone cambia, la frase sull'aval solo se l'aval c'è.
//
// Le frasi generate seguono la lingua del borrador: un contratto spagnolo con
// dentro «a carico dell'inquilino» non lo firma nessuno.
// ============================================================================

// ── Chi paga cosa ────────────────────────────────────────────────────────────
enum CaricoSpesa: String, CaseIterable, Identifiable, Equatable {
    case inquilino, proprietario, incluso
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inquilino:    return "Inquilino"
        case .proprietario: return "Proprietario"
        case .incluso:      return "Incluso nel canone"
        }
    }
}

struct GastoVoce: Identifiable, Equatable {
    var id = UUID()
    var nome: String
    var carico: CaricoSpesa = .inquilino
    var nota: String = ""

    /// Le spese che ci sono praticamente sempre. Sono un punto di partenza:
    /// si tolgono e se ne aggiungono, l'elenco definitivo lo fa il contratto.
    static let standard: [GastoVoce] = [
        .init(nome: "Luz (electricidad)"),
        .init(nome: "Agua"),
        .init(nome: "Gas"),
        .init(nome: "Internet / fibra"),
        .init(nome: "Comunidad de propietarios", carico: .proprietario),
        .init(nome: "Basuras"),
        .init(nome: "IBI", carico: .proprietario),
        .init(nome: "Seguro del hogar", carico: .proprietario),
    ]
}

struct ClausolaExtra: Identifiable, Equatable {
    var id = UUID()
    var titolo: String = ""
    var testo: String = ""
}

/// Il canone di un singolo anno di contratto.
struct CanoneAnno: Identifiable, Equatable {
    var id = UUID()
    var anno: Int          // 1, 2, 3…
    var importo: Int
}

// ── Le persone e la cosa ─────────────────────────────────────────────────────
struct ParteContratto: Equatable {
    var nome = ""
    var nif = ""
    var direccion = ""
    var email = ""
    var telefono = ""
}

struct ImmobileContratto: Equatable {
    var direccion = ""
    var titolo = ""
    var referencia = ""
    var zona = ""
    var ciudad = "Ibiza"
    var m2 = ""
    var habitaciones = ""
    var banos = ""
    var catastro = ""
}

// ── I dati definitivi ────────────────────────────────────────────────────────
struct DatiContratto: Equatable {
    var lugar = "Ibiza"
    var data = Date()

    var proprietario = ParteContratto()
    var immobile = ImmobileContratto()
    var cliente = ParteContratto()

    var inizio = Date()
    var durataMesi = 12
    var canoneMensile = 0
    /// Canone diverso anno per anno. Quando è spento vale `canoneMensile` per
    /// tutta la durata.
    var canoneVariabile = false
    var canoniAnno: [CanoneAnno] = []

    var fianzaMesi = 1
    var fianzaImporto = 0
    var garanziaImporto = 0
    var garanziaNota = ""
    var avalAttivo = false
    var avalBanca = ""
    var avalImporto = 0

    var ipcAttivo = true
    var ipcIndice = "IPC general"
    var ipcNota = ""

    var gastos: [GastoVoce] = GastoVoce.standard
    var extras: [ClausolaExtra] = []

    var anni: Int { max(1, Int(ceil(Double(durataMesi) / 12.0))) }
    var fine: Date {
        Calendar.current.date(byAdding: .month, value: durataMesi, to: inizio)
            .flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) } ?? inizio
    }
    /// Canone del primo anno: è quello che va nella clausola della renta.
    var canonePrimoAnno: Int {
        canoneVariabile ? (canoniAnno.first(where: { $0.anno == 1 })?.importo ?? canoneMensile) : canoneMensile
    }

    /// Riallinea la tabella dei canoni alla durata: allungando il contratto
    /// compaiono gli anni nuovi col canone dell'ultimo, accorciandolo spariscono.
    mutating func sincronizzaCanoni() {
        var nuovi: [CanoneAnno] = []
        for a in 1...anni {
            if let esistente = canoniAnno.first(where: { $0.anno == a }) { nuovi.append(esistente) }
            else { nuovi.append(CanoneAnno(anno: a, importo: nuovi.last?.importo ?? canoneMensile)) }
        }
        canoniAnno = nuovi
    }

    /// La fianza segue le mensilità finché non la si scrive a mano.
    mutating func aggiornaFianzaDaMesi() { fianzaImporto = fianzaMesi * canonePrimoAnno }
}

// ── Le frasi, nella lingua del borrador ──────────────────────────────────────
struct FrasiContratto {
    let lingua: String

    private func s(_ es: String, _ it: String, _ en: String) -> String {
        switch lingua { case "it": return it; case "en": return en; default: return es }
    }

    var locale: Locale { Locale(identifier: lingua == "it" ? "it_IT" : (lingua == "en" ? "en_GB" : "es_ES")) }

    func dataEstesa(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = locale; f.dateFormat = s("d 'de' MMMM 'de' yyyy", "d MMMM yyyy", "d MMMM yyyy")
        return f.string(from: d)
    }
    func dataBreve(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = locale; f.dateFormat = "dd/MM/yyyy"
        return f.string(from: d)
    }
    func durata(_ mesi: Int) -> String {
        if mesi % 12 == 0 {
            let a = mesi / 12
            return a == 1 ? s("un año", "un anno", "one year")
                          : "\(a) " + s("años", "anni", "years")
        }
        return "\(mesi) " + s("meses", "mesi", "months")
    }
    func mensilita(_ n: Int) -> String {
        n == 1 ? s("una mensualidad", "una mensilità", "one month's rent")
               : "\(n) " + s("mensualidades", "mensilità", "months' rent")
    }
    func carico(_ c: CaricoSpesa) -> String {
        switch c {
        case .inquilino:    return s("a cargo de la parte arrendataria", "a carico dell'inquilino", "payable by the tenant")
        case .proprietario: return s("a cargo de la parte arrendadora", "a carico del proprietario", "payable by the landlord")
        case .incluso:      return s("incluido en la renta", "incluso nel canone", "included in the rent")
        }
    }
    var titoloScaletta: String { s("Escalado de la renta", "Canone anno per anno", "Rent schedule") }
    var parolaAnno: String { s("Año", "Anno", "Year") }
    var alMese: String { s("al mes", "al mese", "per month") }
    func ipcSi(_ indice: String) -> String {
        s("La renta se actualizará anualmente, en cada aniversario del contrato, aplicando la variación del \(indice) de los doce meses anteriores publicada por el INE.",
          "Il canone è aggiornato ogni anno, alla data anniversaria del contratto, applicando la variazione dell'indice \(indice) dei dodici mesi precedenti.",
          "The rent shall be updated annually, on each anniversary of the contract, applying the change in the \(indice) over the preceding twelve months.")
    }
    var ipcNo: String {
        s("La renta permanecerá invariable durante toda la vigencia del contrato.",
          "Il canone resta invariato per tutta la durata del contratto.",
          "The rent shall remain unchanged for the whole term of the contract.")
    }
    func fianza(_ importo: String, _ mesi: Int) -> String {
        mesi > 0 ? "\(importo) (\(s("equivalente a", "pari a", "equal to")) \(mensilita(mesi)))" : importo
    }
    func garanzia(_ importo: String, _ nota: String) -> String {
        let base = s("**Garantía adicional.** Además de la fianza legal, la parte arrendataria entrega la cantidad de \(importo) en concepto de garantía adicional del cumplimiento de sus obligaciones, que le será devuelta al término del contrato.",
                     "**Garanzia aggiuntiva.** Oltre alla fianza di legge, l'inquilino versa \(importo) a garanzia dell'adempimento delle proprie obbligazioni, restituibile al termine del contratto.",
                     "**Additional guarantee.** In addition to the statutory deposit, the tenant provides \(importo) as an additional guarantee, to be returned at the end of the contract.")
        return nota.isEmpty ? base : base + " " + nota
    }
    func aval(_ importo: String, _ banca: String) -> String {
        let da = banca.isEmpty ? "" : " " + s("emitido por", "emesso da", "issued by") + " \(banca)"
        return s("**Aval bancario.** La parte arrendataria aporta aval bancario a primer requerimiento por importe de \(importo)\(da), que permanecerá vigente durante toda la duración del contrato y sus prórrogas.",
                 "**Fideiussione bancaria.** L'inquilino presta fideiussione bancaria a prima richiesta per \(importo)\(da), valida per tutta la durata del contratto e delle sue proroghe.",
                 "**Bank guarantee.** The tenant provides a first-demand bank guarantee for \(importo)\(da), valid for the whole term of the contract and any extensions.")
    }
}

// ── Riempimento ──────────────────────────────────────────────────────────────
enum DocRiempi {
    /// Il testo del borrador con i segnaposto sostituiti. Quelli che non
    /// riconosce restano com'erano: meglio vederli stampati che scoprire un
    /// buco in fondo alla pagina.
    static func testo(borrador: Borrador, dati: DatiContratto, agenzia: String) -> String {
        let v = valori(borrador: borrador, dati: dati, agenzia: agenzia)
        var out = borrador.corpo
        for (chiave, valore) in v {
            out = out.replacingOccurrences(of: "{{\(chiave)}}", with: valore)
            out = out.replacingOccurrences(of: "{{ \(chiave) }}", with: valore)
        }
        return compatta(out)
    }

    /// I segnaposto vuoti lasciano righe bianche a grappoli: senza questo il
    /// contratto di chi non ha aval né garanzia esce pieno di buchi.
    static func compatta(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func valori(borrador: Borrador, dati d: DatiContratto, agenzia: String) -> [String: String] {
        let f = FrasiContratto(lingua: borrador.lingua)
        let euro = LeadFmt.euro

        var v: [String: String] = [
            "fecha":   f.dataEstesa(d.data),
            "lugar":   d.lugar,
            "agencia": agenzia,

            "propietario.nombre":    d.proprietario.nome,
            "propietario.nif":       d.proprietario.nif,
            "propietario.direccion": d.proprietario.direccion,
            "propietario.email":     d.proprietario.email,
            "propietario.telefono":  d.proprietario.telefono,

            "inmueble.direccion":    d.immobile.direccion,
            "inmueble.titulo":       d.immobile.titolo,
            "inmueble.referencia":   d.immobile.referencia,
            "inmueble.zona":         d.immobile.zona,
            "inmueble.ciudad":       d.immobile.ciudad,
            "inmueble.m2":           d.immobile.m2,
            "inmueble.habitaciones": d.immobile.habitaciones,
            "inmueble.banos":        d.immobile.banos,
            "inmueble.catastro":     d.immobile.catastro,
            "inmueble.zona_frase":   d.immobile.zona.isEmpty ? "" : ", \(d.immobile.zona)",

            "cliente.nombre":    d.cliente.nome,
            "cliente.nif":       d.cliente.nif,
            "cliente.direccion": d.cliente.direccion,
            "cliente.email":     d.cliente.email,
            "cliente.telefono":  d.cliente.telefono,

            "renta.mensual":     euro(d.canonePrimoAnno),
            "renta.anual":       euro(d.canonePrimoAnno * 12),
            "contrato.inicio":   f.dataBreve(d.inizio),
            "contrato.fin":      f.dataBreve(d.fine),
            "contrato.duracion": f.durata(d.durataMesi),
            "contrato.meses":    "\(d.durataMesi)",

            "fianza":           f.fianza(euro(d.fianzaImporto), d.fianzaMesi),
            "fianza.importe":   euro(d.fianzaImporto),
            "garantia.importe": euro(d.garanziaImporto),
            "ipc":              d.ipcAttivo ? f.ipcSi(d.ipcIndice.isEmpty ? "IPC" : d.ipcIndice) : f.ipcNo,
        ]

        v["renta.tabla"]   = tabellaCanoni(d, f)
        v["gastos.tabla"]  = tabellaSpese(d, f)
        v["extras.tabla"]  = tabellaExtra(d)
        v["garantia"]      = d.garanziaImporto > 0 ? f.garanzia(euro(d.garanziaImporto), d.garanziaNota) : ""
        v["aval"]          = d.avalAttivo ? f.aval(euro(d.avalImporto), d.avalBanca) : ""
        if d.ipcAttivo, !d.ipcNota.isEmpty { v["ipc"]! += " " + d.ipcNota }
        return v
    }

    /// Vuota se il canone non cambia: una tabella di un anno solo è rumore.
    static func tabellaCanoni(_ d: DatiContratto, _ f: FrasiContratto) -> String {
        guard d.canoneVariabile, d.canoniAnno.count > 1 else { return "" }
        var righe = ["**\(f.titoloScaletta):**", ""]
        for c in d.canoniAnno.sorted(by: { $0.anno < $1.anno }) {
            let da = Calendar.current.date(byAdding: .year, value: c.anno - 1, to: d.inizio) ?? d.inizio
            let a = Calendar.current.date(byAdding: .day, value: -1,
                    to: Calendar.current.date(byAdding: .year, value: c.anno, to: d.inizio) ?? d.inizio) ?? d.inizio
            let aFinale = min(a, d.fine)
            righe.append("- \(f.parolaAnno) \(c.anno) (\(f.dataBreve(da)) – \(f.dataBreve(aFinale))): **\(LeadFmt.euro(c.importo))** \(f.alMese)")
        }
        return righe.joined(separator: "\n")
    }

    static func tabellaSpese(_ d: DatiContratto, _ f: FrasiContratto) -> String {
        let voci = d.gastos.filter { !$0.nome.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !voci.isEmpty else { return "" }
        return voci.map { g in
            let nota = g.nota.trimmingCharacters(in: .whitespaces)
            return "- **\(g.nome):** \(f.carico(g.carico))" + (nota.isEmpty ? "" : " (\(nota))")
        }.joined(separator: "\n")
    }

    static func tabellaExtra(_ d: DatiContratto) -> String {
        let voci = d.extras.filter {
            !($0.titolo + $0.testo).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !voci.isEmpty else { return "" }
        return voci.map { c in
            let t = c.titolo.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? c.testo : "**\(t).** \(c.testo)"
        }.joined(separator: "\n\n")
    }

    /// La fotografia dei valori usati, da salvare accanto al PDF: serve a
    /// rigenerare lo stesso documento fra sei mesi cambiando una cifra sola.
    static func json(_ d: DatiContratto) -> [String: Any] {
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
        return [
            "lugar": d.lugar, "data": iso.string(from: d.data),
            "proprietario": ["nome": d.proprietario.nome, "nif": d.proprietario.nif,
                             "direccion": d.proprietario.direccion,
                             "email": d.proprietario.email, "telefono": d.proprietario.telefono],
            "cliente": ["nome": d.cliente.nome, "nif": d.cliente.nif,
                        "direccion": d.cliente.direccion,
                        "email": d.cliente.email, "telefono": d.cliente.telefono],
            "immobile": ["direccion": d.immobile.direccion, "referencia": d.immobile.referencia,
                         "zona": d.immobile.zona, "ciudad": d.immobile.ciudad,
                         "m2": d.immobile.m2, "catastro": d.immobile.catastro],
            "contratto": ["inizio": iso.string(from: d.inizio), "mesi": d.durataMesi,
                          "canone": d.canoneMensile, "canone_variabile": d.canoneVariabile,
                          "canoni": d.canoniAnno.map { ["anno": $0.anno, "importo": $0.importo] }],
            "garanzie": ["fianza_mesi": d.fianzaMesi, "fianza": d.fianzaImporto,
                         "garanzia": d.garanziaImporto, "garanzia_nota": d.garanziaNota,
                         "aval": d.avalAttivo, "aval_banca": d.avalBanca, "aval_importo": d.avalImporto],
            "ipc": ["attivo": d.ipcAttivo, "indice": d.ipcIndice, "nota": d.ipcNota],
            "gastos": d.gastos.map { ["nome": $0.nome, "carico": $0.carico.rawValue, "nota": $0.nota] },
            "extras": d.extras.map { ["titolo": $0.titolo, "testo": $0.testo] },
        ]
    }
}
