import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let mesiNomi = ["", "Gennaio","Febbraio","Marzo","Aprile","Maggio","Giugno",
                       "Luglio","Agosto","Settembre","Ottobre","Novembre","Dicembre"]

@MainActor
final class BancaModel: ObservableObject {
    @Published var estratti: [Estratto] = []
    @Published var fatture: [Fattura] = []
    @Published var spese: [Spesa] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true; error = nil
        do {
            async let e = HubAPI.listEstratti()
            async let f = HubAPI.listFatture()
            async let s = HubAPI.listSpese()
            (estratti, fatture, spese) = try await (e, f, s)
        } catch let er { error = er.localizedDescription }
        loading = false
    }
}

// ─── Banca: estratti conto per mese + riconciliazione ───
struct BancaView: View {
    @StateObject private var model = BancaModel()
    @State private var showForm = false
    @State private var riconcilia: Estratto?
    @State private var toDelete: Estratto?
    @State private var msg: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Carica gli estratti conto mese per mese: l'app li confronta con fatture e spese e segnala cosa manca.")
                        .font(.system(size: 12)).foregroundStyle(Holo.subDim).frame(maxWidth: 460, alignment: .leading)
                    Spacer()
                    addButton
                }
                if let m = msg { Text(m).font(.system(size: 11)).foregroundStyle(Holo.subDim) }

                if let err = model.error {
                    GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).font(.system(size: 12.5)).padding(20) }
                } else if model.loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if model.estratti.isEmpty {
                    emptyPlaceholder
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.estratti.enumerated()), id: \.element.id) { i, e in
                            row(e)
                            if i < model.estratti.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                        }
                    }
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task { await model.load() }
        .sheet(isPresented: $showForm) { EstrattoFormView { Task { await model.load() } } }
        .sheet(item: $riconcilia) { e in
            RiconciliazioneView(estratto: e, fatture: model.fatture, spese: model.spese)
        }
        .confirmationDialog(
            toDelete.map { "Eliminare l'estratto \(mesiNomi[safe: $0.mese] ?? "") \($0.anno)?" } ?? "",
            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) { if let e = toDelete { Task { await elimina(e) } } }
            Button("Annulla", role: .cancel) { toDelete = nil }
        }
    }

    private func row(_ e: Estratto) -> some View {
        let isCSV = (e.file_path ?? "").lowercased().hasSuffix(".csv")
        return HStack(spacing: 14) {
            Image(systemName: "building.columns.fill").font(.system(size: 15)).foregroundStyle(Holo.hsl(217, 75, 68))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(mesiNomi[safe: e.mese] ?? "—") \(e.anno)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.text)
                Text([e.banca, (e.file_path as NSString?)?.lastPathComponent].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim).lineLimit(1)
            }
            Spacer()
            Button { riconcilia = e } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .bold))
                    Text("Riconcilia").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(isCSV ? Color(hex: 0xeaf0fb) : Holo.labelDim)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 40/255, green: 70/255, blue: 140/255).opacity(isCSV ? 0.5 : 0.2)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Holo.hsl(217, 85, 62).opacity(isCSV ? 0.5 : 0.2), lineWidth: 1))
            }.buttonStyle(.plain).help(isCSV ? "Confronta coi movimenti" : "Riconciliazione disponibile solo per CSV")
            IconButton(icon: "paperclip", help: "Apri file") { Task { await apri(e) } }
            IconButton(icon: "trash", help: "Elimina", danger: true) { toDelete = e }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var addButton: some View {
        MenuPillButton(label: "Carica estratto", icon: "building.columns.fill") { showForm = true }
    }
    private var emptyPlaceholder: some View {
        GlassCard {
            VStack(spacing: 14) {
                Image(systemName: "building.columns").font(.system(size: 38)).foregroundStyle(Holo.hsl(217, 75, 65).opacity(0.85))
                    .shadow(color: Holo.hsl(217, 85, 60).opacity(0.5), radius: 10)
                Text("Nessun estratto conto").font(.system(size: 17, weight: .bold)).foregroundStyle(Holo.titleText)
                Text("Carica l'estratto conto della banca (meglio in CSV) per ogni mese: l'app lo confronta con fatture e spese e ti dice cosa manca.")
                    .font(.system(size: 12.5)).foregroundStyle(Holo.subDim).multilineTextAlignment(.center).frame(maxWidth: 400)
                MenuPillButton(label: "Carica estratto", icon: "building.columns.fill") { showForm = true }
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 320).padding(40)
        }
    }

    private func apri(_ e: Estratto) async {
        guard let path = e.file_path, let data = try? await HubAPI.downloadEstrattoFile(path: path) else { msg = "File non disponibile."; return }
        let ext = (path as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("estratto-\(e.anno)-\(e.mese)").appendingPathExtension(ext.isEmpty ? "csv" : ext)
        try? data.write(to: url); NSWorkspace.shared.open(url)
    }
    private func elimina(_ e: Estratto) async {
        toDelete = nil
        do { try await HubAPI.deleteEstratto(id: e.id, filePath: e.file_path); await model.load() }
        catch let er { msg = "Errore: \(er.localizedDescription)" }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// ─── Form: carica estratto conto ───
struct EstrattoFormView: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var anno = Calendar.current.component(.year, from: Date())
    @State private var mese = Calendar.current.component(.month, from: Date())
    @State private var banca = ""
    @State private var fileURL: URL?
    @State private var fileName = ""
    @State private var saving = false
    @State private var err: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CARICA ESTRATTO CONTO").font(.system(size: 15, weight: .heavy)).tracking(2).foregroundStyle(Holo.titleText)
                filePicker
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MESE").font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        Menu {
                            ForEach(1...12, id: \.self) { m in Button(mesiNomi[m]) { mese = m } }
                        } label: { menuLabel(mesiNomi[mese]) }.menuStyle(.borderlessButton)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ANNO").font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        Menu {
                            ForEach((2024...2030).reversed(), id: \.self) { y in Button(String(y)) { anno = y } }
                        } label: { menuLabel(String(anno)) }.menuStyle(.borderlessButton)
                    }
                    HoloField(label: "Banca (opzionale)", text: $banca, placeholder: "Es. Revolut")
                }
                if let err { Text(err).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad)) }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                    Button { save() } label: {
                        Text(saving ? "Carico…" : "Salva")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)], startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain).disabled(saving || fileURL == nil).opacity(fileURL == nil ? 0.5 : 1)
                }
            }.padding(24)
        }
        .frame(width: 520, height: 320)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255), Color(red: 8/255, green: 12/255, blue: 26/255)], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func menuLabel(_ t: String) -> some View {
        HStack { Text(t).font(.system(size: 13)).foregroundStyle(Color(hex: 0xe8f2ff)); Spacer()
            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Holo.labelDim) }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
    }
    private var filePicker: some View {
        Button { pick() } label: {
            HStack(spacing: 10) {
                Image(systemName: fileURL == nil ? "doc.badge.plus" : "doc.fill").font(.system(size: 16)).foregroundStyle(Holo.hsl(217, 80, 72))
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileURL == nil ? "Scegli file estratto (CSV consigliato)" : fileName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Holo.text).lineLimit(1)
                    Text(fileURL == nil ? "CSV per la riconciliazione, oppure PDF per archivio" : "tocca per cambiare").font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Holo.hsl(217, 80, 60).opacity(fileURL == nil ? 0.35 : 0.6),
                style: StrokeStyle(lineWidth: 1, dash: fileURL == nil ? [5, 4] : [])))
        }.buttonStyle(.plain)
    }
    private func pick() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .pdf, .plainText, .spreadsheet, .data]
        p.allowsMultipleSelection = false; p.canChooseDirectories = false
        if p.runModal() == .OK, let u = p.url { fileURL = u; fileName = u.lastPathComponent }
    }
    private func save() {
        guard let url = fileURL else { return }
        saving = true; err = nil
        Task {
            do {
                let bytes = try Data(contentsOf: url)
                let ext = url.pathExtension.isEmpty ? "csv" : url.pathExtension
                let ct = UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/csv"
                let name = "\(anno)-\(String(format: "%02d", mese))-\(UUID().uuidString.prefix(6)).\(ext)"
                let path = try await HubAPI.uploadEstrattoFile(bytes, name: name, contentType: ct)
                try await HubAPI.createEstratto([
                    "anno": anno, "mese": mese, "banca": banca.isEmpty ? nil : banca, "file_path": path,
                ])
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch { await MainActor.run { saving = false; err = error.localizedDescription } }
        }
    }
}
