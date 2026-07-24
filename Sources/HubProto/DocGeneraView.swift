import SwiftUI
import AppKit

// ============================================================================
// Genera documento.
//
// L'ordine è quello del lavoro vero, e ogni passo apre il successivo:
//
//   1. il borrador  — quale contratto tipo stiamo facendo
//   2. il proprietario — chi firma dall'altra parte
//   3. l'immobile   — se ne ha uno solo non lo chiede nemmeno
//   4. il cliente   — futuro inquilino o compratore
//   5. le condizioni definitive — prezzo, durata, garanzie, spese, IPC
//
// Alla fine esce un PDF impaginato, che finisce nell'archivio come «generato»
// agganciato a proprietario e immobile, con dentro i dati usati: se fra un
// mese cambia una cifra non si ricomincia da capo.
// ============================================================================

@MainActor final class GeneraModel: ObservableObject {
    let progetto: String
    init(progetto: String) { self.progetto = progetto }

    @Published var borradores: [Borrador] = []
    @Published var owners: [RELead] = []
    @Published var leads: [RELead] = []
    @Published var proprieta: [Proprieta] = []
    @Published var loading = true

    @Published var borrador: Borrador?
    @Published var owner: RELead?
    @Published var immobile: Proprieta?
    @Published var dati = DatiContratto()

    @Published var busy = false
    @Published var messaggio: String?
    @Published var fatto: Documento?

    /// Da quale lead viene il cliente, quando non è scritto a mano: serve per
    /// agganciare il documento alla richiesta da cui è nato.
    @Published var clienteLeadId: String?

    func load() async {
        loading = true
        async let b = (try? await HubAPI.listBorradores(progetto: progetto)) ?? []
        async let o = (try? await HubAPI.listRePipeline(.owners, slug: progetto)) ?? []
        async let l = (try? await HubAPI.listRePipeline(.leads, slug: progetto)) ?? []
        async let p = (try? await HubAPI.listProprieta(slug: progetto)) ?? []
        borradores = await b; owners = await o; leads = await l; proprieta = await p
        loading = false
    }

    /// Gli immobili agganciati al proprietario scelto.
    var immobiliDelProprietario: [Proprieta] {
        guard let o = owner else { return [] }
        return proprieta.filter { $0.owner_id == o.id }
    }

    func scegli(owner o: RELead) {
        owner = o
        dati.proprietario.nome = o.name
        dati.proprietario.email = o.email ?? ""
        dati.proprietario.telefono = o.phone ?? ""
        immobile = nil
        // Se ne ha uno solo, la domanda non ha senso: la salta.
        let suoi = immobiliDelProprietario
        if suoi.count == 1 { scegli(immobile: suoi[0], agganciando: false) }
    }

    /// `agganciando`: la prima volta che scegli un immobile per un proprietario
    /// che non ne aveva, il legame resta scritto e la volta dopo non lo chiede.
    func scegli(immobile i: Proprieta, agganciando: Bool = true) {
        immobile = i
        dati.immobile.direccion = [i.address, i.zone].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if dati.immobile.direccion.isEmpty { dati.immobile.direccion = i.title }
        dati.immobile.titolo = i.title
        dati.immobile.referencia = i.reference ?? ""
        dati.immobile.zona = i.zone ?? ""
        dati.immobile.ciudad = i.city ?? "Ibiza"
        dati.immobile.m2 = i.size_sqm.map(String.init) ?? ""
        dati.immobile.habitaciones = i.bedrooms.map(String.init) ?? ""
        dati.immobile.banos = i.bathrooms.map(String.init) ?? ""
        if dati.canoneMensile == 0, let r = i.price_rent { dati.canoneMensile = r }
        dati.sincronizzaCanoni()
        if dati.fianzaImporto == 0 { dati.aggiornaFianzaDaMesi() }

        if agganciando, i.owner_id == nil, let o = owner {
            Task {
                try? await HubAPI.setProprietaOwner(proprietaId: i.id, ownerId: o.id)
                await load()
            }
        }
    }

