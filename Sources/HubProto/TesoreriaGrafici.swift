import SwiftUI

// ============================================================================
// Grafici e proiezioni della Tesoreria.
// Tre viste, un menu solo: com'è andata (mese per mese), cosa c'è già in
// calendario (prenotato, che è l'unico futuro certo) e dove si va a finire se
// il ritmo resta questo (proiezione, che è una stima e lo dice).
// Colori: gli stessi canali del planning, così «Booking» è dello stesso colore
// ovunque nell'app; entrate/uscite usano il verde e il rosso della Tesoreria.
// ============================================================================

private let grYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let grMese: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMM yy"; return f }()
private let grMeseLungo: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMMM yyyy"; return f }()

private func grNomeMese(_ key: String, lungo: Bool = false) -> String {
    guard let d = grYmd.date(from: key + "-01") else { return key }
    return (lungo ? grMeseLungo : grMese).string(from: d).capitalized
}

struct GraficiTesoreria: View {
    let movimenti: [TesMovimento]
    let prenotazioni: [Prenotazione]
    let struttura: Struttura?

    enum Vista: String, CaseIterable, Identifiable {
        case medie = "Ricavi e medie", andamento = "Com'è andata", prenotato = "Già prenotato", proiezione = "Proiezione"
        var id: String { rawValue }
        var spiega: String {
            switch self {
            case .medie: return "Il ricavo spalmato sulle notti del soggiorno, non sul giorno del pagamento: è quanto rende una giornata, una settimana, un mese, un anno."
            case .andamento: return "Entrate e uscite registrate, mese per mese. È il passato: sono soldi che si sono mossi davvero."
            case .prenotato: return "Quanto vale quello che è già in calendario, mese per mese. È l'unico futuro certo che abbiamo."
            case .proiezione: return "Dove si va a finire se il ritmo resta questo. È una stima, e vale quanto i mesi su cui è calcolata."
            }
        }
    }
    /// Ogni quanto si guarda: la stessa cifra letta per giorno, settimana, mese
    /// o anno risponde a domande diverse — «ieri quanto ho fatto» non è «questo
    /// mese come sta andando».
    enum Grana: String, CaseIterable, Identifiable {
        case giorno = "Giorno", settimana = "Settimana", mese = "Mese", anno = "Anno"
        var id: String { rawValue }
        /// Quanti periodi mostrare: sempre lo stesso arco di tempo, più o meno.
        var quanti: Int {
            switch self {
            case .giorno: return 45
            case .settimana: return 20
            case .mese: return 18
            case .anno: return 5
            }
        }
        var etichetta: String {
            switch self {
            case .giorno: return "al giorno"
            case .settimana: return "a settimana"
            case .mese: return "al mese"
            case .anno: return "all'anno"
            }
        }
    }
    @State private var vista: Vista = .medie
    @State private var grana: Grana = .mese
    @State private var periodoSotto: String? = nil
    @State private var meseSotto: String? = nil
    /// Quanto si pensa di crescere ogni anno: la proiezione non è un destino,
    /// è un'ipotesi che si deve poter cambiare.
    @State private var crescita: Double = 0

    // ── dati ─────────────────────────────────────────────────────────────────
    private var movFiltrati: [TesMovimento] {
        guard let s = struttura else { return movimenti }
        return movimenti.filter { $0.struttura == s.rawValue }
    }
    private var prenFiltrate: [Prenotazione] {
        prenotazioni.filter { $0.status != "cancellata" && (struttura == nil || $0.struttura == struttura!.rawValue) }
    }

