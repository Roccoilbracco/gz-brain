import SwiftUI
import AppKit

@MainActor
final class FattureModel: ObservableObject {
    @Published var fatture: [Fattura] = []
    @Published var clienti: [Cliente] = []
    @Published var azienda: AziendaSettings?
    @Published var logo: NSImage?
    @Published var loading = true
    @Published var error: String?
    let clienteFilter: String?

    init(clienteFilter: String? = nil) { self.clienteFilter = clienteFilter }

    func load() async {
        loading = true; error = nil
        do {
            async let f = HubAPI.listFatture(clienteId: clienteFilter)
            async let c = HubAPI.listClienti()
            async let a = HubAPI.getAzienda()
            fatture = try await f; clienti = try await c; azienda = try await a
            if let lp = azienda?.logo_path, logo == nil, let d = try? await HubAPI.downloadAzienda(lp) {
                logo = NSImage(data: d)
            }
        } catch let e { error = e.localizedDescription }
        loading = false
    }
    func cliente(_ id: String) -> Cliente? { clienti.first { $0.id == id } }
    func clienteNome(_ id: String) -> String { cliente(id)?.ragione_sociale ?? "—" }
}

func eaDate(_ d: Date, _ fmt: String) -> String {
    let f = DateFormatter(); f.dateFormat = fmt; f.locale = Locale(identifier: "it_IT"); return f.string(from: d)
}

/// "2026-06-22" → "22/06/2026"
func dataIT(_ s: String?) -> String {
    let raw = String((s ?? "").prefix(10))
    let p = raw.split(separator: "-")
    guard p.count == 3 else { return raw }
    return "\(p[2])/\(p[1])/\(p[0])"
}

// ─── Azioni condivise sulle fatture (lista globale + sezione cliente) ───

func fatturaStatoHue(_ s: String) -> Double {
    s == "pagata" ? 152 : s == "inviata" ? 217 : s == "emessa" ? 38 : 0
}

/// "indirizzo completo - VAT Number: ..." per l'intestazione fattura
func fatturaClienteRiga(_ c: Cliente) -> String {
    var parts: [String] = []
    let ind = clienteIndirizzoCompleto(c)
    if !ind.isEmpty { parts.append(ind) }
    if let p = c.piva, !p.isEmpty { parts.append("VAT Number: \(p)") }
    return parts.joined(separator: " - ")
}

func fatturaTempPDF(_ f: Fattura) async -> URL? {
    guard let path = f.pdf_path, let data = try? await HubAPI.downloadFatturaPDF(path: path) else { return nil }
    let ext = (path as NSString).pathExtension
    let url = appTempDir()
        .appendingPathComponent(f.numeroCompleto)
        .appendingPathExtension(ext.isEmpty ? "pdf" : ext)
    try? data.write(to: url)
    return url
}

/// Apre il PDF; ritorna un messaggio di errore se non disponibile.
@MainActor func fatturaApri(_ f: Fattura) async -> String? {
    guard let url = await fatturaTempPDF(f) else { return "PDF non disponibile per questa fattura." }
    NSWorkspace.shared.open(url)
    return nil
}

/// Compone la mail con PDF allegato; ritorna un messaggio di errore se non disponibile.
@MainActor func fatturaInvia(_ f: Fattura, model: FattureModel) async -> String? {
    guard let url = await fatturaTempPDF(f) else { return "PDF non disponibile." }
    let subj = "Invoice \(f.numeroCompleto) — \(model.azienda?.ragione_sociale ?? "")"
    _ = InvoiceMailer.compose(to: model.cliente(f.cliente_id)?.email, subject: subj,
                              body: "In allegato la fattura \(f.numeroCompleto).", attachment: url)
    return nil
}

// ─── Sezione fatture del singolo cliente (embeddata nella scheda cliente) ───
struct ClienteFattureSection: View {
    let clienteId: String
    @StateObject private var model: FattureModel
    @State private var showEditor = false
    @State private var toDelete: Fattura?
    @State private var editing: Fattura?
    @State private var msg: String?

