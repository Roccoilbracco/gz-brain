import SwiftUI

// ============================================================================
// Camere PSE — Educamp (Via Romagna) · calcolo mensile
// Riproduce il foglio Excel «Ospiti Educamp»: elenco ospiti + tabelle per mese
// (affitto lordo · commissione intermediario · affitto netto · utenze · totale
// che paga l'ospite · netto che resta a noi) + riepilogo per mese.
// Sorgente: public.educamp_ospiti + public.educamp_righe.
// ============================================================================

struct EducampOspite: Identifiable, Decodable, Equatable {
    let id: String
    var ospite: String
    var gruppo: String?
    var camera: String?
    var checkin: String?
    var checkout: String?
    var notti: Int?
    var note: String?
    var sort_order: Int?
}

struct EducampRiga: Identifiable, Decodable, Equatable {
    let id: String
    var mese: String
    var ospite: String
    var camera: String?
    var giorni: Int?
    var lordo_cents: Int
    var commissione_cents: Int
    var netto_cents: Int
    var utenze_cents: Int
    var totale_ospite_cents: Int
    var netto_noi_cents: Int
    var sort_order: Int?
}

extension HubAPI {
    static func listEducampOspiti() async throws -> [EducampOspite] {
        try await sb.fetch("educamp_ospiti?select=*&order=sort_order.asc")
    }
    static func listEducampRighe() async throws -> [EducampRiga] {
        try await sb.fetch("educamp_righe?select=*&order=mese.asc,sort_order.asc")
    }
}

private let eduYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let eduMese: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMMM yyyy"; return f }()
private let eduDay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "dd/MM/yy"; return f }()
private func eduMeseNome(_ key: String) -> String {
    guard let d = eduYmd.date(from: key + "-01") else { return key }
    return eduMese.string(from: d).capitalized
}
private func eduDayStr(_ s: String?) -> String {
    guard let s, let d = eduYmd.date(from: String(s.prefix(10))) else { return "—" }
    return eduDay.string(from: d)
}

@MainActor final class EducampModel: ObservableObject {
    @Published var ospiti: [EducampOspite] = []
    @Published var righe: [EducampRiga] = []
    /// Incassi Educamp: arrivano da Tesoreria (vedi `movimenti` passati alla
    /// vista) oppure, se la scheda si apre da sola, si leggono qui.
    @Published var movimentiLocali: [TesMovimento] = []
    // Le bollette servono qui per il confronto: quanto riprendiamo dagli
    // inquilini contro quanto esce davvero di utenze.
    @Published var bollette: [Bolletta] = []
    @Published var loading = true
    func load(caricaMovimenti: Bool) async {
        loading = true
        ospiti = (try? await HubAPI.listEducampOspiti()) ?? []
        righe = (try? await HubAPI.listEducampRighe()) ?? []
        bollette = (try? await HubAPI.listBollette()) ?? []
        if caricaMovimenti { movimentiLocali = (try? await HubAPI.listMovimenti()) ?? [] }
        loading = false
    }
    var mesi: [String] { Array(Set(righe.map { $0.mese })).sorted() }
    func righe(_ mese: String) -> [EducampRiga] {
        righe.filter { $0.mese == mese }.sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }
    }
}

struct EducampView: View {
    /// Movimenti di cassa passati da Tesoreria: appena si registra un incasso
    /// la lista cambia e le spunte di «pagato» si aggiornano da sole.
    var movimenti: [TesMovimento]? = nil
    @StateObject private var model = EducampModel()

    // larghezze colonne tabella mensile
    private let wStato: CGFloat = 15, wCamera: CGFloat = 150, wGiorni: CGFloat = 46, wSoldi: CGFloat = 82, wComm: CGFloat = 70
    private let wManca: CGFloat = 76

    private var incassi: [TesMovimento] { movimenti ?? model.movimentiLocali }

    /// Finestra aperta cliccando una spunta o una card degli incassi: mostra i
    /// versamenti che stanno dietro a quel numero. Prima erano solo nel tooltip,
    /// che si legge male e non si può copiare.
    struct MovimentiAperti: Identifiable {
        let id = UUID()
        let titolo: String
        let sottotitolo: String
        let righe: [TesMovimento]
    }
    @State private var movimentiAperti: MovimentiAperti? = nil

