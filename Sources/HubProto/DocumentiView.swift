import SwiftUI

// ============================================================================
// Scheda «Documenti» della dash GZ Ibiza.
// A sinistra i modelli in bianco da riusare, a destra le copie firmate con il
// riferimento a chi appartengono. Il filtro per categoria vale per entrambe.
// ============================================================================

@MainActor final class DocumentiModel: ObservableObject {
    @Published var docs: [Documento] = []
    @Published var owners: [RELead] = []
    @Published var proprieta: [Proprieta] = []
    @Published var loading = true
    @Published var messaggio: String?

    func load() async {
        loading = true
        docs = (try? await HubAPI.listDocumenti()) ?? []
        owners = (try? await HubAPI.listRePipeline(.owners)) ?? []
        proprieta = (try? await HubAPI.listProprieta()) ?? []
        loading = false
    }
    /// A chi appartiene un documento firmato, in chiaro.
    func intestatario(_ d: Documento) -> String? {
        if let o = d.owner_id, let m = owners.first(where: { $0.id == o }) { return m.name }
        if let p = d.proprieta_id, let i = proprieta.first(where: { $0.id == p }) {
            return i.title.isEmpty ? (i.address ?? "Immobile") : i.title
        }
        return nil
    }
}

struct DocumentiView: View {
    @StateObject private var model = DocumentiModel()
    @State private var categoria: DocCategoria?
    @State private var search = ""
    @State private var busy = false

    private func filtrati(_ tipo: DocStato) -> [Documento] {
        model.docs.filter { d in
            d.tipo == tipo.rawValue
            && (categoria == nil || d.categoria == categoria!.rawValue)
            && (search.isEmpty || [d.titolo, d.descrizione ?? "", model.intestatario(d) ?? ""]
                    .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let m = model.messaggio { avviso(m) }
            filtri
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 40)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    colonna(.modello)
                    colonna(.firmato)
                }
            }
            Text("I modelli sono le bozze in bianco da riusare: non appartengono a nessuno. I firmati sono sempre agganciati a un proprietario o a un immobile, e si ritrovano anche dalla loro scheda. I file stanno in un archivio privato, non raggiungibile dai siti.")
                .font(.system(size: 10.5)).foregroundStyle(UI.faint)
        }
        .task { await model.load() }
    }

    private var filtri: some View {
        HStack(spacing: 6) {
            FilterChip(label: "Tutte", selected: categoria == nil) { categoria = nil }
            ForEach(DocCategoria.allCases) { c in
                FilterChip(label: c.label, icon: c.icon, selected: categoria == c) {
                    categoria = categoria == c ? nil : c
                }
            }
            HoloSearchField(placeholder: "Cerca documento…", text: $search, width: 160)
            Spacer(minLength: 0)
        }
    }

    private func colonna(_ tipo: DocStato) -> some View {
        let righe = filtrati(tipo)
        return SectionCard(title: tipo.label, count: righe.count, icon: tipo.icon) {
            GhostButton(label: "Carica", icon: "arrow.up.doc") {
                Task { await carica(tipo) }
            }.disabled(busy)
        } content: {
            if righe.isEmpty {
                Text(tipo == .modello
                     ? "Nessun modello. Carica qui l'encargo in bianco e i contratti tipo, così li hai sempre sottomano."
                     : "Nessun documento firmato. I PDF firmati si caricano da qui o dalla scheda del proprietario.")
                    .font(.system(size: 11)).foregroundStyle(UI.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(righe.enumerated()), id: \.element.id) { i, d in
                        DocRow(doc: d, intestatario: model.intestatario(d),
                               onApri: { Task { await apri(d) } },
                               onElimina: { Task { await elimina(d) } })
                        if i < righe.count - 1 { Divider().overlay(UI.line) }
                    }
                }
            }
        }
    }

    private func avviso(_ testo: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                .foregroundStyle(UI.tint(.attesa))
            Text(testo).font(.system(size: 11.5)).foregroundStyle(UI.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.messaggio = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(UI.dim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(UI.tint(.attesa).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.tint(.attesa).opacity(0.4), lineWidth: 1))
    }

    // ── azioni ──
    private func carica(_ tipo: DocStato) async {
        let urls = await MainActor.run { scegliDocumenti() }
        guard !urls.isEmpty else { return }
        busy = true; model.messaggio = nil
        // La categoria del filtro fa da default: se stai guardando gli encargo,
        // quello che carichi è quasi certamente un encargo.
        let falliti = await DocUploader.carica(urls, tipo: tipo, categoria: categoria ?? .altro)
        await model.load()
        busy = false
        if falliti > 0 { model.messaggio = "\(falliti) file su \(urls.count) non caricati." }
    }
    private func apri(_ d: Documento) async {
        do {
            let data = try await HubAPI.downloadDocumento(path: d.file_path)
            await MainActor.run { salvaEApri(data, nome: d.file_name ?? "\(d.titolo).pdf") }
        } catch {
            model.messaggio = "Non riesco ad aprire il file: \(error.localizedDescription)"
        }
    }
    private func elimina(_ d: Documento) async {
        do { try await HubAPI.deleteDocumento(d); await model.load() }
        catch { model.messaggio = "Eliminazione non riuscita: \(error.localizedDescription)" }
    }
}