    init(clienteId: String) {
        self.clienteId = clienteId
        _model = StateObject(wrappedValue: FattureModel(clienteFilter: clienteId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                MenuPillButton(label: "Nuova fattura", icon: "plus",
                               disabled: model.azienda?.ragione_sociale == nil) { showEditor = true }
            }
            if let m = msg { Text(m).font(.system(size: 11)).foregroundStyle(Holo.subDim) }

            if model.loading {
                Text("Caricamento…").font(.system(size: 12)).foregroundStyle(Holo.subDim).padding(.vertical, 6)
            } else if model.fatture.isEmpty {
                EmptyStateCard(icon: "doc.text", text: "Nessuna fattura per questo cliente.\nCreane una con “+ Nuova fattura”.")
            } else {
                VStack(spacing: 0) {
                    gridHeader
                    Divider().overlay(Color.white.opacity(0.08))
                    ForEach(Array(model.fatture.enumerated()), id: \.element.id) { i, f in
                        row(f)
                        if i < model.fatture.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showEditor) {
            FatturaEditorView(model: model, clienteId: clienteId) { Task { await model.load() } }
        }
        .sheet(item: $editing) { f in
            FatturaEditView(fattura: f, model: model) { Task { await model.load() } }
        }
        .confirmationDialog(
            toDelete.map { "Eliminare la fattura \($0.numeroCompleto)?" } ?? "",
            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) { if let f = toDelete { Task { await elimina(f) } } }
            Button("Annulla", role: .cancel) { toDelete = nil }
        }
    }

    private var gridHeader: some View {
        HStack(spacing: 18) {
            gcol("NUMERO", .leading)
            gcol("DATA", .leading)
            gcol("IMPONIBILE", .trailing)
            gcol("IVA", .trailing)
            gcol("TOTALE", .trailing)
            Text("STATO").frame(width: 96, alignment: .center)
            Color.clear.frame(width: 124, height: 1)
        }
        .font(.system(size: 9, weight: .heavy)).tracking(1)
        .foregroundStyle(Csb.secFg)
        .padding(.horizontal, 18).padding(.vertical, 10)
    }
    private func gcol(_ t: String, _ a: Alignment) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(1)
            .foregroundStyle(Csb.secFg).frame(maxWidth: .infinity, alignment: a)
    }

    private func row(_ f: Fattura) -> some View {
        HStack(spacing: 18) {
            Text(f.numeroCompleto).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Holo.text).frame(maxWidth: .infinity, alignment: .leading)
            Text(dataIT(f.data)).font(.system(size: 12)).foregroundStyle(Holo.subDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Money.eur(f.imponibile_cents)).font(.system(size: 12)).foregroundStyle(Holo.subDim)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(Money.eur(f.iva_cents)).font(.system(size: 12)).foregroundStyle(Holo.subDim)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(Money.eur(f.totale_cents)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.text)
                .frame(maxWidth: .infinity, alignment: .trailing)
            StatusChip(text: f.stato, hue: fatturaStatoHue(f.stato)).frame(width: 96, alignment: .center)
            HStack(spacing: 4) {
                IconButton(icon: "arrow.up.right.square", help: "Apri PDF") { Task { if let e = await fatturaApri(f) { msg = e } } }
                IconButton(icon: "paperplane", help: "Invia per email") { Task { if let e = await fatturaInvia(f, model: model) { msg = e } } }
                IconButton(icon: "pencil", help: "Modifica") { editing = f }
                IconButton(icon: "trash", help: "Elimina", danger: true) { toDelete = f }
            }.frame(width: 124, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }
    private func elimina(_ f: Fattura) async {
        toDelete = nil
        do { try await HubAPI.deleteFattura(id: f.id, pdfPath: f.pdf_path); await model.load() }
        catch let e { msg = "Errore: \(e.localizedDescription)" }
    }
}

// ─── Lista fatture globale (sezione Clienti; la variante per-cliente è ClienteFattureSection) ───
struct FattureView: View {
    @StateObject private var model = FattureModel()
    @State private var search = ""
    @State private var showEditor = false
    @State private var msg: String?
    @State private var toDelete: Fattura?
    @State private var editing: Fattura?
    @State private var deleting = false

    private var filtered: [Fattura] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.fatture }
        return model.fatture.filter {
            $0.numeroCompleto.contains(q) || String($0.numero).contains(q)
                || model.clienteNome($0.cliente_id).lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Spacer()
                    searchField
                    addButton
                }
                if model.azienda?.ragione_sociale == nil && !model.loading {
                    Text("Compila i Dati aziendali in Impostazioni per emettere fatture.")
                        .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xffd9a0))
                }
                if let m = msg { Text(m).font(.system(size: 11)).foregroundStyle(Holo.subDim) }

                if let err = model.error {
                    GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).font(.system(size: 12.5)).padding(20) }
                } else if model.loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if filtered.isEmpty {
                    emptyPlaceholder
                } else {
                    VStack(spacing: 0) {
                        header
                        Divider().overlay(Color.white.opacity(0.07))
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, f in
                            row(f)
                            if i < filtered.count - 1 { Divider().overlay(Color.white.opacity(0.05)) }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x10141d)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0x232b3b), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task { await model.load() }
        .sheet(isPresented: $showEditor) {
            FatturaEditorView(model: model, clienteId: nil) { Task { await model.load() } }
        }
        .sheet(item: $editing) { f in
            FatturaEditView(fattura: f, model: model) { Task { await model.load() } }
        }
        .confirmationDialog(
            toDelete.map { "Eliminare la fattura \($0.numeroCompleto)?" } ?? "",
            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) { if let f = toDelete { Task { await elimina(f) } } }
            Button("Annulla", role: .cancel) { toDelete = nil }
        } message: {
            Text("L'operazione è definitiva: rimuove la fattura, le sue righe e il PDF.")
        }
    }

    private var searchField: some View {
        HoloSearchField(placeholder: "Cerca fattura…", text: $search)
    }
    private var addButton: some View {
        MenuPillButton(label: "Nuova fattura", icon: "plus",
                       disabled: model.azienda?.ragione_sociale == nil) { showEditor = true }
    }

    private var emptyPlaceholder: some View {
        GlassCard {
            VStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Holo.hsl(217, 75, 65).opacity(0.85))
                    .shadow(color: Holo.hsl(217, 85, 60).opacity(0.5), radius: 10)
                Text(search.isEmpty ? "Nessuna fattura" : "Nessun risultato")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Holo.titleText)
                Text(search.isEmpty ? "Emetti la tua prima fattura: scegli cliente e righe, il PDF è pronto da inviare."
                                    : "Nessuna fattura corrisponde alla ricerca.")
                    .font(.system(size: 12.5)).foregroundStyle(Holo.subDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                if search.isEmpty {
                    MenuPillButton(label: "Nuova fattura", icon: "plus",
                                   disabled: model.azienda?.ragione_sociale == nil) { showEditor = true }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 340)
            .padding(40)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            col("NUMERO", 110); col("DATA", 90)
            col("CLIENTE", nil)
            col("IMPORTO", 100); col("STATO", 90); col("", 146)
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
    private func col(_ t: String, _ w: CGFloat?) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(Holo.labelDim)
            .frame(width: w, alignment: .leading).frame(maxWidth: w == nil ? .infinity : nil, alignment: .leading)
    }
    private func row(_ f: Fattura) -> some View {
        HStack(spacing: 12) {
            Text(f.numeroCompleto).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Holo.text).frame(width: 110, alignment: .leading)
            Text(dataIT(f.data)).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 90, alignment: .leading)
            Text(model.clienteNome(f.cliente_id)).font(.system(size: 12)).foregroundStyle(Holo.text)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(Money.eur(f.totale_cents)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Holo.subDim)
                .frame(width: 100, alignment: .leading)
            StatusChip(text: f.stato, hue: fatturaStatoHue(f.stato)).frame(width: 90, alignment: .leading)
            HStack(spacing: 4) {
                IconButton(icon: "doc.richtext", help: "Apri PDF") { Task { if let e = await fatturaApri(f) { msg = e } } }
                IconButton(icon: "paperplane", help: "Invia per email") { Task { if let e = await fatturaInvia(f, model: model) { msg = e } } }
                IconButton(icon: "pencil", help: "Modifica") { editing = f }
                IconButton(icon: "trash", help: "Elimina fattura", danger: true) { toDelete = f }
                    .disabled(deleting)
            }.frame(width: 146, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func elimina(_ f: Fattura) async {
        deleting = true; defer { deleting = false }
        toDelete = nil
        do {
            try await HubAPI.deleteFattura(id: f.id, pdfPath: f.pdf_path)
            await model.load()
            msg = "Fattura \(f.numeroCompleto) eliminata."
        } catch let e { msg = "Errore eliminazione: \(e.localizedDescription)" }
    }
}

