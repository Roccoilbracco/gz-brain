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

enum TesSub: String, CaseIterable, Identifiable { case riepilogo = "Riepilogo", movimenti = "Movimenti", servizi = "Servizi"; var id: String { rawValue } }

struct TesoreriaView: View {
    let prenotazioni: [Prenotazione]
    let struttura: Struttura?
    @StateObject private var model = TesoreriaModel()
    @State private var sub: TesSub = .riepilogo
    @State private var showForm = false
    @State private var editing: TesMovimento?

    private var visibiliMov: [TesMovimento] {
        guard let s = struttura else { return model.movimenti }
        return model.movimenti.filter { $0.struttura == s.rawValue || $0.struttura == nil }
    }
    private var prenFiltrate: [Prenotazione] {
        prenotazioni.filter { b in b.status != "cancellata" && (struttura == nil || b.struttura == struttura!.rawValue) }
    }

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
    private var daIncassareOTA: Int {
        var t = 0
        for b in prenFiltrate {
            let src = b.source ?? ""
            guard (src == "booking" || src == "airbnb"), BookingStatus.from(b.status).active else { continue }
            t += max(0, b.amount_cents - b.paid_cents)
        }
        return t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $sub) {
                    ForEach(TesSub.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 320).labelsHidden()
                Spacer()
                if sub == .movimenti {
                    Button { editing = nil; showForm = true } label: {
                        HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 11, weight: .bold)); Text("Nuovo movimento").font(.system(size: 12.5, weight: .semibold)) }
                            .foregroundStyle(PSE.ink).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(PSE.warn.opacity(0.95)))
                    }.buttonStyle(.plain)
                }
            }
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 30)
            } else {
                ScrollView(showsIndicators: false) {
                    switch sub {
                    case .riepilogo: riepilogo
                    case .movimenti: movimentiList
                    case .servizi: servizi
                    }
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showForm, onDismiss: { editing = nil }) {
            TesMovimentoForm(conti: model.conti, existing: editing) { await model.load() }
        }
    }

    // ── Riepilogo ──
    private var riepilogo: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(model.conti) { c in contoCard(c) }
            }
            HStack(spacing: 12) {
                totCard("TOTALE CONTI", model.totaleConti, PSE.accent)
                totCard("DA INCASSARE (OTA)", daIncassareOTA, PSE.warn)
                totCard("POTENZIALE", model.totaleConti + daIncassareOTA, Color(hue: 150/360, saturation: 0.34, brightness: 0.60))
            }
            Text("Da incassare = prenotazioni Booking/Airbnb attive non ancora saldate. Pulizia e colazioni nella scheda Servizi.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint).padding(.top, 2)
        }.padding(.bottom, 20)
    }
    private func contoCard(_ c: Conto) -> some View {
        let s = model.saldo(c.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text(c.nome.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.5).foregroundStyle(PSE.faint).lineLimit(1)
            Text(eur(s)).font(.system(size: 22, weight: .bold)).foregroundStyle(s < 0 ? Color(hue: 5/360, saturation: 0.5, brightness: 0.62) : PSE.ink).monospacedDigit()
            Text(c.tipo == "cassa" ? "Contante" : c.tipo == "ota" ? "Booking + Airbnb" : "Banca").font(.system(size: 10)).foregroundStyle(PSE.dim)
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
    private var movimentiList: some View {
        VStack(spacing: 0) {
            if visibiliMov.isEmpty {
                EmptyStateCard(icon: "tray", text: "Nessun movimento.")
            } else {
                ForEach(Array(visibiliMov.enumerated()), id: \.element.id) { i, m in
                    movRow(m)
                    if i < visibiliMov.count - 1 { Divider().overlay(PSE.line).padding(.leading, 16) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
        .padding(.bottom, 20)
    }
    private func movRow(_ m: TesMovimento) -> some View {
        let entrata = m.tipo == "entrata"
        let contoNome = model.conti.first { $0.id == m.conto_id }?.nome ?? (m.conto_id ?? "—")
        return Button { editing = m; showForm = true } label: {
            HStack(spacing: 14) {
                Text(tesPrettyStr(m.data)).font(.system(size: 11, weight: .semibold)).foregroundStyle(PSE.dim).frame(width: 56, alignment: .leading).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.descrizione ?? (m.categoria ?? "—")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PSE.ink).lineLimit(1)
                    Text([contoNome, m.categoria, m.modalita].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(PSE.faint).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text((entrata ? "+" : "−") + eur(m.importo_cents))
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(entrata ? Color(hue: 150/360, saturation: 0.4, brightness: 0.62) : Color(hue: 5/360, saturation: 0.46, brightness: 0.62))
            }
            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // ── Servizi (pulizia + colazioni) ──
    private var servizi: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                servCard("PULIZIA — FATTE", puliziaFatte, "sparkles", PSE.dim)
                servCard("PULIZIA — PREVISTE", puliziePreviste, "sparkles", PSE.warn)
            }
            HStack(spacing: 12) {
                servCard("COLAZIONI — SERVITE", colazioni.servite, "cup.and.saucer.fill", PSE.dim)
                servCard("COLAZIONI — TOTALE", colazioni.totale, "cup.and.saucer.fill", PSE.accent)
            }
            Text("Pulizia: \(CLEAN_COST/100) € per ogni check-out. Colazioni: \(String(format: "%.2f", Double(BREAKFAST_COST)/100)) € per persona/notte, solo prenotazioni Booking. Calcolate in automatico dalle prenotazioni; le «fatte/servite» fino a oggi sono già registrate in Cassa.")
                .font(.system(size: 10.5)).foregroundStyle(PSE.faint)
        }.padding(.bottom, 20)
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
    private let struttOpts = ["—", "es-vedra", "via-romagna"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "NUOVO MOVIMENTO" : "MODIFICA MOVIMENTO").font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
            Picker("Tipo", selection: $tipo) { Text("Entrata").tag("entrata"); Text("Uscita").tag("uscita") }.pickerStyle(.segmented)
            HStack {
                DatePicker("Data", selection: $data, displayedComponents: .date).labelsHidden()
                Picker("Conto", selection: $contoId) { ForEach(conti) { Text($0.nome).tag($0.id) } }
            }
            HStack {
                TextField("Importo (€)", text: $importo).textFieldStyle(.roundedBorder).frame(width: 130)
                Picker("Modalità", selection: $modalita) { ForEach(modalitaOpts, id: \.self) { Text($0.capitalized).tag($0) } }
                Picker("Struttura", selection: $struttura) { ForEach(struttOpts, id: \.self) { Text($0 == "—" ? "Entrambe" : ($0 == "es-vedra" ? "Es Vedra" : "Via Romagna")).tag($0) } }
            }
            TextField("Categoria (es. affitto, spesa, pulizia…)", text: $categoria).textFieldStyle(.roundedBorder)
            TextField("Descrizione", text: $descrizione).textFieldStyle(.roundedBorder)
            HStack {
                if existing != nil {
                    Button(role: .destructive) { Task { await del() } } label: { Text("Elimina") }
                }
                Spacer()
                Button("Annulla") { dismiss() }
                Button(saving ? "Salvo…" : "Salva") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(saving || cents == nil)
            }.padding(.top, 4)
        }
        .padding(22).frame(width: 460)
        .onAppear(perform: fill)
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