    private struct MeseDato: Identifiable {
        let id: String            // "2026-07"
        let entrate: Int, uscite: Int
        var utile: Int { entrate - uscite }
    }
    /// Cauzioni e apporti entrano in cassa ma non sono ricavi: nel conto
    /// economico stanno fuori, e qui devono starne fuori uguale — se no la
    /// proiezione promette soldi che sono di altri.
    private func nonRicavo(_ m: TesMovimento) -> Bool {
        let c = (m.categoria ?? "").lowercased()
        return c.contains("deposito") || c.contains("apporto")
    }
    private var mesi: [MeseDato] {
        var e: [String: Int] = [:], u: [String: Int] = [:]
        for m in movFiltrati {
            let k = String(m.data.prefix(7))
            if m.tipo == "entrata" {
                guard !nonRicavo(m) else { continue }
                e[k, default: 0] += m.importo_cents
            } else {
                u[k, default: 0] += m.importo_cents
            }
        }
        return Set(e.keys).union(u.keys).sorted().map {
            MeseDato(id: $0, entrate: e[$0] ?? 0, uscite: u[$0] ?? 0)
        }
    }

    /// Valore già in calendario per mese, diviso per canale: si conta il
    /// soggiorno nel mese in cui comincia, come lo si incassa.
    private struct MesePrenotato: Identifiable {
        let id: String
        let perCanale: [(canale: String, tot: Int)]
        var totale: Int { perCanale.reduce(0) { $0 + $1.tot } }
    }
    private let canali = ["diretto", "booking", "airbnb", "educamp"]
    private func canaleDi(_ b: Prenotazione) -> String {
        let s = (b.source ?? "diretto").lowercased()
        return canali.contains(s) ? s : "diretto"
    }
    private var prenotato: [MesePrenotato] {
        let oggi = String(grYmd.string(from: Date()).prefix(7))
        var map: [String: [String: Int]] = [:]
        for b in prenFiltrate {
            guard let ci = b.checkin, ci.count >= 7 else { continue }
            let k = String(ci.prefix(7))
            guard k >= oggi else { continue }
            map[k, default: [:]][canaleDi(b), default: 0] += b.amount_cents
        }
        return map.keys.sorted().prefix(14).map { k in
            MesePrenotato(id: k, perCanale: canali.map { (canale: $0, tot: map[k]?[$0] ?? 0) })
        }
    }

    // ── ricavi per notte e medie ─────────────────────────────────────────────
    // Il pagamento arriva tutto insieme (le OTA pagano a soggiorno finito), ma
    // il ricavo lo produce ogni notte: qui l'importo si divide per le notti e si
    // mette dove è stato guadagnato. È l'unico modo perché «media giornaliera»
    // voglia dire qualcosa.
    /// Per ogni giorno: quanto ha reso, e quante camere erano vendute. Le due
    /// cose sono diverse — in un giorno ci sono più camere — e tenerle separate
    /// serve: il ricavo per notte venduta è ricavo diviso CAMERE, non diviso
    /// giorni, se no con nove stanze il prezzo medio esce nove volte più alto.
    private var ricaviPerNotte: [Date: (cents: Int, camere: Int)] {
        let cal = Calendar.current
        var out: [Date: (cents: Int, camere: Int)] = [:]
        for b in prenFiltrate {
            guard let ci = b.checkin.flatMap({ grYmd.date(from: String($0.prefix(10))) }),
                  let co = b.checkout.flatMap({ grYmd.date(from: String($0.prefix(10))) }),
                  ci < co else { continue }
            let notti = max(1, cal.dateComponents([.day], from: ci, to: co).day ?? 1)
            let quota = b.amount_cents / notti
            let resto = b.amount_cents - quota * notti      // i centesimi non si perdono
            var d = ci, i = 0
            while d < co {
                var v = out[d] ?? (0, 0)
                v.cents += quota + (i == 0 ? resto : 0)
                v.camere += 1
                out[d] = v
                d = cal.date(byAdding: .day, value: 1, to: d) ?? co
                i += 1
            }
        }
        return out
    }
    /// Camere disponibili: serve per il ricavo medio per camera, che è il numero
    /// con cui si giudica una struttura (quanto rende un letto, pieno o vuoto).
    private var camereTotali: Int {
        switch struttura { case .viaPo: return 4; case .viaRomagna: return 5; case nil: return 9 }
    }
    private struct Periodo: Identifiable {
        let id: String            // chiave ordinabile
        let etichetta: String
        let inizio: Date
        let giorni: Int
        let ricavo: Int
        let nottiVendute: Int
    }
    private func chiave(_ d: Date, _ g: Grana) -> (String, String, Date, Int) {
        let cal = Calendar.current
        switch g {
        case .giorno:
            let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM"
            return (grYmd.string(from: d), f.string(from: d), d, 1)
        case .settimana:
            let ini = cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM"
            return (grYmd.string(from: ini), f.string(from: ini), ini, 7)
        case .mese:
            let ini = cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
            return (String(grYmd.string(from: ini).prefix(7)), grNomeMese(String(grYmd.string(from: ini).prefix(7))),
                    ini, cal.range(of: .day, in: .month, for: ini)?.count ?? 30)
        case .anno:
            let ini = cal.date(from: cal.dateComponents([.year], from: d)) ?? d
            let a = cal.component(.year, from: d)
            return ("\(a)", "\(a)", ini, cal.range(of: .day, in: .year, for: ini)?.count ?? 365)
        }
    }
    private var periodi: [Periodo] {
        var ric: [String: (et: String, ini: Date, gg: Int, tot: Int, notti: Int)] = [:]
        for (d, v) in ricaviPerNotte {
            let (k, et, ini, gg) = chiave(d, grana)
            var r = ric[k] ?? (et, ini, gg, 0, 0)
            r.tot += v.cents; r.notti += v.camere
            ric[k] = r
        }
        return ric.keys.sorted().suffix(grana.quanti).map { k in
            let r = ric[k]!
            return Periodo(id: k, etichetta: r.et, inizio: r.ini, giorni: r.gg, ricavo: r.tot, nottiVendute: r.notti)
        }
    }