    func scegli(cliente c: RELead) {
        clienteLeadId = c.id
        dati.cliente.nome = c.name
        dati.cliente.email = c.email ?? ""
        dati.cliente.telefono = c.phone ?? ""
    }

    var prontoPerGenerare: Bool {
        borrador != nil && !dati.proprietario.nome.isEmpty && !dati.cliente.nome.isEmpty
    }

    /// Il testo del contratto già riempito: è quello che finisce nel PDF ed è
    /// quello che si legge nell'anteprima. Uno solo, così non possono divergere.
    var testoRiempito: String {
        guard let b = borrador else { return "" }
        return DocRiempi.testo(borrador: b, dati: dati, agenzia: nomeAgenzia)
    }

    var nomeAgenzia: String { progetto == "wallis-57" ? "Wallis 57" : "GZ Ibiza" }

    func genera() async {
        guard let b = borrador else { return }
        busy = true; messaggio = nil; fatto = nil
        let testo = testoRiempito
        let titolo = "\(b.nome) — \(dati.cliente.nome)"
        let piede = "\(nomeAgenzia) · \(titolo) · generato il \(isoOggi())"

        guard let pdf = ContrattoPDF.render(titolo: titolo, testo: testo, piede: piede) else {
            busy = false; messaggio = "Il borrador è vuoto: non c'è niente da impaginare."
            return
        }
        do {
            let path = "generato/\(b.categoria)/\(UUID().uuidString)-\(docSlug(titolo)).pdf"
            _ = try await HubAPI.uploadDocumento(data: pdf, path: path, mime: "application/pdf")
            let doc = try await HubAPI.createDocumento([
                "progetto": progetto, "tipo": DocStato.generato.rawValue, "categoria": b.categoria,
                "titolo": titolo, "file_path": path, "file_name": "\(docSlug(titolo)).pdf",
                "mime": "application/pdf", "size_bytes": pdf.count,
                "owner_id": owner?.id, "proprieta_id": immobile?.id, "lead_id": clienteLeadId,
                "borrador_id": b.id, "generato_il": isoNowString(),
                "dati": DocRiempi.json(dati),
            ])
            fatto = doc
            // Il file è già in mano: si apre senza riscaricarlo.
            await MainActor.run { salvaEApri(pdf, nome: "\(docSlug(titolo)).pdf") }
        } catch {
            messaggio = "Documento non salvato: \(error.localizedDescription)"
        }
        busy = false
    }
}

// ── La pagina ────────────────────────────────────────────────────────────────
struct DocGeneraView: View {
    let progetto: String
    /// L'archivio si ricarica quando esce un documento nuovo.
    var onGenerato: () -> Void = {}

    @StateObject private var m: GeneraModel
    init(progetto: String, onGenerato: @escaping () -> Void = {}) {
        self.progetto = progetto
        self.onGenerato = onGenerato
        _m = StateObject(wrappedValue: GeneraModel(progetto: progetto))
    }

    @State private var categoria: DocCategoria?
    @State private var cercaCliente = ""
    @State private var editandoBorrador: Borrador?
    @State private var nuovoBorrador = false
    @State private var anteprima = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let msg = m.messaggio { errore(msg) }
            if let d = m.fatto { riuscito(d) }

