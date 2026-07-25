import SwiftUI

@MainActor
final class ImmobiliareModel: ObservableObject {
    @Published var leads: [RELead] = []
    @Published var loading = true
    @Published var error: String?
    /// Ultima operazione non riuscita. Le mutazioni sono ottimistiche: se il
    /// salvataggio fallisce e nessuno lo dice, la card resta spostata a schermo
    /// e il dato sul server è un altro — lo schermo mentirebbe.
    @Published var azioneFallita: String?

    let kind: PipelineKind
    /// Progetto immobiliare di cui mostriamo i record. nil = tutti i progetti,
    /// per le viste di sistema (es. l'elenco potenziali dentro Contatti).
    let slug: String?
    init(kind: PipelineKind = .leads, slug: String? = nil) {
        self.kind = kind
        self.slug = slug
    }

    func load() async {
        loading = true
        do { leads = try await HubAPI.listRePipeline(kind, slug: slug); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Mutazione ottimistica + PATCH: la card si sposta subito sotto il dito.
    /// Se lo stadio non cambia (drop nella stessa colonna) non tocchiamo il DB.
    /// Se il PATCH fallisce si torna indietro: meglio vedere la card rimbalzare
    /// che crederla spostata.
    func setStage(_ id: String, _ stageId: String) async {
        guard let i = leads.firstIndex(where: { $0.id == id }), leads[i].stage != stageId else { return }
        let precedente = leads[i].stage
        leads[i].stage = stageId
        do { try await HubAPI.setRePipelineStage(kind, id: id, stage: stageId) }
        catch {
            if let j = leads.firstIndex(where: { $0.id == id }) { leads[j].stage = precedente }
            azioneFallita = "Spostamento non salvato: \(error.localizedDescription)"
        }
    }

    func setNotes(_ id: String, _ notes: String) async -> Bool {
        let v = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let precedente = leads.first { $0.id == id }?.notes
        if let i = leads.firstIndex(where: { $0.id == id }) { leads[i].notes = v.isEmpty ? nil : v }
        do {
            try await HubAPI.updateRePipeline(kind, id: id, fields: ["notes": v.isEmpty ? nil : v])
            return true
        } catch {
            if let j = leads.firstIndex(where: { $0.id == id }) { leads[j].notes = precedente }
            azioneFallita = "Nota non salvata: \(error.localizedDescription)"
            return false
        }
    }

    func remove(_ id: String) async {
        guard let rimosso = leads.first(where: { $0.id == id }) else { return }
        leads.removeAll { $0.id == id }
        do { try await HubAPI.deleteRePipeline(kind, id: id) }
        catch {
            leads.append(rimosso)
            leads.sort { ($0.created_at ?? "") > ($1.created_at ?? "") }
            azioneFallita = "Eliminazione non riuscita: \(error.localizedDescription)"
        }
    }
}

// Le schede della dash. Oltre alle due pipeline ci sono contatti, immobili e
// calendario: sono il lavoro quotidiano dell'agenzia e stavano sparsi nella
// sidebar, lontani dal progetto a cui appartengono.
enum GZTab: String, CaseIterable, Identifiable {
    case leads, owners, contatti, proprieta, documenti, calendario
    var id: String { rawValue }
    var label: String {
        switch self {
        case .leads: return "Leads"
        case .owners: return "Propietari / Inquilini"
        case .contatti: return "Contatti"
        case .proprieta: return "Proprietà"
        case .documenti: return "Documenti"
        case .calendario: return "Calendario"
        }
    }
    var icon: String {
        switch self {
        case .leads: return "person.crop.rectangle.stack"
        case .owners: return "house.and.flag"
        case .contatti: return "person.crop.circle"
        case .proprieta: return "house"
        case .documenti: return "folder"
        case .calendario: return "calendar"
        }
    }
    /// Le sole due schede che sono una pipeline kanban; le altre ospitano una
    /// vista propria e non hanno stadi, filtri fonte né statistiche.
    var pipeline: PipelineKind? {
        switch self { case .leads: return .leads; case .owners: return .owners; default: return nil }
    }
    var sottotitolo: String {
        switch self {
        case .leads: return "Pipeline lead e conversazioni WhatsApp"
        case .owners: return "Proprietari e inquilini che affidano immobili in gestione"
        case .contatti: return "Anagrafica di clienti e potenziali clienti, con le ricorrenze"
        case .proprieta: return "Registro immobili e visibilità sui siti"
        case .documenti: return "Modelli di contratto ed encargo, e le copie firmate"
        case .calendario: return "Disponibilità per le visite e appuntamenti fissati"
        }
    }
}

// ─── Dash immobiliare: pipeline lead + conversazioni WhatsApp ────────────────
// Una sola dash per tutte le agenzie (GZ Ibiza, Wallis 57): stesse schede,
// stesso layout, stesse tabelle. A cambiare è solo `slug`, che filtra i dati —
// ogni agenzia ha i suoi immobili, i suoi lead e i suoi contatti.
struct ImmobiliareDashboard: View {
    /// Progetto di cui è la dash: gz-ibiza, wallis-57, …
    let slug: String
    /// Titolo in testata (il nome del progetto).
    let titolo: String

    @StateObject private var model: ImmobiliareModel
    @StateObject private var owners: ImmobiliareModel

    init(slug: String, titolo: String) {
        self.slug = slug
        self.titolo = titolo
        _model  = StateObject(wrappedValue: ImmobiliareModel(kind: .leads,  slug: slug))
        _owners = StateObject(wrappedValue: ImmobiliareModel(kind: .owners, slug: slug))
    }

    @State private var tab: GZTab = .leads
    @State private var search = ""
    @State private var fonte: LeadSource?
    @State private var mostraAgente = false
    @State private var selected: RELead?
    @State private var mostraForm = false
    @State private var inModifica: RELead?     // nil = nuovo record

    // Il modello della pipeline attualmente mostrata (leads o proprietari/inquilini)
    private var active: ImmobiliareModel { tab == .owners ? owners : model }
    private var kind: PipelineKind { tab.pipeline ?? .leads }

    private var filtered: [RELead] {
        active.leads.filter { l in
            // il filtro fonte esiste solo per i lead (i proprietari arrivano in diretto)
            let okFonte = tab == .owners || fonte == nil || l.source == fonte!.rawValue
            guard okFonte else { return false }
            guard !search.isEmpty else { return true }
            return [l.name, l.email ?? "", l.phone ?? "", l.zone ?? "", l.notes ?? "", l.request_message ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private func inStage(_ id: String) -> [RELead] { filtered.filter { $0.stage == id } }
    // Le statistiche contano sui record filtrati, come il kanban sotto: contando
    // su tutti, con un filtro attivo la stessa schermata dava due numeri diversi
    // per la stessa colonna.
    private func count(_ id: String) -> Int { filtered.filter { $0.stage == id }.count }
    private var filtroAttivo: Bool { fonte != nil || !search.isEmpty }
    // insieme degli stadi "chiusi" della pipeline attiva (vinto/perso · concluso/archiviato)
    private var closedIds: Set<String> { Set(active.kind.stages.filter { $0.isClosed }.map(\.id)) }
    private var inLavorazione: Int {
        filtered.filter { $0.stage != "nuovo" && !closedIds.contains($0.stage) }.count
    }
    private var daWhatsApp: Int { filtered.filter { $0.source == LeadSource.whatsapp.rawValue }.count }

    /// Budget/valore complessivo dei record ancora aperti.
    private var valorePipeline: Int {
        filtered.filter { !closedIds.contains($0.stage) }
            .compactMap { $0.budget_max ?? $0.budget_min }.reduce(0, +)
    }
    /// Percentuale di chiusi con esito positivo (vinto / concluso) sul totale dei chiusi.
    private var conversione: Int {
        let chiusi = filtered.filter { closedIds.contains($0.stage) }.count
        guard chiusi > 0 else { return 0 }
        return Int((Double(count(active.kind.wonStageId)) / Double(chiusi) * 100).rounded())
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 14) {
                header
                pipelineTabs
                if let e = active.azioneFallita { bannerErrore(e) }

                if tab.pipeline != nil {
                    statRow
                    SectionCard(title: tab == .leads ? "Pipeline lead" : "Pipeline proprietari / inquilini",
                                count: filtroAttivo ? filtered.count : active.leads.count,
                                icon: "square.stack.3d.up") {
                        filtri
                    } content: {
                        if active.loading {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 40)
                        } else if let e = active.error {
                            Text("Errore: \(e)").font(.system(size: 12)).foregroundStyle(UI.tint(.stop))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                        } else {
                            board
                        }
                    }
                    // WhatsApp: solo per i lead (richieste in arrivo), non per i proprietari
                    if tab == .leads { WhatsAppSection(slug: slug) }
                } else {
                    // Le viste già esistenti, ospitate qui invece che nella
                    // sidebar: sono lavoro dell'agenzia, non voci di sistema.
                    // Ognuna vede solo i dati del proprio progetto.
                    switch tab {
                    case .contatti:   ContattiView(slug: slug)
                    case .proprieta:  ProprietaView(embedded: true, slug: slug)
                    case .documenti:  DocumentiView(progetto: slug)
                    case .calendario: CalendarioVisiteView(embedded: true, slug: slug)
                    default:          EmptyView()
                    }
                }
            }
            .blur(radius: selected != nil ? 2 : 0)
            .disabled(selected != nil)

            if let sel = selected {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                GZLeadDrawerView(
                    lead: sel,
                    stages: active.kind.stages,
                    isOwner: tab == .owners,
                    onStage: { sid in
                        Task { await active.setStage(sel.id, sid) }
                        if var l = selected { l.stage = sid; selected = l }
                    },
                    onNotes: { txt in
                        let ok = await active.setNotes(sel.id, txt)
                        if ok, var l = selected { l.notes = txt; selected = l }
                        return ok
                    },
                    onDelete: {
                        Task { await active.remove(sel.id) }
                        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
                    },
                    onEdit: {
                        inModifica = sel
                        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
                        mostraForm = true
                    },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 430)
                .transition(.move(edge: .trailing))
            }
        }
        .task { await model.load() }
        .task { await owners.load() }
        .sheet(isPresented: $mostraAgente) {
            AgenteSheet(slug: slug) { mostraAgente = false }
        }
        .sheet(isPresented: $mostraForm, onDismiss: { inModifica = nil }) {
            if tab == .owners {
                OwnerFormView(existing: inModifica, slug: slug) { await active.load() }
            } else {
                LeadFormView(existing: inModifica, kind: kind, slug: slug) { await active.load() }
            }
        }
    }

    /// L'errore di un salvataggio non riuscito: resta finché non lo si chiude,
    /// perché è la sola prova che quello che si vede a schermo non è sul server.
    private func bannerErrore(_ testo: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(UI.tint(.stop))
            Text(testo).font(.system(size: 11.5)).foregroundStyle(UI.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Aggiorna") { Task { await active.load(); active.azioneFallita = nil } }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(UI.accent)
            Button { active.azioneFallita = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(UI.dim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(UI.tint(.stop).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.tint(.stop).opacity(0.45), lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titolo)
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(UI.ink)
                Text(tab.sottotitolo)
                    .font(.system(size: 11.5)).foregroundStyle(UI.faint)
            }
            Spacer()
            // I comandi della pipeline non hanno senso su contatti, immobili e
            // calendario: quelle viste hanno i propri.
            if tab.pipeline != nil {
                GhostButton(label: kind.newLabel, icon: "plus") { inModifica = nil; mostraForm = true }
                if tab == .leads {
                    GhostButton(label: "Agente", icon: "gearshape.2") { mostraAgente = true }
                }
                GhostButton(label: "Aggiorna", icon: "arrow.clockwise") { Task { await active.load() } }
            }
        }
    }

    // Le schede della dash: le due pipeline più contatti, immobili e calendario
    private var pipelineTabs: some View {
        HStack(spacing: 4) {
            ForEach(GZTab.allCases) { k in
                let on = tab == k
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = k; selected = nil; search = ""; fonte = nil }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: k.icon).font(.system(size: 11, weight: .semibold))
                        Text(k.label).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        if let p = k.pipeline {
                            Text("\((p == .leads ? model : owners).leads.count)")
                                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .foregroundStyle(on ? UI.ink.opacity(0.7) : UI.faint)
                        }
                    }
                    .foregroundStyle(on ? UI.ink : UI.dim)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? UI.accent.opacity(0.16) : UI.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(on ? UI.accent.opacity(0.55) : UI.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            if tab == .leads {
                StatTile(label: "Nuovi", value: count("nuovo"), evidenzia: true)
                StatTile(label: "In lavorazione", value: inLavorazione)
                StatTile(label: "Da WhatsApp", value: daWhatsApp)
                StatTile(label: "Vinti", value: count("vinto"))
                StatTile(label: "Valore pipeline", testo: valorePipeline > 0 ? LeadFmt.compact(valorePipeline) : "—")
                StatTile(label: "Conversione", testo: conversione > 0 ? "\(conversione)%" : "—")
            } else {
                StatTile(label: "Nuovi", value: count("nuovo"), evidenzia: true)
                StatTile(label: "Da valutare", value: count("da_valutare"))
                StatTile(label: "Disponibili", value: count("disponibile"))
                StatTile(label: "In gestione", value: count("in_gestione"))
                StatTile(label: "Conclusi", value: count("concluso"))
                StatTile(label: "Valore immobili", testo: valorePipeline > 0 ? LeadFmt.compact(valorePipeline) : "—")
            }
        }
    }

    private var filtri: some View {
        HStack(spacing: 6) {
            if tab == .leads {
                FilterChip(label: "Tutte", selected: fonte == nil) { fonte = nil }
                ForEach(LeadSource.attive) { s in
                    FilterChip(label: s.label, icon: s.icon, selected: fonte == s) {
                        fonte = fonte == s ? nil : s
                    }
                }
            }
            HoloSearchField(placeholder: kind.searchPlaceholder, text: $search, width: 150)
        }
    }

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(active.kind.stages) { stage in
                    GZStageColumn(
                        stage: stage,
                        emptyText: active.kind.emptyColumn,
                        items: inStage(stage.id),
                        onDrop: { id in Task { await active.setStage(id, stage.id) } },
                        onSelect: { l in withAnimation(.easeInOut(duration: 0.2)) { selected = l } })
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// ─── Colonna pipeline ────────────────────────────────────────────────────────
private struct GZStageColumn: View {
    let stage: PipelineStage
    var emptyText: String = "Nessun lead"
    let items: [RELead]
    let onDrop: (String) -> Void
    let onSelect: (RELead) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(stage.color).frame(width: 6, height: 6)
                Text(stage.label.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.9)
                    .foregroundStyle(UI.dim)
                Spacer(minLength: 4)
                Text("\(items.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(items.isEmpty ? UI.faint : UI.text)
            }
            .padding(.horizontal, 2)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(items) { l in
                        GZLeadCard(lead: l)
                            .onTapGesture { onSelect(l) }
                            .draggable(l.id)
                    }
                    if items.isEmpty {
                        Text(emptyText).font(.system(size: 10.5)).foregroundStyle(UI.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                .padding(1)
            }
        }
        .frame(width: 236)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(targeted ? UI.accent.opacity(0.10) : UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(targeted ? UI.accent.opacity(0.55) : UI.line, lineWidth: 1))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }; onDrop(id); return true
        } isTargeted: { targeted = $0 }
    }
}

// ─── Card lead, con badge fonte ──────────────────────────────────────────────
private struct GZLeadCard: View {
    let lead: RELead
    @State private var hover = false

