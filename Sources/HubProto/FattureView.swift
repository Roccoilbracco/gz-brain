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
                Text("FATTURE").font(.system(size: 13, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.hsl(152, 80, 74))
                Text("\(model.fatture.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Holo.subDim)
                Spacer()
                Button { showEditor = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Nuova fattura").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0xeaf0fb))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 40/255, green: 70/255, blue: 140/255).opacity(0.5)))
                    .overlay(Capsule().strokeBorder(Holo.hsl(217, 85, 62).opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain).disabled(model.azienda?.ragione_sociale == nil)
            }
            if let m = msg { Text(m).font(.system(size: 11)).foregroundStyle(Holo.subDim) }

            if model.loading {
                Text("Caricamento…").font(.system(size: 12)).foregroundStyle(Holo.subDim).padding(.vertical, 6)
            } else if model.fatture.isEmpty {
                Text("Nessuna fattura per questo cliente. Creane una con “+ Nuova fattura”.")
                    .font(.system(size: 12)).foregroundStyle(Holo.labelDim).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.fatture.enumerated()), id: \.element.id) { i, f in
                        row(f)
                        if i < model.fatture.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                    }
                }
                .padding(.vertical, 2)
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
            FatturaEditView(fattura: f, clienteNome: model.clienteNome(f.cliente_id)) { Task { await model.load() } }
        }
        .confirmationDialog(
            toDelete.map { "Eliminare la fattura \($0.anno)\(String(format: "%03d", $0.numero))?" } ?? "",
            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) { if let f = toDelete { Task { await elimina(f) } } }
            Button("Annulla", role: .cancel) { toDelete = nil }
        }
    }

    private func row(_ f: Fattura) -> some View {
        HStack(spacing: 12) {
            Text("\(f.anno)\(String(format: "%03d", f.numero))").font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Holo.text).frame(width: 96, alignment: .leading)
            Text(dataIT(f.data)).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 90, alignment: .leading)
            Text(Money.eur(f.totale_cents)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Holo.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            statoBadge(f.stato).frame(width: 84, alignment: .leading)
            HStack(spacing: 10) {
                Button { Task { await apri(f) } } label: { Image(systemName: "doc.richtext").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(217, 80, 70)).help("Apri PDF")
                Button { Task { await invia(f) } } label: { Image(systemName: "paperplane").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(152, 80, 70)).help("Invia per email")
                Button { editing = f } label: { Image(systemName: "pencil").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(48, 85, 68)).help("Modifica")
                Button { toDelete = f } label: { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(2, 80, 68)).help("Elimina")
            }.frame(width: 124, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    private func statoBadge(_ s: String) -> some View {
        let hue: Double = s == "pagata" ? 152 : s == "inviata" ? 217 : s == "emessa" ? 38 : 0
        return Text(s.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
            .foregroundStyle(Holo.hsl(hue, 85, 75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Holo.hsl(hue, 80, 60).opacity(0.5), lineWidth: 1))
    }
    private func tempPDF(_ f: Fattura) async -> URL? {
        guard let path = f.pdf_path, let data = try? await HubAPI.downloadFatturaPDF(path: path) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(f.anno)\(String(format: "%03d", f.numero)).pdf")
        try? data.write(to: url); return url
    }
    private func apri(_ f: Fattura) async {
        guard let url = await tempPDF(f) else { msg = "PDF non disponibile."; return }
        NSWorkspace.shared.open(url)
    }
    private func invia(_ f: Fattura) async {
        guard let url = await tempPDF(f) else { msg = "PDF non disponibile."; return }
        let num = "\(f.anno)\(String(format: "%03d", f.numero))"
        let subj = "Invoice \(num) — \(model.azienda?.ragione_sociale ?? "")"
        _ = InvoiceMailer.compose(to: model.cliente(f.cliente_id)?.email, subject: subj,
                                  body: "In allegato la fattura \(num).", attachment: url)
    }
    private func elimina(_ f: Fattura) async {
        toDelete = nil
        do { try await HubAPI.deleteFattura(id: f.id, pdfPath: f.pdf_path); await model.load() }
        catch let e { msg = "Errore: \(e.localizedDescription)" }
    }
}

// ─── Lista fatture (host nella sezione Clienti o nella scheda cliente) ───
struct FattureView: View {
    let clienteId: String?
    @StateObject private var model: FattureModel
    @State private var search = ""
    @State private var showEditor = false
    @State private var msg: String?
    @State private var toDelete: Fattura?
    @State private var editing: Fattura?
    @State private var deleting = false

    init(clienteId: String? = nil) {
        self.clienteId = clienteId
        _model = StateObject(wrappedValue: FattureModel(clienteFilter: clienteId))
    }

    private var filtered: [Fattura] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.fatture }
        return model.fatture.filter {
            "\($0.anno)\($0.numero)".contains(q) || model.clienteNome($0.cliente_id).lowercased().contains(q)
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
            FatturaEditorView(model: model, clienteId: clienteId) { Task { await model.load() } }
        }
        .sheet(item: $editing) { f in
            FatturaEditView(fattura: f, clienteNome: model.clienteNome(f.cliente_id)) { Task { await model.load() } }
        }
        .confirmationDialog(
            toDelete.map { "Eliminare la fattura \($0.anno)\(String(format: "%03d", $0.numero))?" } ?? "",
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
            TextField("Cerca fattura…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Holo.text).frame(width: 170)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
        .overlay(Capsule().strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.25), lineWidth: 1))
    }
    private var addButton: some View {
        Button { showEditor = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Nuova fattura").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color(hex: 0xeaf0fb))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color(red: 40/255, green: 70/255, blue: 140/255).opacity(0.55)))
            .overlay(Capsule().strokeBorder(Holo.hsl(217, 85, 62).opacity(0.6), lineWidth: 1))
        }.buttonStyle(.plain).disabled(model.azienda?.ragione_sociale == nil)
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
                    Button { showEditor = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            Text("Nuova fattura").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(LinearGradient(
                            colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                            startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain).disabled(model.azienda?.ragione_sociale == nil)
                    .opacity(model.azienda?.ragione_sociale == nil ? 0.5 : 1).padding(.top, 4)
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
            Text("\(f.anno)\(String(format: "%03d", f.numero))").font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Holo.text).frame(width: 110, alignment: .leading)
            Text(dataIT(f.data)).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 90, alignment: .leading)
            Text(model.clienteNome(f.cliente_id)).font(.system(size: 12)).foregroundStyle(Holo.text)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(Money.eur(f.totale_cents)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Holo.subDim)
                .frame(width: 100, alignment: .leading)
            statoBadge(f.stato).frame(width: 90, alignment: .leading)
            HStack(spacing: 10) {
                Button { Task { await apri(f) } } label: { Image(systemName: "doc.richtext").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(217, 80, 70)).help("Apri PDF")
                Button { Task { await invia(f) } } label: { Image(systemName: "paperplane").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(152, 80, 70)).help("Invia per email")
                Button { editing = f } label: { Image(systemName: "pencil").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(48, 85, 68)).help("Modifica")
                Button { toDelete = f } label: { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.hsl(2, 80, 68)).help("Elimina fattura")
                    .disabled(deleting)
            }.frame(width: 146, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func statoBadge(_ s: String) -> some View {
        let hue: Double = s == "pagata" ? 152 : s == "inviata" ? 217 : s == "emessa" ? 38 : 0
        return Text(s.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
            .foregroundStyle(Holo.hsl(hue, 85, 75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Holo.hsl(hue, 80, 60).opacity(0.5), lineWidth: 1))
    }

    private func tempPDF(_ f: Fattura) async -> URL? {
        guard let path = f.pdf_path, let data = try? await HubAPI.downloadFatturaPDF(path: path) else { return nil }
        let ext = (path as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(f.anno)\(String(format: "%03d", f.numero))")
            .appendingPathExtension(ext.isEmpty ? "pdf" : ext)
        try? data.write(to: url)
        return url
    }
    private func apri(_ f: Fattura) async {
        guard let url = await tempPDF(f) else { msg = "PDF non disponibile per questa fattura."; return }
        NSWorkspace.shared.open(url)
    }
    private func elimina(_ f: Fattura) async {
        deleting = true; defer { deleting = false }
        toDelete = nil
        do {
            try await HubAPI.deleteFattura(id: f.id, pdfPath: f.pdf_path)
            await model.load()
            msg = "Fattura \(f.anno)\(String(format: "%03d", f.numero)) eliminata."
        } catch let e { msg = "Errore eliminazione: \(e.localizedDescription)" }
    }
    private func invia(_ f: Fattura) async {
        guard let url = await tempPDF(f) else { msg = "PDF non disponibile."; return }
        let to = model.cliente(f.cliente_id)?.email
        let num = "\(f.anno)\(String(format: "%03d", f.numero))"
        let subj = "Invoice \(num) — \(model.azienda?.ragione_sociale ?? "")"
        _ = InvoiceMailer.compose(to: to, subject: subj, body: "In allegato la fattura \(num).", attachment: url)
    }
}

// ─── Form: modifica fattura (numero, data, stato, importi) ───
struct FatturaEditView: View {
    let fattura: Fattura
    let clienteNome: String
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

    init(fattura: Fattura, clienteNome: String, onSaved: @escaping () -> Void) {
        self.fattura = fattura; self.clienteNome = clienteNome; self.onSaved = onSaved
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
                            .background(Capsule().fill(LinearGradient(
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
        Task {
            do {
                try await HubAPI.updateFattura(id: fattura.id, fields: [
                    "numero": Int(numeroText) ?? fattura.numero,
                    "data": eaDate(data, "yyyy-MM-dd"), "stato": stato,
                    "imponibile_cents": imp, "iva_cents": ivaC, "totale_cents": imp + ivaC,
                ])
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch { await MainActor.run { saving = false; err = error.localizedDescription } }
        }
    }
}