// ── Riga documento, riusata anche nelle schede proprietario e immobile ───────
struct DocRow: View {
    let doc: Documento
    var intestatario: String? = nil
    let onApri: () -> Void
    let onElimina: () -> Void
    @State private var hover = false
    @State private var conferma = false

    var body: some View {
        let cat = DocCategoria.from(doc.categoria)
        HStack(spacing: 10) {
            Image(systemName: cat.icon).font(.system(size: 12)).foregroundStyle(UI.dim).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.titolo).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(cat.label).font(.system(size: 10)).foregroundStyle(UI.faint)
                    if let i = intestatario {
                        Text("·").foregroundStyle(UI.faint)
                        Text(i).font(.system(size: 10)).foregroundStyle(UI.accent).lineLimit(1)
                    }
                    if let f = doc.firmato_il {
                        Text("·").foregroundStyle(UI.faint)
                        Text("firmato \(f)").font(.system(size: 10)).foregroundStyle(UI.faint)
                    }
                }
            }
            Spacer(minLength: 6)
            Text(docPeso(doc.size_bytes)).font(.system(size: 10)).foregroundStyle(UI.faint)
                .monospacedDigit().frame(width: 58, alignment: .trailing)
            Button(action: onApri) {
                Image(systemName: "arrow.down.circle").font(.system(size: 13)).foregroundStyle(UI.dim)
            }.buttonStyle(.plain).help("Scarica e apri")
            Button { conferma = true } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(UI.tint(.stop).opacity(0.8))
            }.buttonStyle(.plain)
            .confirmationDialog("Eliminare «\(doc.titolo)»?", isPresented: $conferma) {
                Button("Elimina", role: .destructive, action: onElimina)
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Il file viene rimosso dall'archivio. L'operazione non si può annullare.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(hover ? UI.surfaceHi : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// ── Sezione documenti da incastonare in una scheda (proprietario o immobile) ──
struct DocumentiAllegati: View {
    let ownerId: String?
    let proprietaId: String?
    var titolo: String = "DOCUMENTI"

    @State private var docs: [Documento] = []
    @State private var busy = false
    @State private var messaggio: String?
    @State private var categoria: DocCategoria = .encargo

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(titolo).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(UI.dim)
                Spacer()
                // Si sceglie la categoria prima di caricare: un encargo firmato e
                // un contratto d'affitto non sono la stessa cosa da ritrovare.
                Menu {
                    ForEach(DocCategoria.allCases) { c in Button(c.label) { categoria = c } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: categoria.icon).font(.system(size: 9))
                        Text(categoria.label).font(.system(size: 10.5, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }.foregroundStyle(UI.dim)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Button { Task { await carica() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.doc").font(.system(size: 10, weight: .semibold))
                        Text(busy ? "Carico…" : "Carica firmato").font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(UI.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(UI.accent.opacity(0.85)))
                }.buttonStyle(.plain).disabled(busy)
            }
            if let m = messaggio {
                Text(m).font(.system(size: 10.5)).foregroundStyle(UI.tint(.stop))
            }
            if docs.isEmpty {
                Text("Nessun documento. Carica qui l'encargo firmato o il contratto.")
                    .font(.system(size: 11)).foregroundStyle(UI.faint).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(docs.enumerated()), id: \.element.id) { i, d in
                        DocRow(doc: d,
                               onApri: { Task { await apri(d) } },
                               onElimina: { Task { await elimina(d) } })
                        if i < docs.count - 1 { Divider().overlay(UI.line) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.line, lineWidth: 1))
            }
        }
        .task(id: ownerId ?? proprietaId ?? "") { await load() }
    }

    private func load() async {
        guard ownerId != nil || proprietaId != nil else { docs = []; return }
        docs = (try? await HubAPI.listDocumentiDi(ownerId: ownerId, proprietaId: proprietaId)) ?? []
    }
    private func carica() async {
        let urls = await MainActor.run { scegliDocumenti() }
        guard !urls.isEmpty else { return }
        busy = true; messaggio = nil
        let falliti = await DocUploader.carica(urls, tipo: .firmato, categoria: categoria,
                                               ownerId: ownerId, proprietaId: proprietaId)
        await load(); busy = false
        if falliti > 0 { messaggio = "\(falliti) file su \(urls.count) non caricati." }
    }
    private func apri(_ d: Documento) async {
        do {
            let data = try await HubAPI.downloadDocumento(path: d.file_path)
            await MainActor.run { salvaEApri(data, nome: d.file_name ?? "\(d.titolo).pdf") }
        } catch { messaggio = "Non riesco ad aprire il file." }
    }
    private func elimina(_ d: Documento) async {
        do { try await HubAPI.deleteDocumento(d); await load() }
        catch { messaggio = "Eliminazione non riuscita." }
    }
}