    var body: some View {
        let src = LeadSource.from(lead.source)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(lead.name.isEmpty ? "—" : lead.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UI.ink).lineLimit(1)
                Spacer(minLength: 4)
                // La fonte si riconosce dall'icona: niente pill colorata per ognuna
                Image(systemName: src.icon).font(.system(size: 9)).foregroundStyle(UI.faint)
                    .help(src.label)
            }

            // Contatti: servono a colpo d'occhio per richiamare senza aprire il lead
            VStack(alignment: .leading, spacing: 2) {
                if let mail = clean(lead.email) {
                    Text(mail).font(.system(size: 10.5)).foregroundStyle(UI.dim)
                        .lineLimit(1).truncationMode(.middle)   // il dominio resta leggibile
                }
                if let tel = clean(lead.phone) {
                    Text(tel).font(.system(size: 10.5)).foregroundStyle(UI.dim)
                        .lineLimit(1).monospacedDigit()
                }
            }

            if let z = clean(lead.zone) {
                Label(z, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 10)).foregroundStyle(UI.dim).lineLimit(1)
            }
            if let b = LeadFmt.budget(lead.budget_min, lead.budget_max) {
                Text(b).font(.system(size: 10.5, weight: .medium)).foregroundStyle(UI.text)
            }
            // Immobile offerto (proprietari): m² e operazione accanto alla descrizione
            if let off = clean(lead.property_offered) {
                Text(off + (lead.size_sqm.map { " · \($0) m²" } ?? ""))
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(UI.text)
                    .lineLimit(1)
            }
            // Il messaggio dal form, o in mancanza le note interne
            if let msg = clean(lead.request_message) ?? clean(lead.notes) {
                Text(msg).font(.system(size: 10.5)).lineSpacing(2)
                    .foregroundStyle(UI.dim).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Text(fmtLeadDate(lead.created_at)).font(.system(size: 9)).foregroundStyle(UI.faint)
                Spacer()
                if clean(lead.notes) != nil {
                    Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(UI.faint)
                        .help("Ha note interne")
                }
            }
            .padding(.top, 1)
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? UI.surfaceHi : UI.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hover = $0 }
    }

    private func clean(_ v: String?) -> String? {
        guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

// ─── Drawer laterale: dettaglio lead + note (gemello di quello Wallis) ───────
private struct GZLeadDrawerView: View {
    let lead: RELead
    let stages: [PipelineStage]
    /// I proprietari hanno i documenti dell'incarico, i lead no.
    var isOwner: Bool = false
    let onStage: (String) -> Void
    let onNotes: (String) async -> Bool
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    @State private var note: String = ""
    @State private var savedFlash = false
    @State private var confermaElimina = false
    private var stage: PipelineStage { stages.first { $0.id == lead.stage } ?? stages[0] }
    private var src: LeadSource { .from(lead.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lead.name.isEmpty ? "—" : lead.name)
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(UI.ink)
                    HStack(spacing: 6) {
                        Text(stage.label.uppercased())
                            .font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
                            .foregroundStyle(stage.color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(stage.color.opacity(0.16)))
                            .overlay(Capsule().strokeBorder(stage.color.opacity(0.5), lineWidth: 1))
                        // fonte: da dove è arrivato il lead (sito, WhatsApp, …)
                        HStack(spacing: 3) {
                            Image(systemName: src.icon).font(.system(size: 8))
                            Text(src.label).font(.system(size: 9, weight: .heavy))
                        }
                        .foregroundStyle(src.color)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(src.color.opacity(0.14)))
                    }
                }
                Spacer()
                // Modifica ed elimina stanno anche in fondo al pannello, ma il
                // fondo con una finestra più alta dello schermo non si
                // raggiunge: qui in testata ci sono sempre.
                Menu {
                    Button { onEdit() } label: { Label("Modifica scheda", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { confermaElimina = true } label: {
                        Label("Elimina tutta la scheda", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(UI.dim)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.05)))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.dim)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 46, leading: 22, bottom: 16, trailing: 20))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    section("PIPELINE") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(stages) { s in
                                let on = s.id == lead.stage
                                Button { onStage(s.id) } label: {
                                    Text(s.label).font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(on ? UI.ink : s.color)
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? s.color : s.color.opacity(0.12)))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(s.color.opacity(on ? 0 : 0.35), lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    section("CONTATTI") {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow("envelope.fill", clean(lead.email) ?? "—")
                            infoRow("phone.fill", clean(lead.phone) ?? "—")
                            infoRow("calendar", fmtLeadDate(lead.created_at))
                        }
                    }
                    // Immobile offerto dal proprietario (solo pipeline proprietari)
                    if let off = clean(lead.property_offered) {
                        section("IMMOBILE OFFERTO") {
                            Text(off).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(UI.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // Ricerca immobile (lead) / dettagli immobile (proprietari)
                    if let d = dettagli {
                        section(lead.property_offered != nil || lead.size_sqm != nil ? "DETTAGLI IMMOBILE" : "RICERCA") {
                            VStack(alignment: .leading, spacing: 8) { ForEach(d, id: \.1) { infoRow($0.0, $0.1) } }
                        }
                    }
                    // L'encargo firmato del proprietario sta qui, sulla sua scheda:
                    // è lì che uno lo va a cercare, non in un archivio generale.
                    if isOwner {
                        DocumentiAllegati(ownerId: lead.id, proprietaId: nil,
                                          titolo: "DOCUMENTI DEL PROPRIETARIO")
                    }
                    if let msg = clean(lead.request_message) {
                        section("RICHIESTA") {
                            Text(msg).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(UI.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section("NOTE") {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                                if note.isEmpty {
                                    Text("Aggiungi una nota…").font(.system(size: 12)).foregroundStyle(UI.dim)
                                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 0)).allowsHitTesting(false)
                                }
                                TextEditor(text: $note)
                                    .font(.system(size: 12.5)).foregroundStyle(UI.text)
                                    .scrollContentBackground(.hidden).background(Color.clear)
                                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                                    .frame(minHeight: 110)
                            }
                            HStack {
                                if savedFlash {
                                    Label("Salvato", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(UI.tint(.ok))
                                } else if note != (lead.notes ?? "") {
                                    // Chiudere il drawer con la nota non salvata la perde
                                    Label("Non salvata", systemImage: "circle.dashed")
                                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(UI.tint(.attesa))
                                }
                                Spacer()
                                Button {
                                    // Il «Salvato» compare solo se il server ha davvero accettato
                                    Task {
                                        guard await onNotes(note) else { return }
                                        savedFlash = true
                                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                                        savedFlash = false
                                    }
                                } label: {
                                    Text("Salva nota").font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(UI.ink)
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(Capsule().fill(UI.accent))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }

            HStack(spacing: 10) {
                if let tel = clean(lead.phone), let url = waURL(tel) {
                    Link(destination: url) {
                        Label("WhatsApp", systemImage: "message.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.ink).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                if let mail = clean(lead.email), let url = URL(string: "mailto:\(mail)") {
                    Link(destination: url) {
                        Label("Rispondi", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.ink).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                GhostButton(label: "Modifica", icon: "pencil", action: onEdit)
                Button { confermaElimina = true } label: {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(UI.tint(.stop))
                        .frame(width: 42, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(UI.tint(.stop).opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.tint(.stop).opacity(0.4), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 12, leading: 22, bottom: 18, trailing: 22))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UI.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(UI.line), alignment: .leading)
        .ignoresSafeArea()
        .onAppear { note = lead.notes ?? "" }
        // Sul pannello e non sul bottone: si chiede da due punti diversi, e
        // agganciata al bottone in fondo la conferma seguirebbe lui fuori
        // dallo schermo su finestre alte.
        .confirmationDialog("Eliminare tutta la scheda di \(lead.name.isEmpty ? "questo contatto" : lead.name)?",
                            isPresented: $confermaElimina, titleVisibility: .visible) {
            Button("Elimina tutto", role: .destructive, action: onDelete)
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Spariscono anagrafica, richiesta, note e storico della pipeline, e non si possono recuperare. Documenti e immobili collegati restano in archivio, solo senza più il legame con questa scheda.")
        }
    }

    /// Righe della sezione RICERCA, solo quelle valorizzate; nil se non c'è nulla da mostrare.
    private var dettagli: [(String, String)]? {
        var r: [(String, String)] = []
        if let v = clean(lead.interest) { r.append(("tag.fill", v.capitalized)) }
        if let v = clean(lead.property_type) { r.append(("house.fill", v.capitalized)) }
        if let v = clean(lead.zone) { r.append(("mappin.and.ellipse", v)) }
        if let m = lead.size_sqm { r.append(("ruler", "\(m) m²")) }
        if let v = LeadFmt.budget(lead.budget_min, lead.budget_max) { r.append(("eurosign.circle.fill", v)) }
        if let b = lead.bedrooms { r.append(("bed.double.fill", "\(b) camere")) }
        if let hl = lead.has_license {
            r.append(("checkmark.seal.fill", "Licenza: " + (hl ? "Sì" : "No") + (clean(lead.license_type).map { " · \($0)" } ?? "")))
        }
        if let tp = lead.three_phase { r.append(("bolt.fill", "Trifase: " + (tp ? "Sì" : "No"))) }
        return r.isEmpty ? nil : r
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(UI.dim)
            content()
        }
    }
    private func infoRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(UI.dim).frame(width: 16)
            Text(text).font(.system(size: 12.5)).foregroundStyle(UI.text).textSelection(.enabled)
        }
    }
    private func clean(_ v: String?) -> String? {
        guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    /// wa.me vuole il numero senza + né separatori
    private func waURL(_ tel: String) -> URL? {
        let n = tel.filter(\.isNumber)
        return n.isEmpty ? nil : URL(string: "https://wa.me/\(n)")
    }
}

// ─── Data ISO → "18 lug · 20:48" ─────────────────────────────────────────────
private func fmtLeadDate(_ s: String?) -> String {
    guard let s else { return "—" }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) ?? iso2.date(from: s) {
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM · HH:mm"
        return f.string(from: d)
    }
    return String(s.prefix(16)).replacingOccurrences(of: "T", with: " ")
}

// ─── Bottone "Agente", accanto al refresh nelle dash ─────────────────────────
struct AgenteButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                Text("Agente").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(hover ? UI.ink : Holo.hsl(140, 70, 65))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(hover ? Holo.hsl(140, 70, 62) : Holo.hsl(140, 70, 50).opacity(0.16)))
            .overlay(Capsule().strokeBorder(Holo.hsl(140, 70, 60).opacity(hover ? 0 : 0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Impostazioni dell'agente WhatsApp")
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
    }
}