    /// I movimenti che finanziano una riga ospite-mese, riconosciuti per data e
    /// descrizione: `fonti` porta la quota, qui si risale al movimento intero.
    private func movimentiDi(_ s: EducampSaldoRiga) -> [TesMovimento] {
        let chiavi = Set(s.fonti.map { "\($0.data)|\($0.desc)" })
        return incassi.filter { chiavi.contains("\($0.data)|\($0.descrizione ?? "")") }
            .sorted { $0.data < $1.data }
    }
    private func apri(_ titolo: String, _ sottotitolo: String, _ righe: [TesMovimento]) {
        movimentiAperti = MovimentiAperti(titolo: titolo, sottotitolo: sottotitolo, righe: righe)
    }
    /// Card cliccabile: stesso aspetto di prima, più la freccetta.
    private func cardClic(_ t: String, _ v: String, _ c: Color, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            card(t, v, c).overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PSE.faint).padding(10)
            }
        }.buttonStyle(.plain)
    }

    var body: some View {
        let esito = EducampPagamenti.calcola(righe: model.righe, movimenti: incassi)
        return Group {
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        intestazione
                        kpi
                        incassiBlocco(esito.saldi, esito.orfani)
                        utenzeBlocco
                        elencoOspiti
                        ForEach(model.mesi, id: \.self) { m in meseTable(m, esito.saldi) }
                        if !esito.orfani.isEmpty { orfaniBlocco(esito.orfani) }
                        riepilogoMese
                        Text("Affitto lordo = quello che paga l'ospite (380 €/mese per letto, commissione inclusa). La commissione è la parte per l'intermediario. Utenze: 8 €/giorno per camera divisi tra i presenti (6 € se resta una persona). Il mese è contato come 30 giorni.")
                            .font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .task { await model.load(caricaMovimenti: movimenti == nil) }
        .sheet(item: $movimentiAperti) { m in
            EducampMovimentiSheet(titolo: m.titolo, sottotitolo: m.sottotitolo, righe: m.righe) {
                movimentiAperti = nil
            }
        }
    }

    private var intestazione: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("EDUCAMP — VIA ROMAGNA · CALCOLO MENSILE")
                .font(.system(size: 12, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
            Text("Affitto per letto/mese 380 € (di cui commissione 80 €) · Utenze 8 €/giorno per camera (6 € se una sola persona)")
                .font(.system(size: 11)).foregroundStyle(PSE.dim)
        }
    }

    // KPI: totali del soggiorno completo
    private var kpi: some View {
        let lordo = model.righe.reduce(0) { $0 + $1.lordo_cents }
        let comm = model.righe.reduce(0) { $0 + $1.commissione_cents }
        let utenze = model.righe.reduce(0) { $0 + $1.utenze_cents }
        let totOsp = model.righe.reduce(0) { $0 + $1.totale_ospite_cents }
        let nettoNoi = model.righe.reduce(0) { $0 + $1.netto_noi_cents }
        return HStack(spacing: 12) {
            card("TOTALE DOVUTO OSPITI", eurc(totOsp), PSE.ink)
            card("NETTO PER NOI", eurc(nettoNoi), PSE.pos)
            card("COMMISSIONI DA CONSEGNARE", eurc(comm), PSE.warn)
            card("UTENZE DA INCASSARE DAGLI INQUILINI", eurc(utenze), PSE.accent)
            card("AFFITTO LORDO", eurc(lordo), PSE.dim)
        }
    }

    // ── Incassi: quanto è già arrivato in cassa dagli ospiti ────────────────
    // Il totale nasce dagli stessi movimenti che colorano le righe: se un
    // numero non torna, la riga colorata dice subito dove guardare.
    private func incassiBlocco(_ saldi: [String: EducampSaldoRiga], _ orfani: [EducampMovNonAbbinato]) -> some View {
        let dovuto = model.righe.reduce(0) { $0 + $1.totale_ospite_cents }
        // Anche gli incassi orfani sono soldi arrivati: entrano nel totale, se no
        // questa card direbbe meno di «Educamp incassato» in Tesoreria.
        let abbinato = saldi.values.reduce(0) { $0 + $1.pagato_cents }
        let incassato = abbinato + orfani.reduce(0) { $0 + $1.importo }
        let stati = model.righe.map { (saldi[EducampPagamenti.chiave(mese: $0.mese, ospite: $0.ospite)] ?? EducampSaldoRiga()).stato }
        let saldate = stati.filter { $0 == .pagato }.count
        let affittoOk = stati.filter { $0 == .affittoOk }.count
        let acconti = stati.filter { $0 == .acconto }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("INCASSI — CHI HA PAGATO")
                .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.pos)
            HStack(spacing: 10) {
                cardClic("INCASSATO DAGLI OSPITI", eurc(incassato), PSE.pos) {
                    apri("Incassi Educamp", "Tutti i versamenti registrati, dal primo all'ultimo",
                         incassi.filter { $0.tipo == "entrata" && ($0.categoria ?? "") == "educamp" }
                                .sorted { $0.data < $1.data })
                }
                card("ANCORA DA INCASSARE", eurc(max(0, dovuto - incassato)), PSE.warn)
                card("MENSILITÀ SALDATE", "\(saldate) di \(model.righe.count)", PSE.ink)
                card("AFFITTO OK, MANCANO UTENZE", "\(affittoOk)", affittoOk > 0 ? PSE.accent : PSE.faint)
                card("SOLO UN ACCONTO", "\(acconti)", acconti > 0 ? PSE.warn : PSE.faint)
            }
            Text("Nelle tabelle qui sotto: ✓ pieno verde = mensilità saldata, ✓ vuoto = affitto incassato ma utenze ancora da prendere, mezzo cerchio ambra = solo un acconto, cerchio vuoto = niente. La colonna «MANCA» dice quanto resta da avere. Il conto si rifà da solo a ogni nuovo movimento di categoria «educamp»: l'ospite si riconosce dal nome scritto nella descrizione, e passando il mouse su una riga si vedono i versamenti che la coprono.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }

    // Un incasso Educamp senza nome riconoscibile non deve sparire: è denaro
    // arrivato che nessuna riga sta contando.
    private func orfaniBlocco(_ orfani: [EducampMovNonAbbinato]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("INCASSI EDUCAMP NON ABBINATI A NESSUN OSPITE")
                .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.warn)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            ForEach(orfani) { o in
                HStack(spacing: 10) {
                    td(eduDayStr(o.data)).frame(width: 74, alignment: .leading)
                    Text(o.desc).font(.system(size: 11.5)).foregroundStyle(PSE.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    num(eurc(o.importo), PSE.pos).frame(width: wSoldi, alignment: .trailing).bold()
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
            Text("Scrivi il nome dell'ospite nella descrizione del movimento (anche solo il nome proprio) e la spunta comparirà da sola sulla riga giusta.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
                .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 2)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.warn.opacity(0.30), lineWidth: 1))
    }

    // ── Utenze: quanto riprendiamo, quando, e quanto esce davvero ───────────
    // Il grosso del recupero arriva ad agosto/settembre/ottobre, quindi il mese
    // per mese conta più del totale.
    private var utenzeBlocco: some View {
        let perMese = model.mesi.map { m in (m, model.righe(m).reduce(0) { $0 + $1.utenze_cents }) }
        let daIncassare = perMese.reduce(0) { $0 + $1.1 }
        let meseCorrente = String(eduYmd.string(from: Date()).prefix(7))
        // Solo le bollette da luglio 2026: il pregresso si sistema a parte.
        let spese = model.bollette.filter { ($0.scadenza ?? "") >= "2026-07-01" }
        let speseTot = spese.reduce(0) { $0 + $1.importo_cents }
        return VStack(alignment: .leading, spacing: 10) {
            Text("UTENZE — DA INCASSARE DAGLI INQUILINI")
                .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.accent)
            HStack(spacing: 10) {
                card("TOTALE DA INCASSARE", eurc(daIncassare), PSE.accent)
                ForEach(perMese, id: \.0) { m, v in
                    meseUtenzaCard(m, v, futuro: m > meseCorrente)
                }
            }
            Text("SPESE UTENZE — QUELLO CHE PAGHIAMO NOI (da luglio 2026)")
                .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.neg).padding(.top, 4)
            HStack(spacing: 10) {
                card("TOTALE BOLLETTE", speseTot > 0 ? eurc(speseTot) : "—", speseTot > 0 ? PSE.neg : PSE.faint)
                ForEach(TIPI_BOLLETTA, id: \.0) { t in
                    let v = spese.filter { $0.tipo == t.0 }.reduce(0) { $0 + $1.importo_cents }
                    card(t.1.uppercased(), v > 0 ? eurc(v) : "—", v > 0 ? PSE.ink : PSE.faint)
                }
            }
            Text("Le utenze addebitate agli inquilini (8 €/giorno per camera) e le bollette che paghiamo sono due conti distinti e non si compensano qui: il dettaglio bolletta per bolletta sta in Servizi → Utenze.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }
    // Il mese non ancora arrivato si vede a colpo d'occhio: è denaro atteso.
    private func meseUtenzaCard(_ mese: String, _ v: Int, futuro: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(eduMeseNome(mese).uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(PSE.faint).lineLimit(1)
                if futuro {
                    Text("ATTESO").font(.system(size: 7, weight: .heavy)).tracking(0.4).foregroundStyle(PSE.warn)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(PSE.warn.opacity(0.15)))
                }
            }
            Text(eurc(v)).font(.system(size: 15, weight: .bold))
                .foregroundStyle(futuro ? PSE.warn : PSE.ink).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(futuro ? PSE.warn.opacity(0.35) : PSE.line, lineWidth: 1))
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

    // ── ELENCO OSPITI ──
    private var elencoOspiti: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ELENCO OSPITI").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 10) {
                th("OSPITE").frame(maxWidth: .infinity, alignment: .leading)
                th("GRUPPO").frame(width: 110, alignment: .leading)
                th("CAMERA").frame(width: 170, alignment: .leading)
                th("CHECK-IN").frame(width: 74, alignment: .leading)
                th("CHECK-OUT").frame(width: 74, alignment: .leading)
                th("NOTTI").frame(width: 46, alignment: .trailing)
                th("NOTE").frame(width: 190, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(Array(model.ospiti.enumerated()), id: \.element.id) { i, o in
                let annull = (o.note ?? "").uppercased().contains("ANNULLATA")
                HStack(spacing: 10) {
                    Text(o.ospite).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(annull ? PSE.faint : PSE.ink).strikethrough(annull)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    td(o.gruppo ?? "—").frame(width: 110, alignment: .leading)
                    td(o.camera ?? "—").frame(width: 170, alignment: .leading)
                    td(eduDayStr(o.checkin)).frame(width: 74, alignment: .leading)
                    td(eduDayStr(o.checkout)).frame(width: 74, alignment: .leading)
                    Text(o.notti.map { "\($0)" } ?? "—").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(PSE.ink).monospacedDigit().frame(width: 46, alignment: .trailing)
                    Text(o.note ?? "").font(.system(size: 10.5)).foregroundStyle(annull ? PSE.warn : PSE.faint)
                        .frame(width: 190, alignment: .leading).lineLimit(2)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                if i < model.ospiti.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
            }
            Color.clear.frame(height: 6)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── Tabella mensile ──
    private func meseTable(_ mese: String, _ saldi: [String: EducampSaldoRiga]) -> some View {
        let righe = model.righe(mese)
        let sub = subtotali(righe)
        let incassato = righe.reduce(0) { $0 + (saldi[EducampPagamenti.chiave(mese: mese, ospite: $1.ospite)]?.pagato_cents ?? 0) }
        let manca = max(0, sub.to - incassato)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(eduMeseNome(mese).uppercased())  ·  mese contato come 30 giorni")
                    .font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.accent)
                Spacer(minLength: 8)
                Text("INCASSATO \(eurc(incassato)) di \(eurc(sub.to))")
                    .font(.system(size: 9.5, weight: .heavy)).tracking(0.4).foregroundStyle(PSE.pos)
                if manca > 0 {
                    Text("MANCA \(eurc(manca))")
                        .font(.system(size: 9.5, weight: .heavy)).tracking(0.4).foregroundStyle(PSE.warn)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(PSE.warn.opacity(0.13)))
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            meseHeader
            ForEach(Array(righe.enumerated()), id: \.element.id) { i, r in
                meseRow(r, saldi[EducampPagamenti.chiave(mese: r.mese, ospite: r.ospite)] ?? EducampSaldoRiga())
                if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
            }
            Divider().overlay(PSE.line)
            subtotaleRow(sub, label: "SUBTOTALE \(eduMeseNome(mese).uppercased())", manca: manca)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    private var meseHeader: some View {
        HStack(spacing: 8) {
            th("").frame(width: wStato)
            th("OSPITE").frame(maxWidth: .infinity, alignment: .leading)
            th("CAMERA").frame(width: wCamera, alignment: .leading)
            th("GIORNI").frame(width: wGiorni, alignment: .trailing)
            th("LORDO").frame(width: wSoldi, alignment: .trailing)
            th("− COMM.").frame(width: wComm, alignment: .trailing)
            th("NETTO").frame(width: wSoldi, alignment: .trailing)
            th("UTENZE").frame(width: wComm, alignment: .trailing)
            th("TOT. OSPITE").frame(width: wSoldi, alignment: .trailing)
            th("NETTO NOI").frame(width: wSoldi, alignment: .trailing)
            th("MANCA").frame(width: wManca, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    private func meseRow(_ r: EducampRiga, _ s: EducampSaldoRiga) -> some View {
        let stato = s.stato
        return HStack(spacing: 8) {
            // La spunta si clicca: apre i versamenti che la giustificano. Il
            // tooltip li diceva già, ma non si potevano leggere con calma.
            Button {
                apri("\(r.ospite) — \(eduMeseNome(r.mese))",
                     s.pagato_cents > 0
                        ? "Versamenti che coprono questa mensilità · dovuti \(eurc(r.totale_ospite_cents)), arrivati \(eurc(s.pagato_cents))"
                        : "Nessun incasso abbinato: dovuti \(eurc(r.totale_ospite_cents)). L'abbinamento usa il nome scritto nella descrizione del movimento.",
                     movimentiDi(s))
            } label: {
                EducampStatoIcona(stato: stato).frame(width: wStato).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(r.ospite).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(stato == .pagato ? PSE.pos : PSE.ink)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            td(r.camera ?? "—").frame(width: wCamera, alignment: .leading)
            num("\(r.giorni ?? 0)", PSE.dim).frame(width: wGiorni, alignment: .trailing)
            num(eurc(r.lordo_cents), PSE.text).frame(width: wSoldi, alignment: .trailing)
            num("−" + eurc(r.commissione_cents), PSE.warn).frame(width: wComm, alignment: .trailing)
            num(eurc(r.netto_cents), PSE.text).frame(width: wSoldi, alignment: .trailing)
            num(eurc(r.utenze_cents), PSE.accent).frame(width: wComm, alignment: .trailing)
            num(eurc(r.totale_ospite_cents), PSE.ink).frame(width: wSoldi, alignment: .trailing)
            num(eurc(r.netto_noi_cents), PSE.pos).frame(width: wSoldi, alignment: .trailing).bold()
            // Quanto resta da avere: il numero conta più dell'icona quando
            // manca solo un pezzo di utenze.
            Group {
                if stato == .pagato {
                    Text("saldato").font(.system(size: 10, weight: .semibold)).foregroundStyle(PSE.pos.opacity(0.8))
                } else if s.pagato_cents > 0 {
                    num("−" + eurc(s.residuo), stato == .affittoOk ? PSE.accent : PSE.warn)
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(PSE.faint)
                }
            }
            .frame(width: wManca, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        // Verde = saldato, ambra = arrivato solo un acconto: si legge la riga
        // intera senza cercare l'icona.
        .background(statoSfondo(stato))
        .help(statoTesto(r, s))
    }
    private func statoSfondo(_ stato: StatoPagamento) -> Color {
        switch stato {
        case .pagato: return PSE.pos.opacity(0.08)
        case .affittoOk: return PSE.pos.opacity(0.035)
        case .acconto: return PSE.warn.opacity(0.06)
        case .nulla: return .clear
        }
    }
    /// Il tooltip dice da dove arrivano i soldi: senza, una spunta sbagliata
    /// sarebbe impossibile da smontare.
    private func statoTesto(_ r: EducampRiga, _ s: EducampSaldoRiga) -> String {
        var t: String
        switch s.stato {
        case .pagato:
            t = "Saldato: \(eurc(s.pagato_cents)) di \(eurc(r.totale_ospite_cents))"
        case .affittoOk:
            t = "Affitto pagato (\(eurc(s.dovuto_affitto_cents))) — mancano \(eurc(s.residuo_utenze)) di utenze"
        case .acconto:
            t = "Acconto \(eurc(s.pagato_cents)) di \(eurc(r.totale_ospite_cents)) — manca \(eurc(s.residuo)) (affitto \(eurc(s.residuo_affitto)) + utenze \(eurc(s.residuo_utenze)))"
        case .nulla:
            t = "Nessun incasso registrato — dovuti \(eurc(r.totale_ospite_cents))"
        }
        for f in s.fonti { t += "\n• \(eduDayStr(f.data)) · \(eurc(f.quota)) — \(f.desc)" }
        if s.stato == .nulla { t += "\nL'abbinamento usa il nome scritto nella descrizione del movimento (categoria «educamp»)." }
        return t
    }

    private func subtotali(_ rs: [EducampRiga]) -> (g: Int, lo: Int, co: Int, ne: Int, ut: Int, to: Int, nn: Int) {
        rs.reduce((0,0,0,0,0,0,0)) { a, r in
            (a.0 + (r.giorni ?? 0), a.1 + r.lordo_cents, a.2 + r.commissione_cents, a.3 + r.netto_cents,
             a.4 + r.utenze_cents, a.5 + r.totale_ospite_cents, a.6 + r.netto_noi_cents)
        }
    }
    private func subtotaleRow(_ s: (g: Int, lo: Int, co: Int, ne: Int, ut: Int, to: Int, nn: Int), label: String, manca: Int) -> some View {
        return HStack(spacing: 8) {
            Color.clear.frame(width: wStato, height: 1)
            Text(label).font(.system(size: 10, weight: .heavy)).tracking(0.5).foregroundStyle(PSE.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            td("").frame(width: wCamera)
            num("\(s.g)", PSE.ink).frame(width: wGiorni, alignment: .trailing).bold()
            num(eurc(s.lo), PSE.ink).frame(width: wSoldi, alignment: .trailing).bold()
            num("−" + eurc(s.co), PSE.warn).frame(width: wComm, alignment: .trailing).bold()
            num(eurc(s.ne), PSE.ink).frame(width: wSoldi, alignment: .trailing).bold()
            num(eurc(s.ut), PSE.accent).frame(width: wComm, alignment: .trailing).bold()
            num(eurc(s.to), PSE.ink).frame(width: wSoldi, alignment: .trailing).bold()
            num(eurc(s.nn), PSE.pos).frame(width: wSoldi, alignment: .trailing).bold()
            Group {
                if manca > 0 { num("−" + eurc(manca), PSE.warn).bold() }
                else { Text("tutto incassato").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(PSE.pos).lineLimit(1) }
            }
            .frame(width: wManca, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
    }

    // ── Riepilogo per mese ──
    private var riepilogoMese: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RIEPILOGO PER MESE").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 8) {
                th("MESE").frame(maxWidth: .infinity, alignment: .leading)
                th("G-LETTO").frame(width: wCamera - 60, alignment: .trailing)
                th("LORDO").frame(width: wSoldi, alignment: .trailing)
                th("− COMM.").frame(width: wComm, alignment: .trailing)
                th("NETTO").frame(width: wSoldi, alignment: .trailing)
                th("UTENZE").frame(width: wComm, alignment: .trailing)
                th("TOT. OSPITI").frame(width: wSoldi, alignment: .trailing)
                th("NETTO NOI").frame(width: wSoldi, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
            ForEach(model.mesi, id: \.self) { m in
                riepRow(eduMeseNome(m), subtotali(model.righe(m)))
                Divider().overlay(PSE.line).padding(.leading, 16)
            }
            riepRow("TOTALE COMPLESSIVO", subtotali(model.righe), grande: true)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func riepRow(_ label: String, _ s: (g: Int, lo: Int, co: Int, ne: Int, ut: Int, to: Int, nn: Int), grande: Bool = false) -> some View {
        return HStack(spacing: 8) {
            Text(label).font(.system(size: grande ? 11 : 12, weight: grande ? .heavy : .semibold)).foregroundStyle(PSE.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            num("\(s.g)", PSE.dim).frame(width: wCamera - 60, alignment: .trailing)
            num(eurc(s.lo), PSE.text).frame(width: wSoldi, alignment: .trailing)
            num("−" + eurc(s.co), PSE.warn).frame(width: wComm, alignment: .trailing)
            num(eurc(s.ne), PSE.text).frame(width: wSoldi, alignment: .trailing)
            num(eurc(s.ut), PSE.accent).frame(width: wComm, alignment: .trailing)
            num(eurc(s.to), PSE.ink).frame(width: wSoldi, alignment: .trailing)
            num(eurc(s.nn), PSE.pos).frame(width: wSoldi, alignment: .trailing).bold()
        }
        .padding(.horizontal, 16).padding(.vertical, grande ? 11 : 8)
        .background(grande ? Color.white.opacity(0.04) : .clear)
    }

    // helper
    private func th(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint).lineLimit(1)
    }
    private func td(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(PSE.dim).lineLimit(1)
    }
    private func num(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 11.5)).foregroundStyle(c).monospacedDigit().lineLimit(1)
    }
}

// ── Finestra dei movimenti dietro a una spunta ──────────────────────────────
// Serve a rispondere a «perché questa riga risulta pagata?» senza andare a
// cercare in Tesoreria: qui ci sono i versamenti veri, con data, conto e modo.
struct EducampMovimentiSheet: View {
    let titolo: String
    let sottotitolo: String
    let righe: [TesMovimento]
    let onClose: () -> Void

    private var totale: Int { righe.reduce(0) { $0 + $1.importo_cents } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(titolo).font(.system(size: 15, weight: .bold)).foregroundStyle(PSE.ink)
                    Text(sottotitolo).font(.system(size: 11)).foregroundStyle(PSE.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.dim)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 14, trailing: 16))

            if righe.isEmpty {
                EmptyStateCard(icon: "banknote",
                               text: "Nessun movimento abbinato. Un incasso entra qui se ha categoria «educamp» e il nome dell'ospite scritto nella descrizione.")
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("DATA").frame(width: 70, alignment: .leading)
                        Text("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("MODO").frame(width: 80, alignment: .leading)
                        Text("CONTO").frame(width: 80, alignment: .leading)
                        Text("IMPORTO").frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 8.5, weight: .heavy)).tracking(0.7).foregroundStyle(PSE.faint)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(righe) { m in
                                HStack(spacing: 10) {
                                    Text(eduDayStr(m.data)).font(.system(size: 11.5)).monospacedDigit()
                                        .foregroundStyle(PSE.dim).frame(width: 70, alignment: .leading)
                                    Text(m.descrizione ?? "—").font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(PSE.ink).frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text((m.modalita ?? "—").capitalized).font(.system(size: 11))
                                        .foregroundStyle(PSE.faint).frame(width: 80, alignment: .leading).lineLimit(1)
                                    Text((m.conto_id ?? "—").capitalized).font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(PSE.accent).frame(width: 80, alignment: .leading).lineLimit(1)
                                    Text("+" + eurc(m.importo_cents)).font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(PSE.pos).monospacedDigit().frame(width: 90, alignment: .trailing)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                Divider().overlay(PSE.line).padding(.leading, 16)
                            }
                        }
                    }
                    HStack {
                        Text("TOTALE \(righe.count) VERSAMENTI").font(.system(size: 10, weight: .heavy))
                            .tracking(0.8).foregroundStyle(PSE.ink)
                        Spacer()
                        Text(eurc(totale)).font(.system(size: 14, weight: .bold))
                            .foregroundStyle(PSE.pos).monospacedDigit()
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
        .frame(width: 780, height: 520)
        .background(Color(hex: 0x0b0f18))
        .preferredColorScheme(.dark)
    }
}
