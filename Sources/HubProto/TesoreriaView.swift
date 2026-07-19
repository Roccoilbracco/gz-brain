import SwiftUI

// ============================================================================
// Camere PSE — Tesoreria (dentro il progetto Camere PSE)
// Conti (Cassa / Massimo OTA / Beeper), Movimenti entrate·uscite, Riepilogo,
// e Servizi (Pulizia 20€/check-out, Colazioni 3,50€/pers·notte Booking) calcolati
// automaticamente dalle prenotazioni. Sorgente: public.conti + public.movimenti.
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

let CLEAN_COST = 2000      // 20,00 € per check-out
let BREAKFAST_COST = 350   // 3,50 € per persona/notte (solo Booking)

@MainActor final class TesoreriaModel: ObservableObject {
    @Published var conti: [Conto] = []
    @Published var movimenti: [TesMovimento] = []
    @Published var loading = true
    func load() async {
        loading = true
        conti = (try? await HubAPI.listConti()) ?? []
        movimenti = (try? await HubAPI.listMovimenti()) ?? []
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

enum TesSub: String, CaseIterable, Identifiable { case riepilogo = "Riepilogo", movimenti = "Movimenti"; var id: String { rawValue } }

struct TesoreriaView: View {
    let prenotazioni: [Prenotazione]
    @Binding var newTrigger: Bool
    @StateObject private var model = TesoreriaModel()
    @State private var sub: TesSub = .riepilogo
    @State private var showForm = false
    @State private var editing: TesMovimento?
    @State private var movStrut: Struttura? = nil
    @State private var mese: String = "tutto"

    private let green = Color(hue: 150/360, saturation: 0.4, brightness: 0.62)
    private let red = Color(hue: 5/360, saturation: 0.46, brightness: 0.62)

    private var visibiliMov: [TesMovimento] {
        model.movimenti.filter { m in
            (movStrut == nil || m.struttura == movStrut!.rawValue) &&
            (mese == "tutto" || String(m.data.prefix(7)) == mese)
        }
    }
    private var movEntrate: Int { var t = 0; for m in visibiliMov where m.tipo == "entrata" { t += m.importo_cents }; return t }
    private var movUscite: Int { var t = 0; for m in visibiliMov where m.tipo == "uscita" { t += m.importo_cents }; return t }
    private var mesiDisponibili: [(String, String)] {
        let keys = Set(model.movimenti.map { String($0.data.prefix(7)) })
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "MMMM yyyy"
        return keys.sorted().compactMap { k in
            guard let d = tesYmd.date(from: k + "-01") else { return nil }
            return (k, f.string(from: d).capitalized)
        }
    }
    private var meseLabel: String { mese == "tutto" ? "Tutti i mesi" : (mesiDisponibili.first { $0.0 == mese }?.1 ?? mese) }
    private func casaStats(_ s: Struttura) -> (inc: Int, spese: Int) {
        var inc = 0, spese = 0
        for m in model.movimenti where m.struttura == s.rawValue {
            if m.tipo == "entrata" { inc += m.importo_cents } else { spese += m.importo_cents }
        }
        return (inc, spese)
    }
    private var prenFiltrate: [Prenotazione] { prenotazioni.filter { $0.status != "cancellata" } }

    // ── servizi calcolati ──
    private var puliziaFatte: Int { checkouts.filter { $0 <= today }.count * CLEAN_COST }
    private var puliziePreviste: Int { checkouts.filter { $0 > today }.count * CLEAN_COST }
    private var checkouts: [Date] { prenFiltrate.compactMap { tesDate($0.checkout) } }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var colazioni: (servite: Int, totale: Int) {
        var serv = 0, tot = 0
        for b in prenFiltrate where (b.source ?? "") == "booking" {
            guard let ci = tesDate(b.checkin), let co = tesDate(b.checkout), co > ci else { continue }
            let g = max(1, b.guests ?? 1)
            let nTot = Calendar.current.dateComponents([.day], from: ci, to: co).day ?? 0
            let end = min(co, today)
            let nServ = end > ci ? (Calendar.current.dateComponents([.day], from: ci, to: end).day ?? 0) : 0
            tot += nTot * g * BREAKFAST_COST
            serv += nServ * g * BREAKFAST_COST
        }
        return (serv, tot)
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
    // da incassare del periodo/casa selezionati (checkin nel mese, filtro casa)
    private var daIncassarePeriodo: Int {
        var t = 0
        for b in prenFiltrate {
            if let s = movStrut, b.struttura != s.rawValue { continue }
            if mese != "tutto" && String((b.checkin ?? "").prefix(7)) != mese { continue }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PSESegmented(items: TesSub.allCases.map { ($0, $0.rawValue) }, selection: $sub)
                if sub == .movimenti {
                    PSESegmented(items: [(nil, "Tutte"), (.viaPo, "Via Po"), (.viaRomagna, "Via Romagna")] as [(Struttura?, String)], selection: $movStrut)
                    meseMenu
                }
                Spacer()
                if sub == .movimenti {
                    Text("\(visibiliMov.count) movimenti").font(.system(size: 11, weight: .medium)).foregroundStyle(PSE.faint)
                }
            }
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    switch sub {
                    case .riepilogo: riepilogo
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
                totCard("TOTALE CONTI (incassato)", model.totaleConti, PSE.accent)
                totCard("POTENZIALE (con da incassare)", model.totaleConti + daIncassareTot, Color(hue: 150/360, saturation: 0.34, brightness: 0.60))
            }
            Text("DA INCASSARE — prenotazioni confermate, soldi non ancora incassati").font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(PSE.warn).padding(.top, 6)
            HStack(spacing: 12) {
                totCard("BOOKING", daIncassareSource(["booking"]), PSE.warn)
                totCard("AIRBNB", daIncassareSource(["airbnb"]), PSE.warn)
                totCard("DIRETTE", daIncassareDirette, PSE.warn)
                totCard("TOTALE", daIncassareTot, green)
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
            Text("OTA (Booking/Airbnb) → conto Massimo · dirette → Beeper o Cassa (scelto per prenotazione). Pulizia 20 €/check-out. Le colazioni Booking (3,50 €/pers·notte) sono aggiunte automaticamente ai Movimenti.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)
        }.padding(.bottom, 20)
    }
    private func contoCard(_ c: Conto) -> some View {
        let s = model.saldo(c.id)
        let inc = daIncassare(c.id)
        return VStack(alignment: .leading, spacing: 7) {
            Text(c.nome.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.5).foregroundStyle(PSE.faint).lineLimit(1)
            Text(eur(s)).font(.system(size: 22, weight: .bold)).foregroundStyle(s < 0 ? Color(hue: 5/360, saturation: 0.5, brightness: 0.62) : PSE.ink).monospacedDigit()
            if inc > 0 {
                Text("+ \(eur(inc)) da incassare").font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.warn)
            } else {
                Text(c.tipo == "cassa" ? "Contante" : c.tipo == "ota" ? "Booking + Airbnb" : "Banca").font(.system(size: 10)).foregroundStyle(PSE.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func totCard(_ t: String, _ v: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundStyle(PSE.faint)
            Text(eur(v)).font(.system(size: 18, weight: .bold)).foregroundStyle(c).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(PSE.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSE.line, lineWidth: 1))
    }

    // ── Movimenti ──
    private var meseMenu: some View {
        Menu {
            Button("Tutti i mesi") { mese = "tutto" }
            ForEach(mesiDisponibili, id: \.0) { m in Button(m.1) { mese = m.0 } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 10))
                Text(meseLabel).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(PSE.dim).padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSE.line, lineWidth: 1))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
    private var movimentiList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                totCard("ENTRATE", movEntrate, green)
                totCard("USCITE", movUscite, red)
                totCard("SALDO PERIODO", movEntrate - movUscite, PSE.accent)
                totCard("DA INCASSARE", daIncassarePeriodo, PSE.warn)
            }
            VStack(spacing: 0) {
                if visibiliMov.isEmpty {
                    EmptyStateCard(icon: "tray", text: "Nessun movimento per il filtro scelto.")
                } else {
                    movHeader
                    ForEach(Array(visibiliMov.enumerated()), id: \.element.id) { i, m in
                        movRow(m)
                        if i < visibiliMov.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                    }
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
                Text((entrata ? "+" : "−") + eur(m.importo_cents))
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(entrata ? Color(hue: 150/360, saturation: 0.4, brightness: 0.62) : Color(hue: 5/360, saturation: 0.46, brightness: 0.62))
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
                Text(eur(v)).font(.system(size: 18, weight: .bold)).foregroundStyle(PSE.ink).monospacedDigit()
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
                miniStat("ENTRATE", st.inc, green)
                miniStat("SPESE", st.spese, red)
                miniStat("UTILE", utile, utile >= 0 ? green : red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
    }
    private func miniStat(_ t: String, _ v: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.6).foregroundStyle(PSE.faint)
            Text(eur(v)).font(.system(size: 15, weight: .bold)).foregroundStyle(c).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                        Button { Task { await del() } } label: {
                            Text("Elimina").font(.system(size: 13)).foregroundStyle(Color(hex: 0xffb3ad))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }.buttonStyle(.plain)
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