            passoBorrador
            if m.borrador != nil {
                passoProprietario
                if m.owner != nil { passoImmobile }
                passoCliente
                passoCondizioni
                barraFinale
            }
        }
        .task { await m.load() }
        .sheet(isPresented: $nuovoBorrador) {
            BorradorEditor(progetto: progetto, esistente: nil) { Task { await m.load() } }
        }
        .sheet(item: $editandoBorrador) { b in
            BorradorEditor(progetto: progetto, esistente: b) { Task { await m.load() } }
        }
        .sheet(isPresented: $anteprima) { anteprimaSheet }
    }

    // ── 1. Borrador ─────────────────────────────────────────────────────────
    private var passoBorrador: some View {
        SectionCard(title: "1 · Borrador", count: borradoresFiltrati.count, icon: "doc.text") {
            HStack(spacing: 6) {
                if let b = m.borrador {
                    GhostButton(label: "Modifica", icon: "pencil") { editandoBorrador = b }
                }
                GhostButton(label: "Nuovo borrador", icon: "plus") { nuovoBorrador = true }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: "Tutti", selected: categoria == nil) { categoria = nil }
                        ForEach(categorieUsate) { c in
                            FilterChip(label: c.labelBreve, icon: c.icon, selected: categoria == c) {
                                categoria = categoria == c ? nil : c
                            }
                        }
                    }.padding(.vertical, 1)
                }
                if m.loading {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
                } else if borradoresFiltrati.isEmpty {
                    vuoto("Nessun borrador. Creane uno: è il testo del contratto con i {{segnaposto}} al posto di nomi e cifre. Puoi anche partire da un file che hai già — ne prendo il testo.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(borradoresFiltrati) { b in rigaBorrador(b) }
                    }
                }
            }
        }
    }

    private func rigaBorrador(_ b: Borrador) -> some View {
        let on = m.borrador?.id == b.id
        return Button {
            m.borrador = on ? nil : b
        } label: {
            HStack(spacing: 10) {
                Image(systemName: b.cat.icon).font(.system(size: 12))
                    .foregroundStyle(on ? UI.accent : UI.dim).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.nome).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink)
                    HStack(spacing: 6) {
                        Text(b.cat.label).font(.system(size: 10)).foregroundStyle(UI.faint)
                        Text("·").foregroundStyle(UI.faint)
                        Text(b.lingua.uppercased()).font(.system(size: 10)).foregroundStyle(UI.faint)
                        Text("·").foregroundStyle(UI.faint)
                        Text("\(b.segnaposti) segnaposto").font(.system(size: 10)).foregroundStyle(UI.faint)
                    }
                }
                Spacer(minLength: 6)
                if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(UI.accent) }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? UI.accent.opacity(0.12) : UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(on ? UI.accent.opacity(0.55) : UI.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }

    private var borradoresFiltrati: [Borrador] {
        m.borradores.filter { categoria == nil || $0.categoria == categoria!.rawValue }
    }
    private var categorieUsate: [DocCategoria] {
        let presenti = Set(m.borradores.map(\.categoria))
        return DocCategoria.allCases.filter { presenti.contains($0.rawValue) }
    }

    // ── 2. Proprietario ─────────────────────────────────────────────────────
    private var passoProprietario: some View {
        SectionCard(title: "2 · Proprietario", icon: "person.text.rectangle") {
            if m.owner != nil {
                GhostButton(label: "Cambia", icon: "arrow.triangle.2.circlepath") {
                    m.owner = nil; m.immobile = nil
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if let o = m.owner {
                    scelto(o.name, dettaglio: [o.email, o.phone].compactMap { $0 }.joined(separator: " · "))
                    datiParte($m.dati.proprietario, prefisso: "Proprietario")
                } else if m.owners.isEmpty {
                    vuoto("Nessun proprietario in pipeline. Si aggiungono dalla scheda «Propietari / Inquilini».")
                } else {
                    elencoPersone(m.owners) { m.scegli(owner: $0) }
                }
            }
        }
    }

    // ── 3. Immobile ─────────────────────────────────────────────────────────
    private var passoImmobile: some View {
        SectionCard(title: "3 · Immobile", icon: "house") {
            if m.immobile != nil {
                GhostButton(label: "Cambia", icon: "arrow.triangle.2.circlepath") { m.immobile = nil }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if let i = m.immobile {
                    scelto(i.title.isEmpty ? (i.address ?? "Immobile") : i.title,
                           dettaglio: [i.reference, i.address, i.zone].compactMap { $0 }
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                    datiImmobile
                } else {
                    let suoi = m.immobiliDelProprietario
                    if suoi.isEmpty {
                        Text("A questo proprietario non è agganciato nessun immobile. Scegline uno qui sotto: resta agganciato a lui, e la prossima volta non te lo chiedo.")
                            .font(.system(size: 11)).foregroundStyle(UI.faint)
                    }
                    let elenco = suoi.isEmpty ? m.proprieta : suoi
                    if elenco.isEmpty {
                        vuoto("Nessun immobile in questo progetto.")
                    } else {
                        VStack(spacing: 6) {
                            ForEach(elenco) { i in rigaImmobile(i) }
                        }
                    }
                }
            }
        }
    }

    private func rigaImmobile(_ i: Proprieta) -> some View {
        Button { m.scegli(immobile: i) } label: {
            HStack(spacing: 10) {
                Image(systemName: "house").font(.system(size: 12)).foregroundStyle(UI.dim).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.title.isEmpty ? (i.address ?? "Immobile") : i.title)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink).lineLimit(1)
                    Text([i.reference, i.zone, i.size_sqm.map { "\($0) m²" },
                          i.price_rent.map { LeadFmt.euro($0) + "/mese" }]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(UI.faint).lineLimit(1)
                }
                Spacer(minLength: 6)
                if i.owner_id == nil {
                    StatusPill(label: "da agganciare", tint: UI.tint(.attesa))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }

    private var datiImmobile: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                DGCampo(label: "Indirizzo nel contratto", text: $m.dati.immobile.direccion)
                DGCampo(label: "Riferimento", text: $m.dati.immobile.referencia).frame(width: 150)
            }
            HStack(spacing: 8) {
                DGCampo(label: "Zona", text: $m.dati.immobile.zona)
                DGCampo(label: "Città", text: $m.dati.immobile.ciudad).frame(width: 150)
                DGCampo(label: "m²", text: $m.dati.immobile.m2).frame(width: 90)
                DGCampo(label: "Rif. catastale", text: $m.dati.immobile.catastro).frame(width: 190)
            }
        }
    }

    // ── 4. Cliente ──────────────────────────────────────────────────────────
    private var passoCliente: some View {
        SectionCard(title: "4 · Cliente", icon: "person.crop.circle") {
            HoloSearchField(placeholder: "Cerca…", text: $cercaCliente, width: 130)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !m.dati.cliente.nome.isEmpty {
                    scelto(m.dati.cliente.nome,
                           dettaglio: [m.dati.cliente.email, m.dati.cliente.telefono]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                }
                if !clientiPossibili.isEmpty {
                    Text("DALLA PIPELINE").font(.system(size: 9, weight: .heavy)).tracking(1.2)
                        .foregroundStyle(UI.faint)
                    elencoPersone(clientiPossibili) { m.scegli(cliente: $0) }
                }
                Text("DATI DEFINITIVI").font(.system(size: 9, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(UI.faint)
                datiParte($m.dati.cliente, prefisso: "Cliente")
            }
        }
    }

    /// Chi può stare dall'altra parte: i lead (chi cerca casa) e i proprietari
    /// (che a volte sono anche inquilini). Il nome si può sempre scrivere a mano.
    private var clientiPossibili: [RELead] {
        let tutti = m.leads + m.owners
        let t = cercaCliente.trimmingCharacters(in: .whitespaces)
        let filtrati = t.isEmpty ? tutti : tutti.filter {
            [$0.name, $0.email ?? "", $0.phone ?? ""].joined(separator: " ")
                .localizedCaseInsensitiveContains(t)
        }
        return Array(filtrati.prefix(t.isEmpty ? 6 : 20))
    }

    // ── 5. Condizioni ───────────────────────────────────────────────────────
    private var passoCondizioni: some View {
        SectionCard(title: "5 · Condizioni definitive", icon: "eurosign.circle") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                bloccoDurata
                Divider().overlay(UI.line)
                bloccoCanone
                Divider().overlay(UI.line)
                bloccoGaranzie
                Divider().overlay(UI.line)
                bloccoIPC
                Divider().overlay(UI.line)
                bloccoSpese
                Divider().overlay(UI.line)
                bloccoExtra
            }
        }
    }

    private var bloccoDurata: some View {
        VStack(alignment: .leading, spacing: 8) {
            sottotitolo("DURATA E LUOGO")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    etichetta("Inizio")
                    DatePicker("", selection: $m.dati.inizio, displayedComponents: .date)
                        .datePickerStyle(.compact).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 5) {
                    etichetta("Durata (mesi)")
                    HStack(spacing: 5) {
                        ForEach([12, 24, 36, 60], id: \.self) { mesi in
                            FilterChip(label: mesi % 12 == 0 ? "\(mesi/12)a" : "\(mesi)m",
                                       selected: m.dati.durataMesi == mesi) {
                                m.dati.durataMesi = mesi; m.dati.sincronizzaCanoni()
                            }
                        }
                        DGNumero(label: "", valore: $m.dati.durataMesi, suffisso: "mesi")
                            .frame(width: 92)
                            .onChange(of: m.dati.durataMesi) { _, _ in m.dati.sincronizzaCanoni() }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    etichetta("Scadenza")
                    Text(dataBreve(m.dati.fine)).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(UI.text).padding(.vertical, 6)
                }
                DGCampo(label: "Luogo firma", text: $m.dati.lugar).frame(width: 140)
                VStack(alignment: .leading, spacing: 5) {
                    etichetta("Data documento")
                    DatePicker("", selection: $m.dati.data, displayedComponents: .date)
                        .datePickerStyle(.compact).labelsHidden()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var bloccoCanone: some View {
        VStack(alignment: .leading, spacing: 8) {
            sottotitolo("CANONE")
            HStack(spacing: 10) {
                DGNumero(label: "Canone mensile", valore: $m.dati.canoneMensile, suffisso: "€/mese")
                    .frame(width: 170)
                    .onChange(of: m.dati.canoneMensile) { _, _ in
                        m.dati.sincronizzaCanoni(); m.dati.aggiornaFianzaDaMesi()
                    }
                DGInterruttore(label: "Prezzo diverso anno per anno", on: $m.dati.canoneVariabile)
                    .onChange(of: m.dati.canoneVariabile) { _, acceso in
                        if acceso { m.dati.sincronizzaCanoni() }
                    }
                Spacer(minLength: 0)
            }
            if m.dati.canoneVariabile {
                VStack(spacing: 6) {
                    ForEach($m.dati.canoniAnno) { $c in
                        HStack(spacing: 10) {
                            Text("Anno \(c.anno)").font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(UI.text).frame(width: 64, alignment: .leading)
                            Text(periodoAnno(c.anno)).font(.system(size: 10.5)).foregroundStyle(UI.faint)
                                .frame(width: 180, alignment: .leading)
                            DGNumero(label: "", valore: $c.importo, suffisso: "€/mese").frame(width: 150)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.line, lineWidth: 1))
            }
        }
    }

    private var bloccoGaranzie: some View {
        VStack(alignment: .leading, spacing: 8) {
            sottotitolo("FIANZA E GARANZIE")
            HStack(spacing: 10) {
                DGNumero(label: "Fianza (mensilità)", valore: $m.dati.fianzaMesi, suffisso: "mesi")
                    .frame(width: 150)
                    .onChange(of: m.dati.fianzaMesi) { _, _ in m.dati.aggiornaFianzaDaMesi() }
                DGNumero(label: "Fianza (importo)", valore: $m.dati.fianzaImporto, suffisso: "€")
                    .frame(width: 150)
                DGNumero(label: "Garantía adicional", valore: $m.dati.garanziaImporto, suffisso: "€")
                    .frame(width: 160)
                DGCampo(label: "Nota sulla garanzia", text: $m.dati.garanziaNota)
            }
            HStack(spacing: 10) {
                DGInterruttore(label: "Aval bancario", on: $m.dati.avalAttivo)
                if m.dati.avalAttivo {
                    DGCampo(label: "Banca", text: $m.dati.avalBanca).frame(width: 220)
                    DGNumero(label: "Importo aval", valore: $m.dati.avalImporto, suffisso: "€")
                        .frame(width: 150)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var bloccoIPC: some View {
        VStack(alignment: .leading, spacing: 8) {
            sottotitolo("AGGIORNAMENTO (IPC)")
            HStack(spacing: 10) {
                DGInterruttore(label: "Aggiornamento annuale", on: $m.dati.ipcAttivo)
                if m.dati.ipcAttivo {
                    DGCampo(label: "Indice", text: $m.dati.ipcIndice).frame(width: 200)
                    DGCampo(label: "Nota (es. tetto massimo)", text: $m.dati.ipcNota)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var bloccoSpese: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sottotitolo("SPESE E FORNITURE")
                Spacer()
                GhostButton(label: "Aggiungi voce", icon: "plus") {
                    m.dati.gastos.append(GastoVoce(nome: ""))
                }
            }
            VStack(spacing: 6) {
                ForEach($m.dati.gastos) { $g in
                    HStack(spacing: 8) {
                        DGCampo(label: "", text: $g.nome, placeholder: "Voce di spesa").frame(width: 210)
                        Picker("", selection: $g.carico) {
                            ForEach(CaricoSpesa.allCases) { c in Text(c.label).tag(c) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 180)
                        DGCampo(label: "", text: $g.nota, placeholder: "Nota (facoltativa)")
                        Button {
                            m.dati.gastos.removeAll { $0.id == g.id }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                                .foregroundStyle(UI.tint(.stop).opacity(0.8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var bloccoExtra: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sottotitolo("CLAUSOLE PERSONALIZZATE")
                Spacer()
                GhostButton(label: "Aggiungi clausola", icon: "plus") {
                    m.dati.extras.append(ClausolaExtra())
                }
            }
            if m.dati.extras.isEmpty {
                Text("Finiscono in fondo al contratto, dove il borrador ha {{extras.tabla}}.")
                    .font(.system(size: 10.5)).foregroundStyle(UI.faint)
            }
            VStack(spacing: 6) {
                ForEach($m.dati.extras) { $c in
                    HStack(alignment: .top, spacing: 8) {
                        DGCampo(label: "", text: $c.titolo, placeholder: "Titolo").frame(width: 210)
                        DGCampo(label: "", text: $c.testo, placeholder: "Testo della clausola")
                        Button {
                            m.dati.extras.removeAll { $0.id == c.id }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                                .foregroundStyle(UI.tint(.stop).opacity(0.8))
                        }.buttonStyle(.plain).padding(.top, 6)
                    }
                }
            }
        }
    }

    // ── Barra finale ────────────────────────────────────────────────────────
    private var barraFinale: some View {
        HStack(spacing: 10) {
            if let b = m.borrador {
                let ignoti = DocSegnaposto.sconosciuti(in: b.corpo)
                if !ignoti.isEmpty {
                    Text("Il borrador ha segnaposto che non so riempire: \(ignoti.map { "{{\($0)}}" }.joined(separator: ", ")).")
                        .font(.system(size: 10.5)).foregroundStyle(UI.tint(.attesa))
                }
            }
            Spacer(minLength: 0)
            GhostButton(label: "Anteprima", icon: "eye") { anteprima = true }
            Button { Task { await m.genera(); onGenerato() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                    Text(m.busy ? "Genero…" : "Genera PDF").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(UI.ink)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(UI.accent.opacity(m.prontoPerGenerare ? 0.85 : 0.3)))
            }
            .buttonStyle(.plain)
            .disabled(m.busy || !m.prontoPerGenerare)
            .help(m.prontoPerGenerare ? "Impagina il contratto e lo salva nell'archivio"
                                      : "Servono borrador, proprietario e cliente")
        }
    }

    private var anteprimaSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ANTEPRIMA").font(.system(size: 12, weight: .heavy)).tracking(1.6)
                    .foregroundStyle(UI.ink)
                Spacer()
                GhostButton(label: "Chiudi") { anteprima = false }
            }
            ScrollView {
                Text(m.testoRiempito.isEmpty ? "Il borrador è vuoto." : m.testoRiempito)
                    .font(.system(size: 11.5, design: .serif))
                    .foregroundStyle(UI.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Nel PDF «# », «## » e «**» diventano titoli e grassetti: qui si vedono com'è scritto il testo.")
                .font(.system(size: 10.5)).foregroundStyle(UI.faint)
        }
        .padding(18).frame(width: 720, height: 640)
        .background(UI.panel).preferredColorScheme(.dark)
    }

    // ── Pezzi comuni ────────────────────────────────────────────────────────
    private func elencoPersone(_ persone: [RELead], scelta: @escaping (RELead) -> Void) -> some View {
        VStack(spacing: 6) {
            ForEach(persone) { p in
                Button { scelta(p) } label: {
                    HStack(spacing: 10) {
                        Avatar(nome: p.name, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink)
                            Text([p.email, p.phone, p.zone].compactMap { $0 }
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10)).foregroundStyle(UI.faint).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(UI.surface))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
        }
    }

    private func datiParte(_ parte: Binding<ParteContratto>, prefisso: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                DGCampo(label: "\(prefisso) — nome nel contratto", text: parte.nome)
                DGCampo(label: "NIF / NIE / passaporto", text: parte.nif).frame(width: 190)
            }
            HStack(spacing: 8) {
                DGCampo(label: "Domicilio", text: parte.direccion)
                DGCampo(label: "Email", text: parte.email).frame(width: 190)
                DGCampo(label: "Telefono", text: parte.telefono).frame(width: 150)
            }
        }
    }

    private func scelto(_ nome: String, dettaglio: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(UI.accent)
            Text(nome).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.ink)
            if !dettaglio.isEmpty {
                Text(dettaglio).font(.system(size: 10.5)).foregroundStyle(UI.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func sottotitolo(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .heavy)).tracking(1.2).foregroundStyle(UI.dim)
    }
    private func etichetta(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.1).foregroundStyle(UI.faint)
    }
    private func vuoto(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(UI.faint)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }
    private func errore(_ s: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                .foregroundStyle(UI.tint(.stop))
            Text(s).font(.system(size: 11.5)).foregroundStyle(UI.text)
            Spacer(minLength: 0)
            Button { m.messaggio = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(UI.dim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(UI.tint(.stop).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.tint(.stop).opacity(0.4), lineWidth: 1))
    }
    private func riuscito(_ d: Documento) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(UI.tint(.ok))
            Text("«\(d.titolo)» generato e salvato nell'archivio, sotto Generati.")
                .font(.system(size: 11.5)).foregroundStyle(UI.text)
            Spacer(minLength: 0)
            Button { m.fatto = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(UI.dim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(UI.tint(.ok).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UI.tint(.ok).opacity(0.4), lineWidth: 1))
    }

    private func dataBreve(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; return f.string(from: d)
    }
    private func periodoAnno(_ anno: Int) -> String {
        let cal = Calendar.current
        let da = cal.date(byAdding: .year, value: anno - 1, to: m.dati.inizio) ?? m.dati.inizio
        let a = cal.date(byAdding: .day, value: -1,
                         to: cal.date(byAdding: .year, value: anno, to: m.dati.inizio) ?? m.dati.inizio) ?? m.dati.inizio
        return "\(dataBreve(da)) – \(dataBreve(min(a, m.dati.fine)))"
    }
}

// ── Campi del generatore ─────────────────────────────────────────────────────
// Sobri come il resto della dash: l'etichetta sopra, il campo sotto, niente
// bordi accesi. HoloField è del mondo delle fatture, con l'azzurro forte.

struct DGCampo: View {
    var label: String = ""
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !label.isEmpty {
                Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.1)
                    .foregroundStyle(UI.faint).lineLimit(1)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UI.ink)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }
}

struct DGNumero: View {
    var label: String = ""
    @Binding var valore: Int
    var suffisso: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !label.isEmpty {
                Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.1)
                    .foregroundStyle(UI.faint).lineLimit(1)
            }
            HStack(spacing: 4) {
                TextField("0", text: testo)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UI.ink)
                    .monospacedDigit()
                if !suffisso.isEmpty {
                    Text(suffisso).font(.system(size: 10)).foregroundStyle(UI.faint)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }

    /// Solo cifre: un canone con dentro una lettera non è un numero, e il
    /// contratto uscirebbe con «€0».
    private var testo: Binding<String> {
        Binding(get: { valore == 0 ? "" : String(valore) },
                set: { valore = Int($0.filter(\.isNumber)) ?? 0 })
    }
}

struct DGInterruttore: View {
    let label: String
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12)).foregroundStyle(on ? UI.accent : UI.dim)
                Text(label).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(on ? UI.ink : UI.dim).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? UI.accent.opacity(0.12) : UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(on ? UI.accent.opacity(0.45) : UI.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}