    // ── proiezione ───────────────────────────────────────────────────────────
    // Quali mesi fanno media. I mesi futuri no: hanno dentro solo qualche
    // incasso anticipato e sembrerebbero mesi da fame. Il mese in corso conta
    // solo se è passata la metà — a luglio inoltrato luglio è un mese vero, il
    // 2 del mese no. Prima si prendevano solo i mesi già chiusi, e a fine
    // luglio la stima girava ancora su giugno soltanto.
    private var mesiCompleti: [MeseDato] {
        let cal = Calendar.current
        let corrente = String(grYmd.string(from: Date()).prefix(7))
        let giorno = cal.component(.day, from: Date())
        return mesi.filter { m in
            if m.id < corrente { return true }
            if m.id == corrente { return giorno >= 15 }
            return false
        }
    }
    private var mediaEntrate: Int {
        guard !mesiCompleti.isEmpty else { return 0 }
        return mesiCompleti.reduce(0) { $0 + $1.entrate } / mesiCompleti.count
    }
    private var mediaUtile: Int {
        guard !mesiCompleti.isEmpty else { return 0 }
        return mesiCompleti.reduce(0) { $0 + $1.utile } / mesiCompleti.count
    }
    private struct AnnoStima: Identifiable {
        let id: Int
        let entrate: Int, utile: Int
        let certo: Int        // parte già prenotata, non stimata
    }
    private var anni: [AnnoStima] {
        let cal = Calendar.current
        let annoOra = cal.component(.year, from: Date())
        let meseOra = cal.component(.month, from: Date())
        // Già in calendario, per anno.
        var certoPerAnno: [Int: Int] = [:]
        for b in prenFiltrate {
            guard let ci = b.checkin, ci.count >= 4, let a = Int(ci.prefix(4)) else { continue }
            if ci >= grYmd.string(from: Date()) { certoPerAnno[a, default: 0] += b.amount_cents }
        }
        return (0..<4).map { i in
            let anno = annoOra + i
            // Nell'anno in corso si stimano solo i mesi che restano, e il mese
            // corrente è già dentro la media: si parte dal prossimo.
            let mesiDaStimare = i == 0 ? max(0, 12 - meseOra) : 12
            let fattore = pow(1 + crescita, Double(i))
            let entrate = Int(Double(mediaEntrate * mesiDaStimare) * fattore)
            let utile = Int(Double(mediaUtile * mesiDaStimare) * fattore)
            return AnnoStima(id: anno, entrate: entrate, utile: utile, certo: certoPerAnno[anno] ?? 0)
        }
    }

