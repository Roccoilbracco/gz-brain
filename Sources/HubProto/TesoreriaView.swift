import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ============================================================================
// Camere PSE — Tesoreria (dentro il progetto Camere PSE)
// Conti (Cassa / Massimo OTA / Beeper), Movimenti entrate·uscite, Riepilogo,
// Conto economico, Educamp e Servizi (Pulizia 20€/check-out, Colazioni
// 3,50€/pers·notte Booking).
// Sorgente: public.conti + public.movimenti (+ pulizie/colazioni per i servizi).
// Tutti gli importi in contabilità si mostrano con i centesimi: eurc().
// ============================================================================

struct Conto: Identifiable, Decodable, Equatable {
    let id: String
    var nome: String
    var tipo: String
    var sort_order: Int
}

struct TesMovimento: Identifiable, Decodable, Equatable {
    let id: String
    var data: String
    var struttura: String?
    var tipo: String            // entrata | uscita
    var categoria: String?
    var descrizione: String?
    var importo_cents: Int
    var modalita: String?
    var conto_id: String?
}

extension HubAPI {
    static func listConti() async throws -> [Conto] { try await sb.fetch("conti?select=*&order=sort_order.asc") }
    static func listMovimenti() async throws -> [TesMovimento] { try await sb.fetch("movimenti?select=*&order=data.desc&limit=3000") }
    @discardableResult
    static func createTesMovimento(_ f: [String: Any?]) async throws -> TesMovimento { try await sb.insertReturning("movimenti", body: f) }
    static func updateTesMovimento(id: String, fields: [String: Any?]) async throws {
        var b = fields; b["updated_at"] = isoNowString()
        try await sb.mutate("movimenti?id=eq.\(id)", method: "PATCH", body: b)
    }
    static func deleteTesMovimento(id: String) async throws { try await sb.mutate("movimenti?id=eq.\(id)", method: "DELETE") }
    static func deleteMovimentoByExtKey(_ key: String) async throws {
        let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        try await sb.mutate("movimenti?ext_key=eq.\(enc)", method: "DELETE")
    }
}

private let tesYmd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let tesPretty: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM"; return f }()
private func tesDate(_ s: String?) -> Date? { s.flatMap { tesYmd.date(from: String($0.prefix(10))) } }
private func tesPrettyStr(_ s: String?) -> String { tesDate(s).map { tesPretty.string(from: $0) } ?? "—" }

// Tariffe dei servizi: le righe vere stanno nelle tabelle public.pulizie e
// public.colazioni (sezione Servizi), queste restano come riferimento del calcolo.
let CLEAN_COST = 2000      // 20,00 € per check-out
let BREAKFAST_COST = 350   // 3,50 € per persona/notte (solo Booking)

@MainActor final class TesoreriaModel: ObservableObject {
    @Published var conti: [Conto] = []
    @Published var movimenti: [TesMovimento] = []
    // Pulizie e colazioni arrivano dalle stesse tabelle che legge la sezione
    // Servizi: il Riepilogo non li ricalcola dalle prenotazioni, altrimenti le
    // due schermate mostrerebbero due numeri diversi per la stessa voce.
    @Published var pulizie: [Pulizia] = []
    @Published var colazioni: [Colazione] = []
    @Published var loading = true
    func load() async {
        loading = true
        conti = (try? await HubAPI.listConti()) ?? []
        movimenti = (try? await HubAPI.listMovimenti()) ?? []
        pulizie = (try? await HubAPI.listPulizie()) ?? []
        colazioni = (try? await HubAPI.listColazioni()) ?? []
        loading = false
    }
    func saldo(_ contoId: String) -> Int {
        var t = 0
        for m in movimenti where m.conto_id == contoId {
            t += (m.tipo == "entrata") ? m.importo_cents : -m.importo_cents
        }
        return t
    }
    var totaleConti: Int {
        var t = 0
        for c in conti { t += saldo(c.id) }
        return t
    }
}

enum TesSub: String, CaseIterable, Identifiable { case riepilogo = "Riepilogo", conti = "Conti", contoEconomico = "Conto economico", educamp = "Educamp", servizi = "Servizi", movimenti = "Movimenti"; var id: String { rawValue } }

// nome mese esteso "MMMM yyyy" da chiave "yyyy-MM"
private let tesMese: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMMM yyyy"; return f }()
private func meseNome(_ key: String) -> String {
    guard let d = tesYmd.date(from: key + "-01") else { return key }
    return tesMese.string(from: d).capitalized
}

struct TesoreriaView: View {
    let prenotazioni: [Prenotazione]
    @Binding var newTrigger: Bool
    @StateObject private var model = TesoreriaModel()
    @State private var sub: TesSub = .riepilogo
    @State private var showForm = false
    @State private var editing: TesMovimento?
    @State private var movStrut: Struttura? = nil
    // "tutto" | "2026" (anno) | "2026-07" (mese): il confronto è per prefisso, così
    // la stessa voce di menu copre sia gli anni sia i mesi.
    @State private var periodo: String = "tutto"
    @State private var cerca: String = ""
    @State private var contoSel: String = "tutti"     // "tutti" = tutti i conti insieme; altrimenti id conto
    @State private var servizioSel: ServizioTab = .pulizie

