import SwiftUI

// ============================================================================
// Scheda «Documenti» delle dash immobiliari (GZ Ibiza, Wallis 57).
// A sinistra i modelli in bianco da riusare, a destra le copie firmate con il
// riferimento a chi appartengono. Il filtro per categoria vale per entrambe.
// Ogni agenzia vede solo i propri: contratti ed encargo non si mescolano.
// ============================================================================

@MainActor final class DocumentiModel: ObservableObject {
    @Published var docs: [Documento] = []
    @Published var owners: [RELead] = []
    @Published var proprieta: [Proprieta] = []
    @Published var loading = true
    @Published var messaggio: String?

    let progetto: String
    init(progetto: String = "gz-ibiza") { self.progetto = progetto }

    func load() async {
        loading = true
        docs = (try? await HubAPI.listDocumenti(progetto: progetto)) ?? []
        owners = (try? await HubAPI.listRePipeline(.owners, slug: progetto)) ?? []
        proprieta = (try? await HubAPI.listProprieta(slug: progetto)) ?? []
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
    /// Agenzia di cui è l'archivio.
    let progetto: String
    @StateObject private var model: DocumentiModel

    init(progetto: String = "gz-ibiza") {
        self.progetto = progetto
        _model = StateObject(wrappedValue: DocumentiModel(progetto: progetto))
    }

    @State private var categoria: DocCategoria?
    @State private var search = ""
    @State private var busy = false
    @State private var sezione: DocSezione = .archivio

    /// Le due metà della scheda: quello che c'è già e quello che si fa adesso.
    private enum DocSezione: String, CaseIterable, Identifiable {
        case archivio, genera
        var id: String { rawValue }
        var label: String { self == .archivio ? "Archivio" : "Genera documento" }
        var icon: String { self == .archivio ? "folder" : "wand.and.stars" }
    }

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
            sezioni
            switch sezione {
            case .archivio: archivio
            case .genera:   DocGeneraView(progetto: progetto) { Task { await model.load() } }
            }
        }
        .task { await model.load() }
    }

    private var archivio: some View {
        VStack(alignment: .leading, spacing: 14) {
            filtri
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 40)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(DocStato.allCases) { colonna($0) }
                }
            }
            Text("I modelli sono le bozze in bianco da riusare: non appartengono a nessuno. I generati escono da un borrador riempito con i dati definitivi. I firmati sono sempre agganciati a un proprietario o a un immobile, e si ritrovano anche dalla loro scheda. I file stanno in un archivio privato, non raggiungibile dai siti.")
                .font(.system(size: 10.5)).foregroundStyle(UI.faint)
        }
    }

    private var sezioni: some View {
        HStack(spacing: 4) {
            ForEach(DocSezione.allCases) { s in
                let on = sezione == s
                Button { withAnimation(.easeInOut(duration: 0.15)) { sezione = s } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.icon).font(.system(size: 10.5, weight: .semibold))
                        Text(s.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(on ? UI.ink : UI.dim)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? UI.accent.opacity(0.16) : UI.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(on ? UI.accent.opacity(0.55) : UI.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// Le chip scorrono: sono dieci categorie più la ricerca, e su uno schermo
    /// stretto le ultime finivano fuori dalla finestra senza modo di arrivarci.
    /// La ricerca resta ferma a destra, che è dove la si cerca.
    private var filtri: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(label: "Tutte", selected: categoria == nil) { categoria = nil }
                    ForEach(DocCategoria.allCases) { c in
                        FilterChip(label: c.labelBreve, icon: c.icon, selected: categoria == c) {
                            categoria = categoria == c ? nil : c
                        }
                    }
                }
                .padding(.vertical, 1)   // il bordo delle chip selezionate non si taglia
            }
            HoloSearchField(placeholder: "Cerca documento…", text: $search, width: 150)
        }
    }

    private func colonna(_ tipo: DocStato) -> some View {
        let righe = filtrati(tipo)
        return SectionCard(title: tipo.label, count: righe.count, icon: tipo.icon) {
            // I generati non si caricano: escono dal generatore, e un bottone
            // «Carica» sotto quella colonna prometterebbe un'altra strada.
            if tipo != .generato {
                GhostButton(label: "Carica", icon: "arrow.up.doc") {
                    Task { await carica(tipo) }
                }.disabled(busy)
            }
        } content: {
            if righe.isEmpty {
                Text(vuoto(tipo))
                    .font(.system(size: 11)).foregroundStyle(UI.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(righe.enumerated()), id: \.element.id) { i, d in
                        DocRow(doc: d, intestatario: model.intestatario(d),
                               onApri: { Task { await apri(d) } },
                               onElimina: { Task { await elimina(d) } },
                               onRinomina: { nome in Task { await rinomina(d, nome) } })
                        if i < righe.count - 1 { Divider().overlay(UI.line) }
                    }
                }
            }
        }
    }

    private func vuoto(_ tipo: DocStato) -> String {
        switch tipo {
        case .modello:  return "Nessun modello. Carica qui l'encargo in bianco e i contratti tipo, così li hai sempre sottomano."
        case .generato: return "Nessun documento generato. Vai su «Genera documento»: scegli il borrador, il proprietario, l'immobile e il cliente, e il contratto esce già compilato."
        case .firmato:  return "Nessun documento firmato. I PDF firmati si caricano da qui o dalla scheda del proprietario."
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
        let falliti = await DocUploader.carica(urls, tipo: tipo, categoria: categoria ?? .altro,
                                               progetto: progetto)
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
    private func rinomina(_ d: Documento, _ nome: String) async {
        do {
            try await HubAPI.updateDocumento(id: d.id, fields: ["titolo": nome])
            await model.load()
        } catch { model.messaggio = "Nome non salvato: \(error.localizedDescription)" }
    }
}

// ── Riga documento, riusata anche nelle schede proprietario e immobile ───────
struct DocRow: View {
    let doc: Documento
    var intestatario: String? = nil
    let onApri: () -> Void
    let onElimina: () -> Void
    /// nil dove il nome non si tocca: la matita non compare nemmeno.
    var onRinomina: ((String) -> Void)? = nil
    @State private var hover = false
    @State private var conferma = false
    @State private var rinominando = false
    @State private var nuovoNome = ""
    @FocusState private var campoAttivo: Bool

    var body: some View {
        let cat = DocCategoria.from(doc.categoria)
        HStack(spacing: 10) {
            Image(systemName: cat.icon).font(.system(size: 12)).foregroundStyle(UI.dim).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                if rinominando {
                    // Invio conferma, Esc lascia perdere: si rinomina di
                    // seguito senza staccare le mani dalla tastiera.
                    TextField("", text: $nuovoNome)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(UI.ink)
                        .focused($campoAttivo)
                        .onSubmit { salvaNome() }
                        .onExitCommand { rinominando = false }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(UI.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UI.accent.opacity(0.6), lineWidth: 1))
                } else {
                    Text(doc.titolo).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink)
                        .lineLimit(1)
                        // Il nome è la cosa che si sbaglia più spesso caricando:
                        // due clic sopra e si corregge, senza cercare la matita.
                        .onTapGesture(count: 2) { if onRinomina != nil { iniziaRinomina() } }
                }
                HStack(spacing: 6) {
                    Text(cat.label).font(.system(size: 10)).foregroundStyle(UI.faint)
                    if let i = intestatario {
                        Text("·").foregroundStyle(UI.faint)
                        Text(i).font(.system(size: 10)).foregroundStyle(UI.accent).lineLimit(1)
                    }
                    if let f = doc.firmato_il {
                        Text("·").foregroundStyle(UI.faint)
                        Text("firmato \(f)").font(.system(size: 10)).foregroundStyle(UI.faint)
                    } else if let g = doc.generato_il {
                        Text("·").foregroundStyle(UI.faint)
                        Text("generato \(g.prefix(10))").font(.system(size: 10)).foregroundStyle(UI.faint)
                    }
                }
            }
            Spacer(minLength: 6)
            Text(docPeso(doc.size_bytes)).font(.system(size: 10)).foregroundStyle(UI.faint)
                .monospacedDigit().frame(width: 58, alignment: .trailing)
            Button(action: onApri) {
                Image(systemName: "arrow.down.circle").font(.system(size: 13)).foregroundStyle(UI.dim)
            }.buttonStyle(.plain).help("Scarica e apri")
            if onRinomina != nil {
                Button { rinominando ? salvaNome() : iniziaRinomina() } label: {
                    Image(systemName: rinominando ? "checkmark.circle.fill" : "pencil")
                        .font(.system(size: rinominando ? 13 : 12))
                        .foregroundStyle(rinominando ? UI.accent : UI.dim)
                }
                .buttonStyle(.plain)
                .help(rinominando ? "Salva il nome" : "Rinomina")
            }
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

    private func iniziaRinomina() {
        nuovoNome = doc.titolo
        rinominando = true
        campoAttivo = true
    }

    private func salvaNome() {
        let nome = nuovoNome.trimmingCharacters(in: .whitespaces)
        rinominando = false
        // Nome vuoto o uguale: non si scrive niente, un documento senza nome
        // in lista sarebbe irrecuperabile.
        guard !nome.isEmpty, nome != doc.titolo else { return }
        onRinomina?(nome)
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
                        Text(categoria.labelBreve).font(.system(size: 10.5, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }.foregroundStyle(UI.dim).lineLimit(1).fixedSize()
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
                               onElimina: { Task { await elimina(d) } },
                               onRinomina: { nome in Task { await rinomina(d, nome) } })
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
    private func rinomina(_ d: Documento, _ nome: String) async {
        do {
            try await HubAPI.updateDocumento(id: d.id, fields: ["titolo": nome])
            await load()
        } catch { messaggio = "Nome non salvato." }
    }
}
