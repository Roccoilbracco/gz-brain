import SwiftUI

// ============================================================================
// Camere PSE — Servizi: Pulizie · Colazioni · Utenze (come i fogli dell'Excel)
// Pulizia 20 €/check-out · Colazioni 3,50 €/pers·notte (Booking) · Utenze Educamp.
// Sorgente: public.pulizie + public.colazioni + public.educamp_righe.
// ============================================================================

struct Pulizia: Identifiable, Decodable, Equatable {
    let id: String
    var data: String?
    var casa: String?
    var descrizione: String?
    var stato: String?
    var costo_cents: Int
    var sort_order: Int?
}
struct Colazione: Identifiable, Decodable, Equatable {
    let id: String
    var ospite: String?
    var camera: String?
    var arrivo: String?
    var partenza: String?
    var notti: Int?
    var persone: Int?
    var costo_totale_cents: Int
    var notti_servite: Int?
    var costo_servito_cents: Int
    var stato: String?
    var sort_order: Int?
}

extension HubAPI {
    static func listPulizie() async throws -> [Pulizia] {
        try await sb.fetch("pulizie?select=*&order=sort_order.asc")
    }
    static func listColazioni() async throws -> [Colazione] {
        try await sb.fetch("colazioni?select=*&order=sort_order.asc")
    }
}

private let svYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let svDay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "dd/MM"; return f }()
private func svDayStr(_ s: String?) -> String {
    guard let s, let d = svYmd.date(from: String(s.prefix(10))) else { return "—" }
    return svDay.string(from: d)
}
private func casaLbl(_ s: String?) -> String { s == "via-po" ? "Via Po" : s == "via-romagna" ? "Via Romagna" : "—" }

enum ServizioTab: String, CaseIterable, Identifiable { case pulizie = "Pulizie", colazioni = "Colazioni", utenze = "Utenze"; var id: String { rawValue } }

@MainActor final class ServiziModel: ObservableObject {
    @Published var pulizie: [Pulizia] = []
    @Published var colazioni: [Colazione] = []
    @Published var utenze: [EducampRiga] = []
    @Published var loading = true
    func load() async {
        loading = true
        pulizie = (try? await HubAPI.listPulizie()) ?? []
        colazioni = (try? await HubAPI.listColazioni()) ?? []
        utenze = (try? await HubAPI.listEducampRighe()) ?? []
        loading = false
    }
}

struct ServiziView: View {
    @Binding var tab: ServizioTab
    @StateObject private var model = ServiziModel()