    private func nelPeriodo(_ m: TesMovimento) -> Bool { periodo == "tutto" || m.data.hasPrefix(periodo) }
    private func matchCerca(_ m: TesMovimento) -> Bool {
        let q = cerca.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return [m.descrizione, m.categoria, m.modalita].contains { ($0 ?? "").lowercased().contains(q) }
    }
    private var visibiliMov: [TesMovimento] {
        model.movimenti.filter { m in
            (movStrut == nil || m.struttura == movStrut!.rawValue) && nelPeriodo(m) && matchCerca(m)
        }
    }
    private var movEntrate: Int { var t = 0; for m in visibiliMov where m.tipo == "entrata" { t += m.importo_cents }; return t }
    private var movUscite: Int { var t = 0; for m in visibiliMov where m.tipo == "uscita" { t += m.importo_cents }; return t }
    private var anniDisponibili: [String] { Set(model.movimenti.map { String($0.data.prefix(4)) }).sorted(by: >) }
    private var mesiDisponibili: [(String, String)] {
        let keys = Set(model.movimenti.map { String($0.data.prefix(7)) })
        return keys.sorted(by: >).compactMap { k in
            guard tesYmd.date(from: k + "-01") != nil else { return nil }
            return (k, meseNome(k))
        }
    }
    private var periodoLabel: String {
        if periodo == "tutto" { return "Tutti i periodi" }
        if periodo.count == 4 { return "Anno \(periodo)" }
        return mesiDisponibili.first { $0.0 == periodo }?.1 ?? periodo
    }
    private func casaStats(_ s: Struttura) -> (inc: Int, spese: Int) {
        var inc = 0, spese = 0
        for m in model.movimenti where m.struttura == s.rawValue {
            if m.tipo == "entrata" { inc += m.importo_cents } else { spese += m.importo_cents }
        }
        return (inc, spese)
    }
    private var prenFiltrate: [Prenotazione] { prenotazioni.filter { $0.status != "cancellata" } }

