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
    // Le bollette servono qui per il confronto: quanto riprendiamo dagli
    // inquilini contro quanto esce davvero di utenze.
    @Published var bollette: [Bolletta] = []
    @Published var loading = true
    func load() async {
        loading = true
        ospiti = (try? await HubAPI.listEducampOspiti()) ?? []
        righe = (try? await HubAPI.listEducampRighe()) ?? []
        bollette = (try? await HubAPI.listBollette()) ?? []
        loading = false
    }
    var mesi: [String] { Array(Set(righe.map { $0.mese })).sorted() }
    func righe(_ mese: String) -> [EducampRiga] {
        righe.filter { $0.mese == mese }.sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }
    }
}

struct EducampView: View {
    @StateObject private var model = EducampModel()

    // larghezze colonne tabella mensile
    private let wCamera: CGFloat = 150, wGiorni: CGFloat = 46, wSoldi: CGFloat = 82, wComm: CGFloat = 70

    var body: some View {
        Group {
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        intestazione
                        kpi
                        utenzeBlocco
                        elencoOspiti
                        ForEach(model.mesi, id: \.self) { m in meseTable(m) }
                        riepilogoMese
                        Text("Affitto lordo = quello che paga l'ospite (380 €/mese per letto, commissione inclusa). La commissione è la parte per l'intermediario. Utenze: 8 €/giorno per camera divisi tra i presenti (6 € se resta una persona). Il mese è contato come 30 giorni.")
                            .font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .task { await model.load() }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(futuro ? PSE.warn.opacity(0.35) : PSE.line, lineWidth: 1))
    }
    private func card(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint).lineLimit(1)
            Text(v).font(.system(size: 16, weight: .bold)).foregroundStyle(c).monospacedDigit()
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
    private func meseTable(_ mese: String) -> some View {
        let righe = model.righe(mese)
        let sub = subtotali(righe)
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(eduMeseNome(mese).uppercased())  ·  mese contato come 30 giorni")
                .font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.accent)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            meseHeader
            ForEach(Array(righe.enumerated()), id: \.element.id) { i, r in
                meseRow(r)
                if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
            }
            Divider().overlay(PSE.line)
            subtotaleRow(sub, label: "SUBTOTALE \(eduMeseNome(mese).uppercased())")
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    private var meseHeader: some View {
        HStack(spacing: 8) {
            th("OSPITE").frame(maxWidth: .infinity, alignment: .leading)
            th("CAMERA").frame(width: wCamera, alignment: .leading)
            th("GIORNI").frame(width: wGiorni, alignment: .trailing)
            th("LORDO").frame(width: wSoldi, alignment: .trailing)
            th("− COMM.").frame(width: wComm, alignment: .trailing)
            th("NETTO").frame(width: wSoldi, alignment: .trailing)
            th("UTENZE").frame(width: wComm, alignment: .trailing)
            th("TOT. OSPITE").frame(width: wSoldi, alignment: .trailing)
            th("NETTO NOI").frame(width: wSoldi, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    private func meseRow(_ r: EducampRiga) -> some View {
        return HStack(spacing: 8) {
            Text(r.ospite).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            td(r.camera ?? "—").frame(width: wCamera, alignment: .leading)
            num("\(r.giorni ?? 0)", PSE.dim).frame(width: wGiorni, alignment: .trailing)
            num(eurc(r.lordo_cents), PSE.text).frame(width: wSoldi, alignment: .trailing)
            num("−" + eurc(r.commissione_cents), PSE.warn).frame(width: wComm, alignment: .trailing)
            num(eurc(r.netto_cents), PSE.text).frame(width: wSoldi, alignment: .trailing)
            num(eurc(r.utenze_cents), PSE.accent).frame(width: wComm, alignment: .trailing)
            num(eurc(r.totale_ospite_cents), PSE.ink).frame(width: wSoldi, alignment: .trailing)
            num(eurc(r.netto_noi_cents), PSE.pos).frame(width: wSoldi, alignment: .trailing).bold()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func subtotali(_ rs: [EducampRiga]) -> (g: Int, lo: Int, co: Int, ne: Int, ut: Int, to: Int, nn: Int) {
        rs.reduce((0,0,0,0,0,0,0)) { a, r in
            (a.0 + (r.giorni ?? 0), a.1 + r.lordo_cents, a.2 + r.commissione_cents, a.3 + r.netto_cents,
             a.4 + r.utenze_cents, a.5 + r.totale_ospite_cents, a.6 + r.netto_noi_cents)
        }
    }
    private func subtotaleRow(_ s: (g: Int, lo: Int, co: Int, ne: Int, ut: Int, to: Int, nn: Int), label: String) -> some View {
        return HStack(spacing: 8) {
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