    var body: some View {
        Group {
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .pulizie: pulizieView
                        case .colazioni: colazioniView
                        case .utenze: utenzeView
                        }
                    }.padding(.bottom, 20)
                }
            }
        }
        .task { await model.load() }
    }

    // ── PULIZIE ──
    private var pulizieView: some View {
        let fatte = model.pulizie.filter { $0.stato == "fatta" }
        let previste = model.pulizie.filter { $0.stato == "prevista" }
        let totF = fatte.reduce(0) { $0 + $1.costo_cents }
        let totP = previste.reduce(0) { $0 + $1.costo_cents }
        let vpF = fatte.filter { $0.casa == "via-po" }.reduce(0) { $0 + $1.costo_cents }
        let vrF = fatte.filter { $0.casa == "via-romagna" }.reduce(0) { $0 + $1.costo_cents }
        return VStack(alignment: .leading, spacing: 12) {
            Text("PULIZIA E LAVANDERIA — 20 € per ogni check-out (per camera)")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
            HStack(spacing: 12) {
                card("FATTE (uscita in cassa)", eur(totF), PSE.pos)
                card("PREVISTE (future)", eur(totP), PSE.warn)
                card("TOTALE", eur(totF + totP), PSE.ink)
                card("N. CHECK-OUT", "\(model.pulizie.count)", PSE.accent)
            }
            HStack(spacing: 12) {
                card("FATTE — VIA PO", eur(vpF), PSE.accent)
                card("FATTE — VIA ROMAGNA", eur(vrF), PSE.accent)
                Color.clear.frame(maxWidth: .infinity); Color.clear.frame(maxWidth: .infinity)
            }
            tableCard {
                pulHeader
                ForEach(Array(model.pulizie.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 10) {
                        num(svDayStr(p.data), PSE.dim).frame(width: 54, alignment: .leading)
                        td(casaLbl(p.casa)).frame(width: 96, alignment: .leading)
                        Text(p.descrizione ?? "—").font(.system(size: 12)).foregroundStyle(PSE.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        statoPill(p.stato)
                        num(eur(p.costo_cents), PSE.text).frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    if i < model.pulizie.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                }
            }
            Text("Solo le pulizie «Fatte» sono conteggiate come uscita in cassa; le «Previste» sono costi futuri.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }
    private var pulHeader: some View {
        HStack(spacing: 10) {
            th("DATA").frame(width: 54, alignment: .leading)
            th("CASA").frame(width: 96, alignment: .leading)
            th("CAMERA / OSPITE").frame(maxWidth: .infinity, alignment: .leading)
            th("STATO").frame(width: 78, alignment: .leading)
            th("COSTO").frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }

    // ── COLAZIONI ──
    private var colazioniView: some View {
        let serv = model.colazioni.reduce(0) { $0 + $1.costo_servito_cents }
        let tot = model.colazioni.reduce(0) { $0 + $1.costo_totale_cents }
        return VStack(alignment: .leading, spacing: 12) {
            Text("COLAZIONI — 3,50 € per persona / giorno (solo prenotazioni Booking)")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
            HStack(spacing: 12) {
                card("GIÀ SERVITE (uscita)", eurc(serv), PSE.pos)
                card("PREVISTE (future)", eurc(tot - serv), PSE.warn)
                card("TOTALE", eurc(tot), PSE.ink)
                card("N. PRENOTAZIONI", "\(model.colazioni.count)", PSE.accent)
            }
            tableCard {
                colHeader
                ForEach(Array(model.colazioni.enumerated()), id: \.element.id) { i, cz in
                    HStack(spacing: 10) {
                        Text(cz.ospite ?? "—").font(.system(size: 12, weight: .medium)).foregroundStyle(PSE.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        td(cz.camera ?? "—").frame(width: 120, alignment: .leading)
                        num("\(svDayStr(cz.arrivo))–\(svDayStr(cz.partenza))", PSE.dim).frame(width: 96, alignment: .leading)
                        num("\(cz.notti ?? 0)", PSE.dim).frame(width: 44, alignment: .trailing)
                        num("\(cz.persone ?? 0)", PSE.dim).frame(width: 54, alignment: .trailing)
                        num(eurc(cz.costo_totale_cents), PSE.text).frame(width: 74, alignment: .trailing)
                        num(eurc(cz.costo_servito_cents), PSE.pos).frame(width: 78, alignment: .trailing)
                        statoPill(cz.stato)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    if i < model.colazioni.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                }
            }
            Text("Solo le colazioni «già servite» sono conteggiate come spesa. Le prenotazioni dirette e Airbnb non hanno colazione.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }
    }
    private var colHeader: some View {
        HStack(spacing: 10) {
            th("OSPITE").frame(maxWidth: .infinity, alignment: .leading)
            th("CAMERA").frame(width: 120, alignment: .leading)
            th("PERIODO").frame(width: 96, alignment: .leading)
            th("NOTTI").frame(width: 44, alignment: .trailing)
            th("PERS.").frame(width: 54, alignment: .trailing)
            th("TOTALE").frame(width: 74, alignment: .trailing)
            th("SERVITO").frame(width: 78, alignment: .trailing)
            th("STATO").frame(width: 78, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }

    // ── UTENZE (da Educamp: 8 €/giorno per camera divisi tra i presenti) ──
    private var utenzeView: some View {
        let mesi = Array(Set(model.utenze.map { $0.mese })).sorted()
        let tot = model.utenze.reduce(0) { $0 + $1.utenze_cents }
        return VStack(alignment: .leading, spacing: 12) {
            Text("UTENZE EDUCAMP — VIA ROMAGNA · 8 €/giorno per camera (6 € se una sola persona), interamente nostre")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim)
            HStack(spacing: 12) {
                card("TOTALE UTENZE", eurc(tot), PSE.accent)
                ForEach(mesi, id: \.self) { m in
                    card(meseBreve(m).uppercased(), eurc(model.utenze.filter { $0.mese == m }.reduce(0) { $0 + $1.utenze_cents }), PSE.dim)
                }
            }
            ForEach(mesi, id: \.self) { m in
                let righe = model.utenze.filter { $0.mese == m }.sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }
                let sub = righe.reduce(0) { $0 + $1.utenze_cents }
                tableCard {
                    HStack {
                        Text(meseBreve(m).uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.accent)
                        Spacer()
                        Text(eurc(sub)).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.accent).monospacedDigit()
                    }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                    HStack(spacing: 10) {
                        th("OSPITE").frame(maxWidth: .infinity, alignment: .leading)
                        th("CAMERA").frame(width: 200, alignment: .leading)
                        th("GIORNI").frame(width: 60, alignment: .trailing)
                        th("UTENZE").frame(width: 90, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
                    ForEach(Array(righe.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 10) {
                            Text(r.ospite).font(.system(size: 12, weight: .medium)).foregroundStyle(PSE.ink)
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            td(r.camera ?? "—").frame(width: 200, alignment: .leading)
                            num("\(r.giorni ?? 0)", PSE.dim).frame(width: 60, alignment: .trailing)
                            num(eurc(r.utenze_cents), PSE.accent).frame(width: 90, alignment: .trailing)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        if i < righe.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                    }
                }
            }
        }
    }
    private func meseBreve(_ key: String) -> String {
        guard let d = svYmd.date(from: key + "-01") else { return key }
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMMM yyyy"
        return f.string(from: d).capitalized
    }

    // ── helper ──
    private func tableCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content().padding(.bottom, 6) }
            .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func card(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint).lineLimit(1)
            Text(v).font(.system(size: 17, weight: .bold)).foregroundStyle(c).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func statoPill(_ s: String?) -> some View {
        let done = (s == "fatta" || s == "servite")
        return Text((s ?? "—").capitalized)
            .font(.system(size: 9.5, weight: .heavy)).tracking(0.5)
            .foregroundStyle(done ? PSE.pos : PSE.warn)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill((done ? PSE.pos : PSE.warn).opacity(0.14)))
            .overlay(Capsule().strokeBorder((done ? PSE.pos : PSE.warn).opacity(0.45), lineWidth: 1))
            .frame(width: 78, alignment: .leading)
    }
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