    // ── servizi: stessi dati della sezione Servizi (tabelle pulizie/colazioni) ──
    private var puliziaFatte: Int { model.pulizie.filter { $0.stato == "fatta" }.reduce(0) { $0 + $1.costo_cents } }
    private var puliziePreviste: Int { model.pulizie.filter { $0.stato != "fatta" }.reduce(0) { $0 + $1.costo_cents } }
    private var colazioni: (servite: Int, totale: Int) {
        (model.colazioni.reduce(0) { $0 + $1.costo_servito_cents },
         model.colazioni.reduce(0) { $0 + $1.costo_totale_cents })
    }
    // conto di destinazione dei soldi di una prenotazione (OTA→Massimo, dirette→scelto/Beeper)
    private func contoDest(_ b: Prenotazione) -> String {
        if let c = b.conto_id, !c.isEmpty { return c }
        let s = b.source ?? ""
        return (s == "booking" || s == "airbnb") ? "massimo" : "beeper"
    }
    private func daIncassare(_ contoId: String) -> Int {
        var t = 0
        for b in prenFiltrate where contoDest(b) == contoId {
            t += max(0, b.amount_cents - b.paid_cents)
        }
        return t
    }
    // da incassare del periodo/casa selezionati (checkin nel periodo, filtro casa)
    private var daIncassarePeriodo: Int {
        var t = 0
        for b in prenFiltrate {
            if let s = movStrut, b.struttura != s.rawValue { continue }
            if periodo != "tutto" && !(b.checkin ?? "").hasPrefix(periodo) { continue }
            t += max(0, b.amount_cents - b.paid_cents)
        }
        return t
    }
    private var daIncassareTot: Int {
        var t = 0
        for c in model.conti { t += daIncassare(c.id) }
        return t
    }
    // da incassare per canale/fonte
    private func daIncassareSource(_ srcs: [String]) -> Int {
        var t = 0
        for b in prenFiltrate where srcs.contains(b.source ?? "") {
            t += max(0, b.amount_cents - b.paid_cents)
        }
        return t
    }
    private var daIncassareDirette: Int { daIncassareSource(["diretto", "sito", "whatsapp", "telefono", "email"]) }
    // Booking trattiene il 16,5%: quanto del «da incassare» lordo non arriverà mai
    // sul conto. Airbnb e dirette non hanno commissione.
    private var commissioneAttesa: Int { Int((Double(daIncassareSource(["booking"])) * 0.165).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PSESegmented(items: TesSub.allCases.map { ($0, $0.rawValue) }, selection: $sub)
                if sub == .conti {
                    PSESegmented(items: [("tutti", "Tutti i conti")] + model.conti.map { ($0.id, $0.nome) }, selection: $contoSel)
                } else if sub == .servizi {
                    PSESegmented(items: ServizioTab.allCases.map { ($0, $0.rawValue) }, selection: $servizioSel)
                } else if sub == .contoEconomico || sub == .movimenti {
                    PSESegmented(items: [(nil, "Tutte"), (.viaPo, "Via Po"), (.viaRomagna, "Via Romagna")] as [(Struttura?, String)], selection: $movStrut)
                }
                if sub == .conti || sub == .contoEconomico || sub == .movimenti { periodoMenu }
                if sub == .movimenti { campoCerca }
                Spacer()
                if sub == .movimenti {
                    Text("\(visibiliMov.count) movimenti").font(.system(size: 11, weight: .medium)).foregroundStyle(PSE.faint)
                }
                if sub == .conti || sub == .contoEconomico || sub == .movimenti { exportButton }
            }
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    switch sub {
                    case .riepilogo: riepilogo
                    case .conti: contiView
                    case .contoEconomico: contoEconomico
                    case .educamp: EducampView()
                    case .servizi: ServiziView(tab: $servizioSel)
                    case .movimenti: movimentiList
                    }
                }
            }
        }
        .task { await model.load() }
        .onChange(of: newTrigger) { _, v in
            if v { editing = nil; sub = .movimenti; showForm = true; newTrigger = false }
        }
        .sheet(isPresented: $showForm, onDismiss: { editing = nil }) {
            TesMovimentoForm(conti: model.conti, existing: editing) { await model.load() }
        }
    }

    // ── Riepilogo (conti + servizi uniti) ──
    private var riepilogo: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(model.conti) { c in contoCard(c) }
            }
            HStack(spacing: 12) {
                totCard("TOTALE CONTI (incassato, netto)", model.totaleConti, PSE.accent)
                totCard("POTENZIALE (+ da incassare lordo)", model.totaleConti + daIncassareTot, PSE.pos)
            }
            Text("DA INCASSARE — prenotazioni confermate, soldi non ancora incassati · IMPORTI LORDI OTA").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.warn).padding(.top, 6)
            HStack(spacing: 12) {
                totCard("BOOKING (lordo)", daIncassareSource(["booking"]), PSE.warn)
                totCard("AIRBNB", daIncassareSource(["airbnb"]), PSE.warn)
                totCard("DIRETTE", daIncassareDirette, PSE.warn)
                totCard("TOTALE (lordo)", daIncassareTot, PSE.pos)
            }
            Text("PER CASA — entrate, spese e utile registrati").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint).padding(.top, 6)
            HStack(spacing: 12) {
                casaCard(.viaPo)
                casaCard(.viaRomagna)
            }
            Text("SERVIZI").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint).padding(.top, 6)
            HStack(spacing: 12) {
                servCard("PULIZIA — FATTE", puliziaFatte, "sparkles", PSE.dim)
                servCard("PULIZIA — PREVISTE", puliziePreviste, "sparkles", PSE.warn)
                servCard("COLAZIONI BOOKING", colazioni.totale, "cup.and.saucer.fill", PSE.accent)
            }
            Text("I saldi dei conti sono NETTI (su Massimo la commissione Booking è già registrata come uscita); il «da incassare» invece è LORDO, quello che il cliente paga all'OTA. Su Booking arriverà circa il 16,5% in meno — oggi ≈ \(eurc(commissioneAttesa)) — mentre Airbnb e le dirette non hanno commissione. Perciò il «potenziale» è un tetto, non l'incasso atteso.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)
            Text("OTA (Booking/Airbnb) → conto Massimo · dirette → Beeper o Cassa (scelto per prenotazione). Pulizia 20 €/check-out. Le colazioni Booking (3,50 €/pers·notte) sono aggiunte automaticamente ai Movimenti.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }.padding(.bottom, 20)
    }
    private func contoCard(_ c: Conto) -> some View {
        let s = model.saldo(c.id)
        let inc = daIncassare(c.id)
        return VStack(alignment: .leading, spacing: 7) {
            Text(c.nome.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.5).foregroundStyle(PSE.faint).lineLimit(1)
            Text(eurc(s)).font(.system(size: 22, weight: .bold)).foregroundStyle(s < 0 ? PSE.neg : PSE.ink).monospacedDigit()
            if inc > 0 {
                Text("+ \(eurc(inc)) da incassare\(c.tipo == "ota" ? " (lordo)" : "")").font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.warn)
            } else {
                Text(c.tipo == "cassa" ? "Contante" : c.tipo == "ota" ? "Booking + Airbnb" : "Banca").font(.system(size: 10)).foregroundStyle(PSE.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func totCard(_ t: String, _ v: Int, _ c: Color) -> some View { testoCard(t, eurc(v), c) }
    private func testoCard(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
            Text(v).font(.system(size: 18, weight: .bold)).foregroundStyle(c).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── Movimenti ──
    private var periodoMenu: some View {
        Menu {
            Button("Tutti i periodi") { periodo = "tutto" }
            Divider()
            ForEach(anniDisponibili, id: \.self) { a in Button("Anno \(a)") { periodo = a } }
            Divider()
            ForEach(mesiDisponibili, id: \.0) { m in Button(m.1) { periodo = m.0 } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 10))
                Text(periodoLabel).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(periodo == "tutto" ? PSE.dim : PSE.ink).padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(periodo == "tutto" ? PSE.line : PSE.accent.opacity(0.7), lineWidth: 1))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
    private var campoCerca: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(PSE.faint)
            TextField("Cerca", text: $cerca)
                .textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(PSE.ink).frame(width: 130)
            if !cerca.isEmpty {
                Button { cerca = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(PSE.faint)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
    }
    private var movimentiList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                totCard("ENTRATE", movEntrate, PSE.pos)
                totCard("USCITE", movUscite, PSE.neg)
                totCard("SALDO PERIODO", movEntrate - movUscite, PSE.accent)
                totCard("DA INCASSARE (lordo)", daIncassarePeriodo, PSE.warn)
            }
            VStack(spacing: 0) {
                if visibiliMov.isEmpty {
                    EmptyStateCard(icon: "tray", text: "Nessun movimento per il filtro scelto.")
                } else {
                    movHeader
                    ForEach(visibiliMov) { m in
                        movRow(m)
                        Divider().overlay(PSE.line).padding(.leading, 16)
                    }
                    movTotaleRow
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
        }
        .padding(.bottom, 20)
    }
    private var movHeader: some View {
        HStack(spacing: 12) {
            Text("DATA").frame(width: 62, alignment: .leading)
            Text("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
            Text("CASA").frame(width: 96, alignment: .leading)
            Text("CONTO").frame(width: 150, alignment: .leading)
            Text("CATEGORIA").frame(width: 100, alignment: .leading)
            Text("MODALITÀ").frame(width: 84, alignment: .leading)
            Text("IMPORTO").frame(width: 92, alignment: .trailing)
        }
        .font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    // Riga di chiusura della tabella: entrate, uscite e saldo di ciò che è
    // effettivamente a schermo, filtri compresi.
    private var movTotaleRow: some View {
        let saldo = movEntrate - movUscite
        return HStack(spacing: 12) {
            Text("TOTALE — \(visibiliMov.count) MOVIMENTI")
                .font(.system(size: 10.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.ink)
            Spacer()
            Text("+" + eurc(movEntrate)).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.pos).monospacedDigit()
            Text("−" + eurc(movUscite)).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.neg).monospacedDigit()
            Text("=").font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.faint)
            Text(eurc(saldo)).font(.system(size: 15, weight: .bold))
                .foregroundStyle(saldo < 0 ? PSE.neg : PSE.ink).monospacedDigit()
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white.opacity(0.04))
    }
    private func movRow(_ m: TesMovimento) -> some View {
        let entrata = m.tipo == "entrata"
        let contoNome = model.conti.first { $0.id == m.conto_id }?.nome ?? (m.conto_id ?? "—")
        let casa = m.struttura == "via-po" ? "Via Po" : m.struttura == "via-romagna" ? "Via Romagna" : "—"
        return Button { editing = m; showForm = true } label: {
            HStack(spacing: 12) {
                Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim).frame(width: 62, alignment: .leading).monospacedDigit()
                Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(casa).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 96, alignment: .leading).lineLimit(1)
                Text(contoNome).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 150, alignment: .leading).lineLimit(1)
                Text((m.categoria ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(PSE.faint).frame(width: 100, alignment: .leading).lineLimit(1)
                Text((m.modalita ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(PSE.faint).frame(width: 84, alignment: .leading).lineLimit(1)
                Text((entrata ? "+" : "−") + eurc(m.importo_cents))
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(entrata ? PSE.pos : PSE.neg)
                    .frame(width: 92, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func servCard(_ t: String, _ v: Int, _ icon: String, _ c: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(c)
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
                Text(eurc(v)).font(.system(size: 18, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    // card per casa: entrate, spese, utile
    private func casaCard(_ s: Struttura) -> some View {
        let st = casaStats(s)
        let utile = st.inc - st.spese
        return VStack(alignment: .leading, spacing: 12) {
            Text(s.label.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.ink)
            HStack(spacing: 0) {
                miniStat("ENTRATE", st.inc, PSE.pos)
                miniStat("SPESE", st.spese, PSE.neg)
                miniStat("UTILE", utile, utile >= 0 ? PSE.pos : PSE.neg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func miniStat(_ t: String, _ v: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
            Text(eurc(v)).font(.system(size: 15, weight: .bold)).foregroundStyle(c).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // ══ CONTO ECONOMICO ══════════════════════════════════════════════════════
    // Vista temporale + per categoria: la parte che serve al commercialista e
    // per capire l'andamento. Rispetta il filtro casa (movStrut), tutti i mesi.

    private var movStrutFiltrati: [TesMovimento] {
        model.movimenti.filter { (movStrut == nil || $0.struttura == movStrut!.rawValue) && nelPeriodo($0) }
    }
    // (chiave "yyyy-MM", entrate, uscite) per mese, dal più recente
    private var mensili: [(key: String, entrate: Int, uscite: Int)] {
        var map: [String: (e: Int, u: Int)] = [:]
        for m in movStrutFiltrati {
            let k = String(m.data.prefix(7)); var v = map[k] ?? (0, 0)
            if m.tipo == "entrata" { v.e += m.importo_cents } else { v.u += m.importo_cents }
            map[k] = v
        }
        return map.keys.sorted(by: >).map { (key: $0, entrate: map[$0]!.e, uscite: map[$0]!.u) }
    }
    private func perCategoria(_ tipo: String) -> [(cat: String, tot: Int)] {
        var map: [String: Int] = [:]
        for m in movStrutFiltrati where m.tipo == tipo {
            let c = (m.categoria?.isEmpty == false) ? m.categoria! : "altro"
            map[c, default: 0] += m.importo_cents
        }
        return map.map { (cat: $0.key, tot: $0.value) }.sorted { $0.tot > $1.tot }
    }
    // Debiti e finanziamenti: rimborsi (debito vecchio, mutuo, rata prestito), non
    // costi di gestione. Vanno tenuti fuori dal margine operativo.
    private func isDebito(_ cat: String?) -> Bool {
        let c = (cat ?? "").lowercased()
        return ["debito", "debiti", "prestito", "mutuo", "rata", "finanziam"].contains { c.contains($0) }
    }
    private func perCategoriaUscite(debiti: Bool) -> [(cat: String, tot: Int)] {
        var map: [String: Int] = [:]
        for m in movStrutFiltrati where m.tipo == "uscita" && isDebito(m.categoria) == debiti {
            let c = (m.categoria?.isEmpty == false) ? m.categoria! : "altro"
            map[c, default: 0] += m.importo_cents
        }
        return map.map { (cat: $0.key, tot: $0.value) }.sorted { $0.tot > $1.tot }
    }
    private var totEntrate: Int { movStrutFiltrati.filter { $0.tipo == "entrata" }.reduce(0) { $0 + $1.importo_cents } }
    private var totUscite: Int { movStrutFiltrati.filter { $0.tipo == "uscita" }.reduce(0) { $0 + $1.importo_cents } }
    private var totCostiOperativi: Int { movStrutFiltrati.filter { $0.tipo == "uscita" && !isDebito($0.categoria) }.reduce(0) { $0 + $1.importo_cents } }
    private var totDebiti: Int { movStrutFiltrati.filter { $0.tipo == "uscita" && isDebito($0.categoria) }.reduce(0) { $0 + $1.importo_cents } }

    private var contoEconomico: some View {
        VStack(alignment: .leading, spacing: 12) {
            let utileOp = totEntrate - totCostiOperativi          // margine di gestione
            let utileNetto = utileOp - totDebiti                  // dopo debiti/finanziamenti
            let margineOp = totEntrate > 0 ? Int((Double(utileOp) / Double(totEntrate) * 100).rounded()) : 0
            // Gestione: entrate vs costi operativi (senza debiti)
            HStack(spacing: 12) {
                totCard("ENTRATE", totEntrate, PSE.pos)
                totCard("COSTI OPERATIVI", totCostiOperativi, PSE.neg)
                totCard("UTILE OPERATIVO", utileOp, utileOp >= 0 ? PSE.pos : PSE.neg)
                testoCard("MARGINE OP.", totEntrate > 0 ? "\(margineOp)%" : "—", PSE.accent)
            }
            // Sotto la gestione: debiti/finanziamenti e utile netto reale
            if totDebiti > 0 {
                HStack(spacing: 12) {
                    totCard("DEBITI / FINANZIAMENTI", totDebiti, PSE.warn)
                    totCard("UTILE NETTO (dopo debiti)", utileNetto, utileNetto >= 0 ? PSE.pos : PSE.neg)
                    Color.clear.frame(maxWidth: .infinity)
                }
            }

            Text("ANDAMENTO MENSILE").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint).padding(.top, 6)
            if mensili.isEmpty {
                EmptyStateCard(icon: "chart.bar", text: "Nessun movimento registrato.")
            } else {
                let maxAbs = max(1, mensili.map { abs($0.entrate - $0.uscite) }.max() ?? 1)
                VStack(spacing: 0) {
                    mensiliHeader
                    ForEach(Array(mensili.enumerated()), id: \.element.key) { i, r in
                        mensileRow(r, maxAbs: maxAbs)
                        if i < mensili.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
            }

            HStack(alignment: .top, spacing: 12) {
                categoriaCard("COSTI OPERATIVI PER CATEGORIA", perCategoriaUscite(debiti: false), totCostiOperativi, PSE.neg)
                categoriaCard("ENTRATE PER CATEGORIA", perCategoria("entrata"), totEntrate, PSE.pos)
            }
            .padding(.top, 6)

            if totDebiti > 0 {
                categoriaCard("DEBITI E FINANZIAMENTI (rimborsi)", perCategoriaUscite(debiti: true), totDebiti, PSE.warn)
                    .padding(.top, 2)
            }

            Text("Conto economico su base cassa. «Utile operativo» = entrate − costi di gestione; i debiti (Marroni, Muratore, mutuo, rata) sono rimborsi e restano fuori dal margine. Periodo: \(periodoLabel.lowercased()), filtro casa applicato. «Esporta CSV» per il commercialista.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)
        }.padding(.bottom, 20)
    }

    // ══ CONTI — estratto conto per conto (Cassa · Massimo · Beeper) ═══════════
    // Ogni conto come nel relativo foglio dell'Excel: entrate, uscite, saldo.
    private var tuttiIConti: Bool { contoSel == "tutti" }
    private var contoMovimenti: [TesMovimento] {
        (tuttiIConti ? model.movimenti : model.movimenti.filter { $0.conto_id == contoSel })
            .filter { nelPeriodo($0) }
            .sorted { $0.data > $1.data }
    }
    /// Saldo del conto (o di tutti) prima dell'inizio del periodo scelto: senza
    /// questo, filtrare per mese farebbe leggere come «saldo» il solo movimento
    /// del mese, che non è il saldo del conto.
    private var saldoIniziale: Int {
        guard periodo != "tutto" else { return 0 }
        var t = 0
        for m in model.movimenti where (tuttiIConti || m.conto_id == contoSel) && m.data < periodo {
            t += (m.tipo == "entrata") ? m.importo_cents : -m.importo_cents
        }
        return t
    }
    private func contoNomeBreve(_ id: String?) -> String {
        switch id { case "cassa": return "Cassa"; case "massimo": return "Massimo"; case "beeper": return "Beeper"; default: return id ?? "—" }
    }
    private var contiView: some View {
        let mov = contoMovimenti
        let entrate = mov.filter { $0.tipo == "entrata" }
        let uscite = mov.filter { $0.tipo == "uscita" }
        let totE = entrate.reduce(0) { $0 + $1.importo_cents }
        let totU = uscite.reduce(0) { $0 + $1.importo_cents }
        let conto = model.conti.first { $0.id == contoSel }
        let iniz = saldoIniziale
        let nome = tuttiIConti ? "TOTALE" : (conto?.nome.uppercased() ?? "")
        return VStack(alignment: .leading, spacing: 12) {
            // intestazione: col periodo filtrato l'estratto parte dal saldo
            // iniziale e chiude sul finale, come un vero estratto conto.
            HStack(spacing: 12) {
                if periodo == "tutto" {
                    testoCard("SALDO \(nome)", eurc(totE - totU), (totE - totU) < 0 ? PSE.neg : PSE.ink)
                    totCard("ENTRATE", totE, PSE.pos)
                    totCard("USCITE", totU, PSE.neg)
                    testoCard("N. MOVIMENTI", "\(mov.count)", PSE.accent)
                } else {
                    totCard("SALDO INIZIALE", iniz, iniz < 0 ? PSE.neg : PSE.dim)
                    totCard("ENTRATE", totE, PSE.pos)
                    totCard("USCITE", totU, PSE.neg)
                    testoCard("SALDO FINALE \(nome)", eurc(iniz + totE - totU), (iniz + totE - totU) < 0 ? PSE.neg : PSE.ink)
                }
            }
            // Con «Tutti i conti»: una card di saldo per ciascun conto (saldo pieno,
            // non del periodo: è quello che c'è davvero sul conto oggi)
            if tuttiIConti {
                HStack(spacing: 12) {
                    ForEach(model.conti) { c in
                        let s = model.saldo(c.id)
                        totCard("\(c.nome.uppercased()) — SALDO OGGI", s, s < 0 ? PSE.neg : PSE.accent)
                    }
                }
            }
            if mov.isEmpty {
                EmptyStateCard(icon: "tray", text: periodo == "tutto" ? "Nessun movimento." : "Nessun movimento in \(periodoLabel.lowercased()).")
            } else {
                contoLedger("ENTRATE", entrate, totE, PSE.pos, "+", showConto: tuttiIConti)
                contoLedger("USCITE", uscite, totU, PSE.neg, "−", showConto: tuttiIConti)
                // Riga finale: saldo iniziale + entrate − uscite = saldo finale
                rimanenteRow(iniz, totE, totU)
            }
            Text(contoNota).font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)
        }.padding(.bottom, 20)
    }
    private var contoNota: String {
        switch contoSel {
        case "tutti": return "Tutti i conti insieme: Cassa (contante) + Massimo (Booking, lordo entrata / commissione uscita) + Beeper (bonifici). La colonna «Conto» indica dove è transitato il denaro."
        case "massimo": return "Booking già incassato: importo lordo come entrata, commissione (16,5%) come uscita. Il saldo è il netto. Le prenotazioni future sono in «da incassare» (Riepilogo)."
        case "beeper": return "Estratto conto bonifici: affitti, depositi (da restituire) e uscite (rata prestito, muratore, Marroni, spese banca)."
        default: return "Contante Via Po + Via Romagna: affitti in entrata; pulizia, colazioni, chiavi e idraulico in uscita."
        }
    }
    private func contoLedger(_ title: String, _ items: [TesMovimento], _ tot: Int, _ c: Color, _ sign: String, showConto: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.faint)
                Spacer()
                Text(sign + eurc(tot)).font(.system(size: 12, weight: .bold)).foregroundStyle(c).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                Button { editing = m; showForm = true } label: {
                    HStack(spacing: 12) {
                        Text(tesPrettyStr(m.data)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim).frame(width: 58, alignment: .leading).monospacedDigit()
                        Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if showConto {
                            Text(contoNomeBreve(m.conto_id)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PSE.accent).frame(width: 76, alignment: .leading).lineLimit(1)
                        }
                        Text(casaLabel(m.struttura)).font(.system(size: 11)).foregroundStyle(PSE.dim).frame(width: 96, alignment: .leading).lineLimit(1)
                        Text((m.categoria ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(PSE.faint).frame(width: 100, alignment: .leading).lineLimit(1)
                        Text(sign + eurc(m.importo_cents)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(c).monospacedDigit().frame(width: 92, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if i < items.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
            }
            Color.clear.frame(height: 6)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func casaLabel(_ s: String?) -> String {
        s == "via-po" ? "Via Po" : s == "via-romagna" ? "Via Romagna" : "—"
    }
    // Riga di chiusura: saldo iniziale + entrate − uscite = saldo finale
    private func rimanenteRow(_ iniz: Int, _ totE: Int, _ totU: Int) -> some View {
        let saldo = iniz + totE - totU
        return HStack(spacing: 16) {
            Text(periodo == "tutto" ? "TOTALE RIMANENTE" : "SALDO FINALE").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(PSE.ink)
            Spacer()
            if periodo != "tutto" {
                Text(eurc(iniz)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.dim).monospacedDigit()
                    .help("Saldo prima dell'inizio del periodo")
            }
            Text("+\(eurc(totE))").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.pos).monospacedDigit()
            Text("−\(eurc(totU))").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.neg).monospacedDigit()
            Text("=").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PSE.faint)
            Text(eurc(saldo)).font(.system(size: 16, weight: .bold)).foregroundStyle(saldo < 0 ? PSE.neg : PSE.ink).monospacedDigit()
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    private var mensiliHeader: some View {
        HStack(spacing: 12) {
            Text("MESE").frame(width: 130, alignment: .leading)
            Text("ENTRATE").frame(width: 90, alignment: .trailing)
            Text("USCITE").frame(width: 90, alignment: .trailing)
            Text("UTILE").frame(width: 90, alignment: .trailing)
            Text("").frame(maxWidth: .infinity)
        }
        .font(.system(size: 8.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Rectangle().fill(PSE.line).frame(height: 1), alignment: .bottom)
    }
    private func mensileRow(_ r: (key: String, entrate: Int, uscite: Int), maxAbs: Int) -> some View {
        let utile = r.entrate - r.uscite
        let frac = min(1, Double(abs(utile)) / Double(maxAbs))
        return HStack(spacing: 12) {
            Text(meseNome(r.key)).font(.system(size: 12, weight: .semibold)).foregroundStyle(PSE.ink)
                .frame(width: 130, alignment: .leading).lineLimit(1)
            Text("+" + eurc(r.entrate)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(PSE.pos).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text("−" + eurc(r.uscite)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(PSE.neg).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(eurc(utile)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(utile >= 0 ? PSE.pos : PSE.neg).monospacedDigit().frame(width: 90, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(PSE.surface).frame(height: 8)
                    RoundedRectangle(cornerRadius: 3).fill((utile >= 0 ? PSE.pos : PSE.neg).opacity(0.75))
                        .frame(width: max(2, geo.size.width * frac), height: 8)
                }.frame(maxHeight: .infinity, alignment: .center)
            }.frame(height: 18)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func categoriaCard(_ title: String, _ rows: [(cat: String, tot: Int)], _ tot: Int, _ c: Color) -> some View {
        let maxTot = max(1, rows.first?.tot ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
            if rows.isEmpty {
                Text("Nessuna voce").font(.system(size: 11)).foregroundStyle(PSE.dim).padding(.vertical, 8)
            } else {
                ForEach(rows, id: \.cat) { r in
                    let pct = tot > 0 ? Int((Double(r.tot) / Double(tot) * 100).rounded()) : 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(r.cat.capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(eurc(r.tot)).font(.system(size: 12, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
                            Text("\(pct)%").font(.system(size: 10, weight: .semibold)).foregroundStyle(PSE.faint).frame(width: 34, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(PSE.surface).frame(height: 6)
                                RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * Double(r.tot) / Double(maxTot)), height: 6)
                            }
                        }.frame(height: 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── Export CSV per il commercialista (separatore ; per Excel IT) ──
    private var exportButton: some View {
        Button { exportCSV() } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .bold))
                Text("Esporta CSV").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(PSE.dim).padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
        }.buttonStyle(.plain).help("Esporta i movimenti visibili in CSV")
    }
    private func exportCSV() {
        // Movimenti → set filtrato visibile; Conti → estratto del conto; altro → tutti (filtro casa)
        let rows: [TesMovimento]
        switch sub {
        case .movimenti: rows = visibiliMov
        case .conti: rows = contoMovimenti
        default: rows = movStrutFiltrati.sorted { $0.data > $1.data }
        }
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "\u{FEFF}Data;Tipo;Struttura;Categoria;Descrizione;Conto;Modalità;Importo\n"
        for m in rows {
            let conto = model.conti.first { $0.id == m.conto_id }?.nome ?? (m.conto_id ?? "")
            let casa = m.struttura == "via-po" ? "Via Po" : m.struttura == "via-romagna" ? "Via Romagna" : ""
            let imp = String(format: "%.2f", Double(m.importo_cents) / 100).replacingOccurrences(of: ".", with: ",")
            csv += [m.data, m.tipo, casa, m.categoria ?? "", m.descrizione ?? "", conto, m.modalita ?? "", imp]
                .map { q($0) }.joined(separator: ";") + "\n"
        }
        // nome file parlante: sezione + casa + periodo, così i CSV per il
        // commercialista non finiscono tutti con lo stesso nome
        var parti = ["camere-pse", sub == .conti ? "conti-\(contoSel)" : sub == .contoEconomico ? "conto-economico" : "movimenti"]
        if let s = movStrut { parti.append(s.rawValue) }
        if periodo != "tutto" { parti.append(periodo) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = parti.joined(separator: "_") + ".csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.data(using: .utf8)?.write(to: url)
        }
    }
}

// ── Form nuovo/modifica movimento ──
private struct TesMovimentoForm: View {
    let conti: [Conto]
    let existing: TesMovimento?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var data = Date()
    @State private var contoId = "cassa"
    @State private var tipo = "uscita"
    @State private var categoria = ""
    @State private var descrizione = ""
    @State private var importo = ""
    @State private var modalita = "contante"
    @State private var struttura = "—"
    @State private var saving = false
    @State private var confermaElimina = false

    private let modalitaOpts = ["contante", "booking", "airbnb", "bonifico"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "NUOVO MOVIMENTO" : "MODIFICA MOVIMENTO")
                    .font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HStack(spacing: 12) {
                    pick("Tipo", [("entrata", "Entrata"), ("uscita", "Uscita")], tipo) { tipo = $0 }
                    pick("Conto", conti.map { ($0.id, $0.nome) }, contoId) { contoId = $0 }
                }
                HStack(spacing: 12) {
                    dateField("Data", $data)
                    HoloField(label: "Importo €", text: $importo, placeholder: "120").frame(width: 150)
                }
                HStack(spacing: 12) {
                    pick("Modalità", modalitaOpts.map { ($0, $0.capitalized) }, modalita) { modalita = $0 }
                    pick("Struttura", [("—", "Entrambe"), ("via-po", "Via Po"), ("via-romagna", "Via Romagna")], struttura) { struttura = $0 }
                }
                HoloField(label: "Categoria", text: $categoria, placeholder: "affitto, spesa, pulizia…")
                HoloField(label: "Descrizione", text: $descrizione, placeholder: "Es. Stanza Camino — Federica")

                HStack(spacing: 10) {
                    if existing != nil {
                        Button { confermaElimina = true } label: {
                            Text("Elimina").font(.system(size: 13)).foregroundStyle(Color(hex: 0xffb3ad))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }.buttonStyle(.plain)
                        .confirmationDialog("Eliminare questo movimento?", isPresented: $confermaElimina) {
                            Button("Elimina movimento", role: .destructive) { Task { await del() } }
                            Button("Annulla", role: .cancel) {}
                        } message: {
                            Text("\(existing?.descrizione ?? existing?.categoria ?? "Movimento") · \(eurc(existing?.importo_cents ?? 0)). L'operazione non si può annullare.")
                        }
                    }
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { Task { await save() } } label: {
                        Text(saving ? "Salvataggio…" : "Salva movimento").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain).disabled(saving || cents == nil)
                    .opacity(cents == nil ? 0.5 : 1)
                }.padding(.top, 4)
            }
            .padding(24)
        }
        .frame(width: 520, height: 470)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .onAppear(perform: fill)
    }

    private func dateField(_ label: String, _ date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
            DatePicker("", selection: date, displayedComponents: .date).labelsHidden().datePickerStyle(.compact).colorScheme(.dark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func pick(_ label: String, _ opts: [(String, String)], _ sel: String, _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
            Menu {
                ForEach(opts, id: \.0) { o in Button(o.1) { set(o.0) } }
            } label: {
                HStack(spacing: 8) {
                    Text(opts.first { $0.0 == sel }?.1 ?? "—").font(.system(size: 13)).foregroundStyle(Color(hex: 0xe8f2ff)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Holo.labelDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                .contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity)
    }

    private var cents: Int? {
        let s = importo.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(s), v > 0 else { return nil }
        return Int((v * 100).rounded())
    }
    private func fill() {
        guard let m = existing else { return }
        data = tesDate(m.data) ?? Date()
        contoId = m.conto_id ?? "cassa"; tipo = m.tipo
        categoria = m.categoria ?? ""; descrizione = m.descrizione ?? ""
        importo = String(format: "%.2f", Double(m.importo_cents) / 100)
        modalita = m.modalita ?? "contante"; struttura = m.struttura ?? "—"
    }
    private func fields() -> [String: Any?] {
        [ "data": tesYmd.string(from: data), "conto_id": contoId, "tipo": tipo,
          "categoria": categoria.isEmpty ? nil : categoria, "descrizione": descrizione.isEmpty ? nil : descrizione,
          "importo_cents": cents ?? 0, "modalita": modalita, "struttura": struttura == "—" ? nil : struttura ]
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            if let m = existing { try await HubAPI.updateTesMovimento(id: m.id, fields: fields()) }
            else { try await HubAPI.createTesMovimento(fields()) }
            await onSaved(); dismiss()
        } catch {}
    }
    private func del() async {
        guard let m = existing else { return }
        do { try await HubAPI.deleteTesMovimento(id: m.id); await onSaved(); dismiss() } catch {}
    }
}
