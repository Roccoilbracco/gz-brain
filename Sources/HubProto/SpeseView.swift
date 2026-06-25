import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class SpeseModel: ObservableObject {
    @Published var spese: [Spesa] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true; error = nil
        do { spese = try await HubAPI.listSpese() }
        catch let e { error = e.localizedDescription }
        loading = false
    }
    var totale: Int { spese.reduce(0) { $0 + $1.importo_cents } }
}

// ─── Spese: fatture passive ricevute/pagate ───
struct SpeseView: View {
    @StateObject private var model = SpeseModel()
    @State private var search = ""
    @State private var showForm = false
    @State private var editing: Spesa?
    @State private var toDelete: Spesa?
    @State private var msg: String?

    private var filtered: [Spesa] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.spese }
        return model.spese.filter {
            ($0.fornitore ?? "").lowercased().contains(q)
            || ($0.descrizione ?? "").lowercased().contains(q)
            || ($0.categoria ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    if !model.spese.isEmpty {
                        Text("Totale: \(Money.eur(model.totale))")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Holo.subDim)
                    }
                    Spacer()
                    searchField
                    addButton
                }
                if let m = msg { Text(m).font(.system(size: 11)).foregroundStyle(Holo.subDim) }

                if let err = model.error {
                    GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).font(.system(size: 12.5)).padding(20) }
                } else if model.loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if filtered.isEmpty {
                    emptyPlaceholder
                } else {
                    table
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task { await model.load() }
        .sheet(isPresented: $showForm) {
            SpesaFormView { Task { await model.load() } }
        }
        .sheet(item: $editing) { s in
            SpesaEditView(spesa: s) { Task { await model.load() } }
        }
        .confirmationDialog(
            toDelete.map { "Eliminare la spesa di \($0.fornitore ?? "—")?" } ?? "",
            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) { if let s = toDelete { Task { await elimina(s) } } }
            Button("Annulla", role: .cancel) { toDelete = nil }
        } message: { Text("Rimuove la spesa e il file allegato.") }
    }

    private var table: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.07))
            ForEach(Array(filtered.enumerated()), id: \.element.id) { i, s in
                row(s)
                if i < filtered.count - 1 { Divider().overlay(Color.white.opacity(0.05)) }
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x10141d)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0x232b3b), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 12) {
            col("DATA", 85); col("FORNITORE", nil); col("DESCRIZIONE", 200)
            col("IMPORTO", 95); col("IVA", 80); col("CATEGORIA", 110); col("", 92)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(hex: 0x171c28))
    }
    private func col(_ t: String, _ w: CGFloat?) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(Holo.labelDim)
            .frame(width: w, alignment: .leading).frame(maxWidth: w == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ s: Spesa) -> some View {
        HStack(spacing: 12) {
            Text(dataIT(s.data)).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 85, alignment: .leading)
            Text(s.fornitore ?? "—").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Holo.text)
                .lineLimit(1).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text(s.descrizione ?? "—").font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .lineLimit(1).frame(width: 200, alignment: .leading)
            Text(Money.eur(s.importo_cents)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Holo.text)
                .frame(width: 95, alignment: .leading)
            Text(s.iva_cents == 0 ? "—" : Money.eur(s.iva_cents)).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 80, alignment: .leading)
            categoriaBadge(s.categoria).frame(width: 110, alignment: .leading)
            HStack(spacing: 4) {
                IconButton(icon: "paperclip", help: "Apri allegato") { Task { await apri(s) } }
                    .disabled(s.file_path == nil).opacity(s.file_path == nil ? 0.3 : 1)
                IconButton(icon: "pencil", help: "Modifica") { editing = s }
                IconButton(icon: "trash", help: "Elimina", danger: true) { toDelete = s }
            }.frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func categoriaBadge(_ c: String?) -> some View {
        Group {
            if let c, !c.isEmpty {
                StatusChip(text: c, hue: 38)
            } else { Text("—").font(.system(size: 11)).foregroundStyle(Holo.labelDim) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
            TextField("Cerca spesa…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Holo.text).frame(width: 160)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.25), lineWidth: 1))
    }
    private var addButton: some View {
        MenuPillButton(label: "Carica spesa", icon: "tray.and.arrow.down.fill") { showForm = true }
    }

    private var emptyPlaceholder: some View {
        GlassCard {
            VStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 38)).foregroundStyle(Holo.hsl(217, 75, 65).opacity(0.85))
                    .shadow(color: Holo.hsl(217, 85, 60).opacity(0.5), radius: 10)
                Text(search.isEmpty ? "Nessuna spesa" : "Nessun risultato")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Holo.titleText)
                Text(search.isEmpty ? "Carica le fatture che ricevi e paghi: allega il PDF/immagine e i dati, pronte per il commercialista."
                                    : "Nessuna spesa corrisponde alla ricerca.")
                    .font(.system(size: 12.5)).foregroundStyle(Holo.subDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                if search.isEmpty {
                    MenuPillButton(label: "Carica spesa", icon: "tray.and.arrow.down.fill") { showForm = true }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 340).padding(40)
        }
    }

    // ── azioni ──
    private func apri(_ s: Spesa) async {
        guard let path = s.file_path, let data = try? await HubAPI.downloadSpesaFile(path: path) else {
            msg = "Allegato non disponibile."; return
        }
        let ext = (path as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent((s.fornitore ?? "spesa").replacingOccurrences(of: "/", with: "-"))
            .appendingPathExtension(ext.isEmpty ? "pdf" : ext)
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }
    private func elimina(_ s: Spesa) async {
        toDelete = nil
        do { try await HubAPI.deleteSpesa(id: s.id, filePath: s.file_path); await model.load() }
        catch let e { msg = "Errore: \(e.localizedDescription)" }
    }
}

// cents → "1234,56" per i campi input
func centsToInput(_ c: Int) -> String {
    guard c != 0 else { return "" }
    return "\(c/100)," + String(format: "%02d", abs(c) % 100)
}
func parseYMD(_ s: String?) -> Date {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    return f.date(from: String((s ?? "").prefix(10))) ?? Date()
}

// ─── Form: modifica spesa (importo, dati) ───
struct SpesaEditView: View {
    let spesa: Spesa
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var fornitore: String
    @State private var data: Date
    @State private var importo: String
    @State private var iva: String
    @State private var categoria: String
    @State private var descrizione: String
    @State private var saving = false
    @State private var err: String?

    private let categorie = ["Software", "Consulenza", "Hosting/Cloud", "Marketing", "Hardware", "Servizi", "Tasse/Bolli", "Altro"]

    init(spesa: Spesa, onSaved: @escaping () -> Void) {
        self.spesa = spesa; self.onSaved = onSaved
        _fornitore = State(initialValue: spesa.fornitore ?? "")
        _data = State(initialValue: parseYMD(spesa.data))
        _importo = State(initialValue: centsToInput(spesa.importo_cents))
        _iva = State(initialValue: centsToInput(spesa.iva_cents))
        _categoria = State(initialValue: spesa.categoria ?? "")
        _descrizione = State(initialValue: spesa.descrizione ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MODIFICA SPESA").font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                HoloField(label: "Fornitore *", text: $fornitore)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DATA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        DatePicker("", selection: $data, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                    }
                    HoloField(label: "Importo (€) *", text: $importo, placeholder: "0,00")
                    HoloField(label: "IVA (€)", text: $iva, placeholder: "0,00").frame(width: 130)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("CATEGORIA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                    Menu {
                        ForEach(categorie, id: \.self) { c in Button(c) { categoria = c } }
                    } label: {
                        HStack {
                            Text(categoria.isEmpty ? "Seleziona…" : categoria)
                                .font(.system(size: 13)).foregroundStyle(categoria.isEmpty ? Holo.labelDim : Color(hex: 0xe8f2ff))
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Holo.labelDim)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                    }.menuStyle(.borderlessButton)
                }
                HoloField(label: "Descrizione", text: $descrizione)

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
                    }.buttonStyle(.plain).disabled(saving || fornitore.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 420)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func save() {
        saving = true; err = nil
        Task {
            do {
                try await HubAPI.updateSpesa(id: spesa.id, fields: [
                    "data": eaDate(data, "yyyy-MM-dd"),
                    "fornitore": fornitore.trimmingCharacters(in: .whitespaces),
                    "descrizione": descrizione.isEmpty ? nil : descrizione,
                    "importo_cents": Money.parse(importo) ?? 0,
                    "iva_cents": Money.parse(iva) ?? 0,
                    "categoria": categoria.isEmpty ? nil : categoria,
                ])
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch { await MainActor.run { saving = false; err = error.localizedDescription } }
        }
    }
}

// ─── Form: carica una spesa (file + dati) ───
struct SpesaFormView: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var fornitore = ""
    @State private var data = Date()
    @State private var importo = ""
    @State private var iva = ""
    @State private var categoria = ""
    @State private var descrizione = ""
    @State private var fileURL: URL?
    @State private var fileName = ""
    @State private var saving = false
    @State private var err: String?

    private let categorie = ["Software", "Consulenza", "Hosting/Cloud", "Marketing", "Hardware", "Servizi", "Tasse/Bolli", "Altro"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CARICA SPESA").font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)

                filePicker
                HoloField(label: "Fornitore *", text: $fornitore, placeholder: "Es. Anthropic, Apple, Hetzner…")
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DATA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        DatePicker("", selection: $data, displayedComponents: .date).labelsHidden()
                            .datePickerStyle(.field)
                    }
                    HoloField(label: "Importo (€) *", text: $importo, placeholder: "0,00")
                    HoloField(label: "IVA (€)", text: $iva, placeholder: "0,00").frame(width: 130)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("CATEGORIA").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                    Menu {
                        ForEach(categorie, id: \.self) { c in Button(c) { categoria = c } }
                    } label: {
                        HStack {
                            Text(categoria.isEmpty ? "Seleziona…" : categoria)
                                .font(.system(size: 13)).foregroundStyle(categoria.isEmpty ? Holo.labelDim : Color(hex: 0xe8f2ff))
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Holo.labelDim)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                    }.menuStyle(.borderlessButton)
                }
                HoloField(label: "Descrizione", text: $descrizione, placeholder: "Es. Abbonamento Claude Max")

                if let err { Text(err).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad)) }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain).font(.system(size: 13))
                        .foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { save() } label: {
                        Text(saving ? "Carico…" : "Salva spesa")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain).disabled(saving || !canSave).opacity(canSave ? 1 : 0.5)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 560)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private var canSave: Bool {
        !fornitore.trimmingCharacters(in: .whitespaces).isEmpty && (Money.parse(importo) ?? 0) > 0
    }

    private var filePicker: some View {
        Button { pick() } label: {
            HStack(spacing: 10) {
                Image(systemName: fileURL == nil ? "doc.badge.plus" : "doc.fill")
                    .font(.system(size: 16)).foregroundStyle(Holo.hsl(217, 80, 72))
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileURL == nil ? "Scegli file (PDF o immagine)" : fileName)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Holo.text).lineLimit(1)
                    Text(fileURL == nil ? "fattura ricevuta da allegare" : "tocca per cambiare")
                        .font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                Holo.hsl(217, 80, 60).opacity(fileURL == nil ? 0.35 : 0.6),
                style: StrokeStyle(lineWidth: 1, dash: fileURL == nil ? [5, 4] : [])))
        }.buttonStyle(.plain)
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .png, .jpeg, .image]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url {
            fileURL = url; fileName = url.lastPathComponent
        }
    }

    private func save() {
        guard canSave else { return }
        saving = true; err = nil
        let impC = Money.parse(importo) ?? 0
        let ivaC = Money.parse(iva) ?? 0
        Task {
            do {
                var path: String? = nil
                if let url = fileURL {
                    let bytes = try Data(contentsOf: url)
                    let ext = url.pathExtension.isEmpty ? "pdf" : url.pathExtension
                    let ct = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                    let safe = url.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
                    let name = "\(UUID().uuidString.prefix(8))-\(safe).\(ext)"
                    path = try await HubAPI.uploadSpesaFile(bytes, name: name, contentType: ct)
                }
                try await HubAPI.createSpesa([
                    "data": eaDate(data, "yyyy-MM-dd"),
                    "fornitore": fornitore.trimmingCharacters(in: .whitespaces),
                    "descrizione": descrizione.isEmpty ? nil : descrizione,
                    "importo_cents": impC, "iva_cents": ivaC,
                    "categoria": categoria.isEmpty ? nil : categoria,
                    "file_path": path,
                ])
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; err = error.localizedDescription }
            }
        }
    }
}