    // ── vista ────────────────────────────────────────────────────────────────
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PSESegmented(items: Vista.allCases.map { ($0, $0.rawValue) }, selection: $vista)
                Spacer(minLength: 8)
                Text(vista.spiega).font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    .lineLimit(2).multilineTextAlignment(.trailing).frame(maxWidth: 420, alignment: .trailing)
            }
            switch vista {
            case .medie: medieView
            case .andamento: andamentoView
            case .prenotato: prenotatoView
            case .proiezione: proiezioneView
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // ── 0. Ricavi e medie ────────────────────────────────────────────────────
    private var medieView: some View {
        let dati = periodi
        let conRicavo = dati.filter { $0.ricavo > 0 }
        let tot = dati.reduce(0) { $0 + $1.ricavo }
        let media = conRicavo.isEmpty ? 0 : tot / conRicavo.count
        let migliore = dati.max { $0.ricavo < $1.ricavo }
        let notti = dati.reduce(0) { $0 + $1.nottiVendute }
        let giorni = dati.reduce(0) { $0 + $1.giorni }
        let perNotte = notti > 0 ? tot / notti : 0                     // quanto rende una camera venduta
        let perCamera = giorni > 0 ? tot / (giorni * camereTotali) : 0  // quanto rende una camera, piena o vuota
        let maxV = max(1, dati.map { $0.ricavo }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PSESegmented(items: Grana.allCases.map { ($0, $0.rawValue) }, selection: $grana)
                Spacer(minLength: 0)
                Text("Ultimi \(dati.count) \(grana.rawValue.lowercased())\(dati.count == 1 ? "" : "i") con movimento")
                    .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
            }
            HStack(spacing: 10) {
                statoCard("MEDIA \(grana.etichetta.uppercased())", eurc(media), PSE.accent,
                          "Calcolata sui \(conRicavo.count) periodi che hanno prodotto qualcosa")
                statoCard("MIGLIORE", migliore.map { eurc($0.ricavo) } ?? "—", PSE.pos,
                          migliore.map { "\($0.etichetta): \(eurc($0.ricavo))" } ?? "")
                statoCard("PER NOTTE VENDUTA", eurc(perNotte), PSE.ink,
                          "\(notti) notti vendute in tutto: è il prezzo medio incassato per camera occupata")
                statoCard("PER CAMERA AL GIORNO", eurc(perCamera), PSE.warn,
                          "Ricavo diviso per tutte le \(camereTotali) camere e tutti i giorni, vuote comprese")
                statoCard("TOTALE", eurc(tot), PSE.pos, "Somma del periodo mostrato")
            }
            if dati.isEmpty {
                EmptyStateCard(icon: "chart.bar", text: "Nessun soggiorno da cui calcolare i ricavi.")
            } else {
                HStack(alignment: .bottom, spacing: grana == .giorno ? 3 : 8) {
                    ForEach(dati) { p in colonnaPeriodo(p, maxV: maxV, media: media) }
                    Spacer(minLength: 0)
                }
                .frame(height: 190, alignment: .bottom)
                if let k = periodoSotto, let p = dati.first(where: { $0.id == k }) {
                    dettaglioPeriodo(p)
                } else {
                    Text("La riga tratteggiata è la media. Passa sopra una colonna per i numeri di quel \(grana.rawValue.lowercased()).")
                        .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                }
            }
        }
    }
    private func colonnaPeriodo(_ p: Periodo, maxV: Int, media: Int) -> some View {
        let h: CGFloat = 140
        let sotto = periodoSotto == p.id
        let larghezza: CGFloat = grana == .giorno ? 16 : (grana == .anno ? 70 : 40)
        return VStack(spacing: 5) {
            Text(sotto ? eurc(p.ricavo) : " ")
                .font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(PSE.ink)
                .lineLimit(1).minimumScaleFactor(0.6).frame(height: 11)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(PSE.pos.opacity(sotto ? 1 : (p.ricavo >= media ? 0.78 : 0.45)))
                    .frame(width: larghezza, height: max(2, CGFloat(p.ricavo) / CGFloat(maxV) * h))
            }
            .frame(height: h, alignment: .bottom)
            .overlay(alignment: .bottom) {
                // la media, come riferimento: si vede subito chi sta sopra e chi sotto
                Rectangle().fill(PSE.accent.opacity(0.65)).frame(height: 1)
                    .offset(y: -(CGFloat(media) / CGFloat(maxV) * h))
            }
            Text(p.etichetta).font(.system(size: 8.5, weight: sotto ? .bold : .medium))
                .foregroundStyle(sotto ? PSE.ink : PSE.dim).lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: larghezza + 8)
        }
        .contentShape(Rectangle())
        .onHover { d in periodoSotto = d ? p.id : (periodoSotto == p.id ? nil : periodoSotto) }
        .help("\(p.etichetta): \(eurc(p.ricavo)) · \(p.nottiVendute) notti vendute su \(p.giorni * camereTotali) disponibili")
    }
    private func dettaglioPeriodo(_ p: Periodo) -> some View {
        let occ = p.giorni * camereTotali
        let pct = occ > 0 ? Int((Double(p.nottiVendute) / Double(occ) * 100).rounded()) : 0
        return HStack(spacing: 16) {
            Text(p.etichetta).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.ink)
            valore("ricavo", eurc(p.ricavo), PSE.pos)
            valore("notti vendute", "\(p.nottiVendute) su \(occ)", PSE.text)
            valore("occupazione", "\(pct)%", PSE.accent)
            if p.nottiVendute > 0 { valore("per notte", eurc(p.ricavo / p.nottiVendute), PSE.ink) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
    }
    private func statoCard(_ t: String, _ v: String, _ c: Color, _ aiuto: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.7).foregroundStyle(PSE.faint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(v).font(.system(size: 17, weight: .bold)).foregroundStyle(c).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
        .help(aiuto)
    }

    // ── 1. Com'è andata ──────────────────────────────────────────────────────
    private var andamentoView: some View {
        let dati = mesi
        let maxV = max(1, dati.map { max($0.entrate, $0.uscite) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            legenda([("Entrate", PSE.pos), ("Uscite", PSE.neg)])
            if dati.isEmpty {
                EmptyStateCard(icon: "chart.bar", text: "Nessun movimento registrato.")
            } else {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(dati) { m in
                        colonnaMese(m, maxV: maxV)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 210)
                if let k = meseSotto, let m = dati.first(where: { $0.id == k }) {
                    dettaglioMese(m)
                } else {
                    Text("Passa sopra una colonna per i numeri del mese.")
                        .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                }
            }
        }
    }
    private func colonnaMese(_ m: MeseDato, maxV: Int) -> some View {
        let h: CGFloat = 150
        let sotto = meseSotto == m.id
        return VStack(spacing: 6) {
            // valore sopra la colonna solo dove serve: sul mese sotto il mouse.
            Text(sotto ? eurc(m.utile) : " ")
                .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(m.utile >= 0 ? PSE.pos : PSE.neg).frame(height: 12)
            HStack(alignment: .bottom, spacing: 2) {
                barra(CGFloat(m.entrate) / CGFloat(maxV) * h, PSE.pos, sotto)
                barra(CGFloat(m.uscite) / CGFloat(maxV) * h, PSE.neg, sotto)
            }
            .frame(height: h, alignment: .bottom)
            Text(grNomeMese(m.id)).font(.system(size: 9.5, weight: sotto ? .bold : .medium))
                .foregroundStyle(sotto ? PSE.ink : PSE.dim).lineLimit(1)
        }
        .frame(width: 62)
        .contentShape(Rectangle())
        .onHover { dentro in meseSotto = dentro ? m.id : (meseSotto == m.id ? nil : meseSotto) }
        .help("\(grNomeMese(m.id, lungo: true)): entrate \(eurc(m.entrate)), uscite \(eurc(m.uscite)), utile \(eurc(m.utile))")
    }
    private func barra(_ h: CGFloat, _ c: Color, _ acceso: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(c.opacity(acceso ? 1 : 0.72))
            .frame(width: 22, height: max(2, h))
    }
    private func dettaglioMese(_ m: MeseDato) -> some View {
        HStack(spacing: 16) {
            Text(grNomeMese(m.id, lungo: true)).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.ink)
            valore("entrate", eurc(m.entrate), PSE.pos)
            valore("uscite", eurc(m.uscite), PSE.neg)
            valore("utile", eurc(m.utile), m.utile >= 0 ? PSE.pos : PSE.neg)
            if m.entrate > 0 {
                valore("margine", "\(Int((Double(m.utile) / Double(m.entrate) * 100).rounded()))%", PSE.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
    }

    // ── 2. Già prenotato ─────────────────────────────────────────────────────
    private func coloreCanale(_ c: String) -> Color {
        switch c {
        case "booking": return Color(hue: 42/360, saturation: 0.62, brightness: 0.80)
        case "airbnb": return Color(hue: 8/360, saturation: 0.58, brightness: 0.78)
        case "educamp": return Color(hue: 168/360, saturation: 0.46, brightness: 0.72)
        default: return Color(hue: 206/360, saturation: 0.52, brightness: 0.80)
        }
    }
    private var prenotatoView: some View {
        let dati = prenotato
        let maxV = max(1, dati.map { $0.totale }.max() ?? 1)
        let tot = dati.reduce(0) { $0 + $1.totale }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                legenda(canali.map { ($0 == "diretto" ? "Diretta" : $0.capitalized, coloreCanale($0)) })
                Spacer(minLength: 0)
                Text("In calendario da oggi: \(eurc(tot))")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.accent)
            }
            if dati.isEmpty {
                EmptyStateCard(icon: "calendar", text: "Non c'è ancora niente in calendario da oggi in avanti.")
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(dati) { m in
                        VStack(spacing: 6) {
                            Text(meseSotto == m.id ? eurc(m.totale) : " ")
                                .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                                .foregroundStyle(PSE.ink).frame(height: 12)
                            VStack(spacing: 2) {
                                ForEach(m.perCanale.filter { $0.tot > 0 }, id: \.canale) { p in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(coloreCanale(p.canale).opacity(meseSotto == m.id ? 1 : 0.75))
                                        .frame(height: max(2, CGFloat(p.tot) / CGFloat(maxV) * 150))
                                }
                            }
                            .frame(width: 30, height: 150, alignment: .bottom)
                            Text(grNomeMese(m.id)).font(.system(size: 9.5, weight: meseSotto == m.id ? .bold : .medium))
                                .foregroundStyle(meseSotto == m.id ? PSE.ink : PSE.dim).lineLimit(1)
                        }
                        .frame(width: 56)
                        .contentShape(Rectangle())
                        .onHover { d in meseSotto = d ? m.id : (meseSotto == m.id ? nil : meseSotto) }
                        .help(dettaglioCanali(m))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 200, alignment: .bottom)
                Text("Ogni soggiorno è contato nel mese in cui comincia, al lordo delle commissioni. Sono prenotazioni vere, non stime.")
                    .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
            }
        }
    }
    private func dettaglioCanali(_ m: MesePrenotato) -> String {
        var t = "\(grNomeMese(m.id, lungo: true)): \(eurc(m.totale))"
        for p in m.perCanale where p.tot > 0 {
            t += "\n• \(p.canale == "diretto" ? "Diretta" : p.canale.capitalized): \(eurc(p.tot))"
        }
        return t
    }

    // ── 3. Proiezione ────────────────────────────────────────────────────────
    private var proiezioneView: some View {
        let dati = anni
        let maxV = max(1, dati.map { max($0.entrate, $0.certo) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            if mesiCompleti.isEmpty {
                EmptyStateCard(icon: "questionmark.circle",
                               text: "Non c'è ancora un mese intero registrato: senza storico non si può stimare niente.")
            } else {
                HStack(spacing: 14) {
                    legenda([("Già prenotato", PSE.accent), ("Stimato", PSE.pos)])
                    Spacer(minLength: 0)
                    Text("Crescita annua ipotizzata").font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    HStack(spacing: 4) {
                        ForEach([-0.2, -0.1, 0.0, 0.1, 0.2], id: \.self) { g in
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) { crescita = g }
                            } label: {
                                Text(g == 0 ? "come oggi" : "\(g > 0 ? "+" : "")\(Int(g * 100))%")
                                    .font(.system(size: 10, weight: crescita == g ? .bold : .medium))
                                    .foregroundStyle(crescita == g ? PSE.ink : PSE.dim)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Capsule().fill(crescita == g ? PSE.accent.opacity(0.8) : PSE.surface))
                                    .overlay(Capsule().strokeBorder(crescita == g ? Color.clear : PSE.line, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 22) {
                    ForEach(dati) { a in colonnaAnno(a, maxV: maxV) }
                    Spacer(minLength: 0)
                }
                .frame(height: 210, alignment: .bottom)
                tabellaAnni(dati)
                Text("Stima costruita su \(mesiCompleti.count) \(mesiCompleti.count == 1 ? "mese finito" : "mesi finiti") (media \(eurc(mediaEntrate)) di entrate e \(eurc(mediaUtile)) di utile al mese), proiettata sui mesi che restano e sugli anni a venire. La parte piena è quello che è già in calendario: quella è certa, il resto no. Con pochi mesi di storico la stima va presa per quello che è — un ordine di grandezza, non un preventivo.")
                    .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func colonnaAnno(_ a: AnnoStima, maxV: Int) -> some View {
        let h: CGFloat = 150
        let hTot = CGFloat(a.entrate) / CGFloat(maxV) * h
        let hCerto = min(hTot, CGFloat(a.certo) / CGFloat(maxV) * h)
        return VStack(spacing: 6) {
            Text(eurc(a.entrate)).font(.system(size: 10, weight: .bold)).monospacedDigit()
                .foregroundStyle(PSE.ink).frame(height: 12)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(PSE.pos.opacity(0.30))
                    .frame(width: 56, height: max(2, hTot))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PSE.pos.opacity(0.55), lineWidth: 1))
                if hCerto > 1 {
                    RoundedRectangle(cornerRadius: 4).fill(PSE.accent.opacity(0.85))
                        .frame(width: 56, height: hCerto)
                }
            }
            .frame(height: h, alignment: .bottom)
            Text("\(a.id)").font(.system(size: 11, weight: .bold)).foregroundStyle(PSE.text).monospacedDigit()
        }
        .help("\(a.id): stima \(eurc(a.entrate)) di entrate, di cui \(eurc(a.certo)) già prenotati. Utile stimato \(eurc(a.utile)).")
    }
    private func tabellaAnni(_ dati: [AnnoStima]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("ANNO").frame(width: 70, alignment: .leading)
                Text("GIÀ PRENOTATO").frame(maxWidth: .infinity, alignment: .trailing)
                Text("ENTRATE STIMATE").frame(maxWidth: .infinity, alignment: .trailing)
                Text("UTILE STIMATO").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .heavy)).tracking(0.7).foregroundStyle(PSE.faint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(dati) { a in
                HStack(spacing: 10) {
                    Text("\(a.id)").font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink)
                        .monospacedDigit().frame(width: 70, alignment: .leading)
                    Text(a.certo > 0 ? eurc(a.certo) : "—").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(a.certo > 0 ? PSE.accent : PSE.faint).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(eurc(a.entrate)).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.text)
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    Text(eurc(a.utile)).font(.system(size: 12, weight: .bold))
                        .foregroundStyle(a.utile >= 0 ? PSE.pos : PSE.neg).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider().overlay(PSE.line).padding(.leading, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── pezzi comuni ─────────────────────────────────────────────────────────
    private func legenda(_ voci: [(String, Color)]) -> some View {
        HStack(spacing: 12) {
            ForEach(voci, id: \.0) { v in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(v.1).frame(width: 10, height: 10)
                    Text(v.0).font(.system(size: 10.5)).foregroundStyle(PSE.dim)
                }
            }
        }
    }
    private func valore(_ t: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Text(t).font(.system(size: 10)).foregroundStyle(PSE.faint)
            Text(v).font(.system(size: 12.5, weight: .bold)).foregroundStyle(c).monospacedDigit()
        }
    }
}