// ─── Form: modifica fattura (numero, data, stato, importi) ───
struct FatturaEditView: View {
    let fattura: Fattura
    @ObservedObject var model: FattureModel
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var numeroText: String
    @State private var data: Date
    @State private var stato: String
    @State private var imponibile: String
    @State private var iva: String
    @State private var saving = false
    @State private var err: String?

    private let stati = ["emessa", "inviata", "pagata", "annullata"]
    private var clienteNome: String { model.clienteNome(fattura.cliente_id) }

    init(fattura: Fattura, model: FattureModel, onSaved: @escaping () -> Void) {
        self.fattura = fattura; self.model = model; self.onSaved = onSaved
        _numeroText = State(initialValue: String(fattura.numero))
        _data = State(initialValue: parseYMD(fattura.data))
        _stato = State(initialValue: fattura.stato)
        _imponibile = State(initialValue: centsToInput(fattura.imponibile_cents))
        _iva = State(initialValue: centsToInput(fattura.iva_cents))
    }

    private var totaleC: Int { (Money.parse(imponibile) ?? 0) + (Money.parse(iva) ?? 0) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MODIFICA FATTURA").font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                Text("Cliente: \(clienteNome)").font(.system(size: 12)).foregroundStyle(Holo.subDim)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("NUMERO").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        HStack(spacing: 4) {
                            Text("\(fattura.anno) /").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                            TextField("", text: $numeroText).textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xe8f2ff))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DATA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        DatePicker("", selection: $data, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("STATO").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        Menu {
                            ForEach(stati, id: \.self) { s in Button(s.capitalized) { stato = s } }
                        } label: {
                            HStack { Text(stato.capitalized).font(.system(size: 13)).foregroundStyle(Color(hex: 0xe8f2ff)); Spacer()
                                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Holo.labelDim) }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                        }.menuStyle(.borderlessButton)
                    }
                }
                HStack(spacing: 12) {
                    HoloField(label: "Imponibile (€)", text: $imponibile, placeholder: "0,00")
                    HoloField(label: "IVA (€)", text: $iva, placeholder: "0,00")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TOTALE").font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Holo.labelDim)
                        Text(Money.eur(totaleC)).font(.system(size: 15, weight: .heavy)).foregroundStyle(Holo.titleText)
                            .padding(.vertical, 9)
                    }
                }

                if let err { Text(err).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad)) }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain).font(.system(size: 13))
                        .foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { save() } label: {
                        Text(saving ? "Salvo…" : "Salva")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain).disabled(saving)
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 360)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func save() {
        saving = true; err = nil
        let imp = Money.parse(imponibile) ?? 0, ivaC = Money.parse(iva) ?? 0
        let numero = Int(numeroText) ?? fattura.numero
        Task {
            do {
                if numero != fattura.numero, try await HubAPI.fatturaExists(anno: fattura.anno, numero: numero) {
                    await MainActor.run { saving = false; err = "Esiste già la fattura \(fattura.anno)\(String(format: "%03d", numero)): cambia numero." }
                    return
                }
                try await HubAPI.updateFattura(id: fattura.id, fields: [
                    "numero": numero,
                    "data": eaDate(data, "yyyy-MM-dd"), "stato": stato,
                    "imponibile_cents": imp, "iva_cents": ivaC, "totale_cents": imp + ivaC,
                ])
                // rigenera il PDF: senza, il documento in storage resterebbe quello vecchio
                let pdfOK = await regenPDF(numero: numero, imp: imp, ivaC: ivaC)
                await MainActor.run {
                    saving = false; onSaved()
                    if pdfOK { dismiss() } else { err = "Dati salvati, ma il PDF non è stato rigenerato." }
                }
            } catch { await MainActor.run { saving = false; err = error.localizedDescription } }
        }
    }

    /// Ricostruisce il PDF dai dati aggiornati (righe dal DB) e lo ricarica in storage.
    private func regenPDF(numero: Int, imp: Int, ivaC: Int) async -> Bool {
        guard let azienda = model.azienda else { return false }
        do {
            let righe = try await HubAPI.getFatturaRighe(fattura.id)
            let invRighe = righe.map { r in
                InvoiceData.Riga(desc: r.descrizione,
                                 qta: r.qta == r.qta.rounded() ? String(Int(r.qta)) : String(r.qta),
                                 prezzoC: r.prezzo_unitario_cents, totaleC: r.totale_cents)
            }
            let cliente = model.cliente(fattura.cliente_id)
            let vat = fattura.vat_mode.flatMap { VatMode(rawValue: $0) }
            let inv = InvoiceData(
                azienda: azienda, clienteNome: cliente?.ragione_sociale ?? clienteNome,
                clienteRiga: cliente.map(fatturaClienteRiga) ?? "",
                numero: "\(fattura.anno)\(String(format: "%03d", numero))", data: eaDate(data, "dd/MM/yyyy"),
                righe: invRighe, imponibileC: imp, ivaC: ivaC, totaleC: imp + ivaC,
                vatNote: vat?.note ?? "", logo: model.logo)
            guard let pdf = InvoicePDF.render(inv) else { return false }
            let path = try await HubAPI.uploadFatturaPDF(pdf, anno: fattura.anno, numero: numero)
            try await HubAPI.setFatturaPdfPath(id: fattura.id, path: path)
            if let old = fattura.pdf_path, old != path { try? await HubAPI.deleteFatturaPDFFile(path: old) }
            return true
        } catch { return false }
    }
}
