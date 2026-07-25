import AppKit
import SwiftUI

// ── Pagina di dettaglio di un immobile ────────────────────────────────────────
//
// Impianto della pagina, in tre parti fisse:
//
//   1. TESTATA   foto di copertina, riferimento, stato, titolo, indirizzo
//   2. NUMERI    prezzo, superficie, €/m², vani — la riga che si guarda per prima
//   3. SEZIONI   panoramica · scheda tecnica · foto · proprietari · operazioni · documenti
//
// Regola che tiene insieme tutto: **le sezioni non cambiano fra lettura e
// modifica**. Prima metà del contenuto compariva solo in lettura (scheda
// tecnica, storico, documenti) e la griglia foto solo in modifica, così per
// sapere cosa c'era dentro un immobile bisognava entrare e uscire dalla
// modifica. Ora le righe sono sempre le stesse: cambia solo se la cella a
// destra è testo o campo compilabile.

enum SezioneProprieta: String, CaseIterable, Identifiable {
    case panoramica, scheda, foto, proprietari, operazioni, documenti
    var id: String { rawValue }

    var label: String {
        switch self {
        case .panoramica: return "Panoramica"
        case .scheda: return "Scheda tecnica"
        case .foto: return "Foto"
        case .proprietari: return "Proprietari"
        case .operazioni: return "Operazioni"
        case .documenti: return "Documenti"
        }
    }
    var icon: String {
        switch self {
        case .panoramica: return "square.grid.2x2"
        case .scheda: return "list.clipboard"
        case .foto: return "photo.on.rectangle"
        case .proprietari: return "person.2"
        case .operazioni: return "clock.arrow.circlepath"
        case .documenti: return "doc.text"
        }
    }
}

struct ProprietaDetailView: View {
    /// nil = pagina "nuova proprietà": stessa impaginazione, campi già aperti.
    let proprietaId: String?

    @State private var p: Proprieta?
    @State private var draft = PropertyDraft()
    @State private var editing: Bool
    @State private var loading: Bool
    @State private var saving = false
    @State private var errorMsg: String?
    @State private var sezione: SezioneProprieta = .panoramica
    @State private var showAddEvent = false
    @State private var showAddProprietario = false
    @State private var confirmDelete = false
    @State private var fotoBusy = false
    @State private var fotoMsg: String?
    @State private var gestisciAperto = false
    @State private var selezioneFoto: Set<String> = []
    @State private var confermaEliminaFoto = false
    @State private var videoBusy = false
    @State private var videoMsg: String?
    /// Video aperto nel player, nil quando è chiuso.
    @State private var videoAperto: VideoDaGuardare?
    @State private var projects: [Project] = []
    @State private var proprietari: [Proprietario] = []
    @State private var pdfStato: PDFStato = .fermo

    init(proprietaId: String?, slugIniziale: String = "gz-ibiza") {
        self.proprietaId = proprietaId
        _editing = State(initialValue: proprietaId == nil)
        _loading = State(initialValue: proprietaId != nil)
        // Nuova proprietà: nasce nell'agenzia da cui è stata aperta la pagina,
        // non sempre in GZ. Sull'esistente il progetto lo detta la riga sul DB.
        if proprietaId == nil {
            var d = PropertyDraft(); d.projectSlug = slugIniziale
            _draft = State(initialValue: d)
        }
    }

    private enum PDFStato: Equatable {
        case fermo, inCorso, fatto(String), errore(String)
    }

    private var isNew: Bool { proprietaId == nil }
    private var st: PropertyStatus { editing ? draft.status : .from(p?.status) }
    private var titolo: String {
        let t = editing ? draft.title : (p?.title ?? "")
        return t.isEmpty ? (isNew ? "Nuova proprietà" : "—") : t
    }
    private var riferimento: String {
        let r = editing ? draft.reference : (p?.reference ?? "")
        return r.trimmingCharacters(in: .whitespaces)
    }
    private var indirizzo: String {
        let parti = editing
            ? [draft.address, draft.zone, draft.city]
            : [p?.address ?? "", p?.zone ?? "", p?.city ?? ""]
        return parti.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                barraAzioni

                if let errorMsg {
                    GlassCard {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color(hex: 0xffb3ad))
                            Text(errorMsg).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xffb3ad))
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(16)
                    }
                }

                if loading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                    }.padding(.top, 40)
                } else if isNew || p != nil {
                    testata
                    numeriChiave
                    barraSezioni
                    contenuto
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 54 in alto e non meno: la finestra non ha barra del titolo e il
            // contenuto le passa sotto, ma quella fascia resta zona di
            // trascinamento e si mangia i clic. Con 34 i bottoni di questa
            // barra finivano dentro la fascia e non rispondevano.
            .padding(EdgeInsets(top: 54, leading: 30, bottom: 40, trailing: 30))
        }
        .task(id: proprietaId ?? "nuova") { await load() }
        .sheet(isPresented: $showAddEvent) {
            if let id = proprietaId { StoricoFormView(proprietaId: id) { await load() } }
        }
        .sheet(isPresented: $showAddProprietario) {
            if let id = proprietaId {
                ProprietarioFormView(proprietaId: id) { await caricaProprietari(id) }
            }
        }
        .confirmationDialog("Eliminare la proprietà e tutto il suo storico?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { delete() }
            Button("Annulla", role: .cancel) {}
        }
        // Più foto in un colpo solo si cancellano per sbaglio molto più
        // facilmente di una: qui si chiede conferma, sulla singola X no.
        .confirmationDialog(selezioneFoto.count == 1
                              ? "Eliminare la foto selezionata?"
                              : "Eliminare le \(selezioneFoto.count) foto selezionate?",
                            isPresented: $confermaEliminaFoto, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { Task { await eliminaSelezionate() } }
            Button("Annulla", role: .cancel) {}
        }
        .sheet(item: $videoAperto) { v in VideoProprietaSheet(path: v.id) }
    }

    // ── 1. Barra azioni: sempre in alto, non cambia posto fra le sezioni ──────
    private var barraAzioni: some View {
        HStack(spacing: 10) {
            Button { AppState.shared.route = .proprietaHub } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    Text("PROPRIETÀ").font(.system(size: 11)).tracking(1.5)
                }
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
            }.buttonStyle(.plain)

            Spacer(minLength: 12)

            if editing {
                Button("Annulla") { cancelEdit() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Holo.subDim)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                Button { Task { await save() } } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.small).scaleEffect(0.7) }
                        Text(saving ? "Salvataggio…" : "Salva").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(LinearGradient(
                        colors: [Holo.hsl(217, 82, 54), Holo.hsl(245, 72, 56)],
                        startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(.plain).disabled(saving || !draft.isValid).opacity(draft.isValid ? 1 : 0.5)
            } else {
                if !isNew { bottonePDF }
                Button { editing = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                        Text("Modifica").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Holo.hsl(217, 80, 52)))
                }.buttonStyle(.plain)

                Menu {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Elimina proprietà", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Csb.itemFg)
                        .frame(width: 32, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabsBg))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    /// Genera la scheda in PDF — lo stesso documento che riceve il cliente.
    private var bottonePDF: some View {
        Button { Task { await generaPDF() } } label: {
            HStack(spacing: 6) {
                switch pdfStato {
                case .inCorso: ProgressView().controlSize(.small).scaleEffect(0.7)
                case .fatto:   Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                case .errore:  Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                case .fermo:   Image(systemName: "doc.richtext").font(.system(size: 11, weight: .semibold))
                }
                Text(etichettaPDF).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(coloreP)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(coloreP.opacity(0.14)))
            .overlay(Capsule().strokeBorder(coloreP.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(pdfStato == .inCorso)
        .help(aiutoPDF)
    }

    private var etichettaPDF: String {
        switch pdfStato {
        case .fermo: return "Scheda PDF"
        case .inCorso: return "Genero…"
        case .fatto: return "Aperto"
        case .errore: return "Non riuscito"
        }
    }
    private var coloreP: Color {
        switch pdfStato {
        case .fatto: return Holo.hsl(145, 75, 66)
        case .errore: return Color(hex: 0xffb3ad)
        default: return Holo.hsl(28, 88, 66)
        }
    }
    private var aiutoPDF: String {
        if case let .errore(m) = pdfStato { return m }
        if case let .fatto(path) = pdfStato { return "Salvato in \(path)" }
        return "Genera la scheda tecnica in PDF (spagnolo, italiano, inglese, cinese) e la apre"
    }

    // ── 2. Testata: copertina + identità dell'immobile ───────────────────────
    private var testata: some View {
        ZStack(alignment: .bottomLeading) {
            copertina

            // Velo scuro dal basso: senza, il titolo bianco su una foto chiara
            // (facciate, spiagge) diventa illeggibile.
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.82)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if !riferimento.isEmpty {
                        Text("RIF. \(riferimento)").font(.system(size: 9.5, weight: .heavy)).tracking(1.4)
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 8).padding(.vertical, 3.5)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    }
                    StatusChip(text: st.label, hue: st.hue)
                    if let op = operationInfo(editing ? draft.listingType : p?.listing_type) {
                        Text(op.label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
                            .foregroundStyle(Holo.hsl(op.hue, 90, 78))
                            .padding(.horizontal, 8).padding(.vertical, 3.5)
                            .background(Capsule().fill(Holo.hsl(op.hue, 70, 40).opacity(0.55)))
                    }
                }

                Text(titolo).font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(.white).lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)

                if !indirizzo.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 10.5))
                        Text(indirizzo).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.86))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 22, bottom: 20, trailing: 22))
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Csb.panelBorder, lineWidth: 1))
    }

    @ViewBuilder private var copertina: some View {
        let foto = p?.photos ?? []
        if let prima = foto.first {
            FotoCopertina(path: prima)
        } else {
            // Nessuna foto: sfondo nella tinta dello stato, così la pagina non
            // sembra rotta e lo stato resta leggibile a colpo d'occhio.
            LinearGradient(colors: [Holo.hsl(st.hue, 45, 26), Holo.hsl(st.hue, 55, 14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(
                    Image(systemName: "house.fill").font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.09))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(30))
        }
    }

    // ── 3. Numeri chiave ─────────────────────────────────────────────────────
    private var numeriChiave: some View {
        let prezzo = editing ? Int(draft.price) : p?.price
        let affitto = editing ? Int(draft.priceRent) : p?.price_rent
        let mq = editing ? Int(draft.sqm) : p?.size_sqm
        let camere = editing ? Int(draft.bedrooms) : p?.bedrooms
        let bagni = editing ? Int(draft.bathrooms) : p?.bathrooms
        // Al metro quadro: è il numero con cui si confrontano due immobili e
        // nessuno ha voglia di calcolarlo a mano.
        let alMq: Int? = {
            guard let prezzo, let mq, mq > 0 else { return nil }
            return prezzo / mq
        }()

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
            if let prezzo {
                cellaNumero("PREZZO", LeadFmt.euro(prezzo), "eurosign.circle.fill", 145)
            }
            if let affitto {
                cellaNumero("AFFITTO", LeadFmt.euro(affitto) + "/mese", "calendar", 200)
            }
            if let mq {
                cellaNumero("SUPERFICIE", "\(mq) m²", "square.dashed", 210)
            }
            if let alMq {
                cellaNumero("AL M²", LeadFmt.euro(alMq), "function", 28)
            }
            if let camere, camere > 0 {
                cellaNumero("CAMERE", "\(camere)", "bed.double.fill", 262)
            }
            if let bagni, bagni > 0 {
                cellaNumero("BAGNI", "\(bagni)", "shower.fill", 190)
            }
        }
    }

    private func cellaNumero(_ label: String, _ valore: String, _ icona: String, _ tinta: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icona).font(.system(size: 9.5))
                Text(label).font(.system(size: 8.5, weight: .heavy)).tracking(1.1)
            }
            .foregroundStyle(Holo.hsl(tinta, 55, 66))
            Text(valore).font(.system(size: 16, weight: .bold)).foregroundStyle(Holo.titleText)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 12, trailing: 13))
        .background(RoundedRectangle(cornerRadius: 12).fill(Holo.hsl(tinta, 40, 30).opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Holo.hsl(tinta, 45, 50).opacity(0.28), lineWidth: 1))
    }

    // ── 4. Selettore di sezione ──────────────────────────────────────────────
    private var barraSezioni: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SezioneProprieta.allCases) { s in
                    // Su una proprietà nuova esiste solo la panoramica: le altre
                    // sezioni hanno bisogno di un id salvato su cui appendersi.
                    let bloccata = isNew && s != .panoramica
                    Button { if !bloccata { sezione = s } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: s.icon).font(.system(size: 10.5))
                            Text(s.label).font(.system(size: 12, weight: sezione == s ? .semibold : .medium))
                            if let n = conteggio(s), n > 0 {
                                Text("\(n)").font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(sezione == s ? .white : Csb.secFg)
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(Capsule().fill(sezione == s
                                        ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                            }
                        }
                        .foregroundStyle(sezione == s ? .white : Csb.itemFg)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(Capsule().fill(sezione == s
                            ? Holo.hsl(217, 78, 50).opacity(0.92) : Csb.tabsBg))
                        .overlay(Capsule().strokeBorder(sezione == s
                            ? .clear : Csb.tabOnBorder, lineWidth: 1))
                        .opacity(bloccata ? 0.35 : 1)
                    }
                    .buttonStyle(.plain).disabled(bloccata)
                    .help(bloccata ? "Salva prima la proprietà" : "")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func conteggio(_ s: SezioneProprieta) -> Int? {
        switch s {
        case .foto: return p?.photos?.count ?? 0
        case .proprietari: return proprietari.count
        case .operazioni: return p?.proprieta_storico?.count ?? 0
        default: return nil
        }
    }

    // ── 5. Contenuto della sezione scelta ────────────────────────────────────
    @ViewBuilder private var contenuto: some View {
        switch sezione {
        case .panoramica:
            pannello { schedaAnagrafica }
        case .scheda:
            if let p {
                SchedaTecnicaSection(
                    proprietaId: p.id,
                    tipoSuggerito: p.listing_type == "traspaso"
                        || (p.property_type ?? "").lowercased().contains("local")
                        ? "commerciale" : nil)
            }
        case .foto:
            sezioneFoto
        case .proprietari:
            sezioneProprietari
        case .operazioni:
            if let p { sezioneOperazioni(p) }
        case .documenti:
            if let p { ProprietaDocumentiSection(proprietaId: p.id) }
        }
    }

    private func pannello<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 16).fill(Csb.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Csb.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // ── Panoramica: le stesse righe in lettura e in modifica ─────────────────
    private var schedaAnagrafica: some View {
        VStack(spacing: 0) {
            riga("TITOLO", letto: p?.title.ifEmpty("—") ?? "—") {
                InlineField(placeholder: "Titolo proprietà *", text: $draft.title,
                            font: .system(size: 13, weight: .semibold))
            }
            divider
            riga("RIFERIMENTO", letto: (p?.reference ?? "").ifEmpty("—")) {
                InlineField(placeholder: "es. GZ00082", text: $draft.reference).frame(width: 220)
            }
            divider
            riga("STATO", letto: st.label) {
                InlinePicker(opts: PropertyStatus.allCases.map { ($0.rawValue, $0.label) },
                             sel: draft.status.rawValue) { draft.status = .from($0) }
                    .frame(width: 200)
            }
            divider
            riga("INDIRIZZO", letto: indirizzo.ifEmpty("—")) {
                VStack(spacing: 7) {
                    InlineField(placeholder: "Indirizzo (es. Carrer de …)", text: $draft.address)
                    HStack(spacing: 8) {
                        InlineField(placeholder: "Zona", text: $draft.zone)
                        InlineField(placeholder: "Città", text: $draft.city)
                    }
                }
            }
            divider
            riga("TIPOLOGIA", letto: [p?.category?.capitalized, p?.property_type]
                    .compactMap { $0 }.joined(separator: " · ").ifEmpty("—")) {
                HStack(spacing: 8) {
                    InlinePicker(opts: [("", "Categoria")] + LeadCategory.allCases.map { ($0.rawValue, $0.label) },
                                 sel: draft.category) { draft.category = $0 }
                    InlinePicker(opts: [("", "Tipo immobile")] + propertyTypes.map { ($0, $0) },
                                 sel: draft.propertyType) { draft.propertyType = $0 }
                }
            }
            divider
            riga("OPERAZIONE", letto: operationInfo(p?.listing_type)?.label ?? "—") {
                InlinePicker(opts: [("", "—")] + LeadInterest.allCases.map { ($0.rawValue, $0.label) },
                             sel: draft.listingType) { draft.listingType = $0 }
                    .frame(width: 220)
            }
            divider
            riga("DIMENSIONI", letto: [p?.size_sqm.map { "\($0) m²" },
                                       p?.bedrooms.map { "\($0) camere" },
                                       p?.bathrooms.map { "\($0) bagni" }]
                    .compactMap { $0 }.joined(separator: " · ").ifEmpty("—")) {
                HStack(spacing: 8) {
                    InlineField(placeholder: "m²", text: $draft.sqm).frame(width: 100)
                    InlineField(placeholder: "Camere", text: $draft.bedrooms).frame(width: 110)
                    InlineField(placeholder: "Bagni", text: $draft.bathrooms).frame(width: 110)
                    Spacer(minLength: 0)
                }
            }
            divider
            riga("PREZZO", letto: [p?.price.map { LeadFmt.euro($0) },
                                   p?.price_rent.map { LeadFmt.euro($0) + "/mese" }]
                    .compactMap { $0 }.joined(separator: " · ").ifEmpty("—")) {
                HStack(spacing: 8) {
                    InlineField(placeholder: "Prezzo € (vendita/traspaso)", text: $draft.price).frame(width: 230)
                    InlineField(placeholder: "Affitto €/mese", text: $draft.priceRent).frame(width: 180)
                    Spacer(minLength: 0)
                }
            }
            divider
            riga("PUBBLICAZIONE", letto: sitiLabel(p)) { visibilitaSiti }
            divider
            riga("DESCRIZIONE", letto: (p?.notes ?? "").ifEmpty("—")) {
                InlineField(placeholder: "Testo dell'annuncio: è quello che viene tradotto nelle quattro lingue del PDF",
                            text: $draft.notes, multiline: true)
            }
        }
    }

    /// Una riga della panoramica: etichetta a sinistra, a destra il valore
    /// oppure — a parità di posizione — il campo per modificarlo.
    private func riga<C: View>(_ label: String, letto: String,
                               @ViewBuilder _ campo: () -> C) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2)
                .foregroundStyle(Csb.secFg)
                .frame(width: 130, alignment: .leading)
                .padding(.top, editing ? 8 : 1)

            if editing {
                campo().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(letto).font(.system(size: 13)).foregroundStyle(Holo.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: editing ? 9 : 11, leading: 18,
                            bottom: editing ? 9 : 11, trailing: 18))
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }

    /// Riga di sola lettura: a quale agenzia appartiene e se è online.
    private func sitiLabel(_ p: Proprieta?) -> String {
        let slug = p?.project_slug ?? "gz-ibiza"
        let nome = agenzie.first { $0.slug == slug }?.name ?? slug
        return nome + ((p?.pubblicata ?? false) ? " · pubblicata sul sito" : " · non pubblicata")
    }

    /// Solo i progetti che sono agenzie immobiliari: un immobile non può stare
    /// dentro Camere PSE o NCREATIVE.
    private var agenzie: [Project] { projects.filter { AGENZIE_IMMOBILIARI.contains($0.slug) } }

    private var visibilitaSiti: some View {
        VStack(alignment: .leading, spacing: 8) {
            if agenzie.isEmpty {
                Text("Caricamento progetti…").font(.system(size: 11)).foregroundStyle(Holo.subDim)
            } else {
                // A CHI appartiene: una sola scelta, non una spunta per sito.
                HStack(spacing: 6) {
                    ForEach(agenzie) { proj in
                        let on = draft.projectSlug == proj.slug
                        Button { draft.projectSlug = proj.slug } label: {
                            Text(proj.name).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(on ? Holo.text : Csb.secFg)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(on ? Holo.hsl(217, 70, 50).opacity(0.22) : Color.white.opacity(0.04)))
                                .overlay(Capsule().strokeBorder(on ? Holo.hsl(217, 85, 64).opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }

                // SE è online sul sito di quell'agenzia.
                Button { draft.pubblicata.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: draft.pubblicata ? "eye.fill" : "eye.slash").font(.system(size: 10))
                        Text(draft.pubblicata ? "Pubblicata sul sito" : "Pubblica sul sito")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(draft.pubblicata ? Holo.hsl(145, 72, 60) : Csb.secFg)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(draft.pubblicata ? Holo.hsl(145, 60, 45).opacity(0.18) : Color.white.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(draft.pubblicata ? Holo.hsl(145, 60, 55).opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
                }.buttonStyle(.plain)

                Text("L'immobile appare nella dash dell'agenzia scelta e, se pubblicato, sul suo sito.")
                    .font(.system(size: 10.5)).foregroundStyle(Holo.subDim)
            }
        }
    }

    // ── Foto ─────────────────────────────────────────────────────────────────
    //
    // Si caricano da qui e basta, come i documenti: le foto erano l'unica cosa
    // che si poteva aggiungere solo entrando in modifica, e da fuori sembrava
    // che non si potessero aggiungere affatto. Caricamento ed eliminazione
    // vanno subito sul database, senza passare dal salvataggio della scheda.
    private var sezioneFoto: some View {
        let salvate = p?.photos ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GALLERIA").font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(210, 60, 66))
                if salvate.count > 1 {
                    Text("la prima è la copertina").font(.system(size: 10.5))
                        .foregroundStyle(Holo.subDim)
                }
                Spacer()
                bottoneCarica(icona: "photo.badge.plus", label: "Aggiungi foto",
                              inCorso: fotoBusy) { Task { await aggiungiFoto() } }
                bottoneCarica(icona: "video.badge.plus", label: "Aggiungi video",
                              inCorso: videoBusy) { Task { await aggiungiVideo() } }
            }

            if let fotoMsg {
                Text(fotoMsg).font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
            if let videoMsg {
                Text(videoMsg).font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }

            if salvate.isEmpty {
                EmptyStateCard(icon: "photo",
                    text: "Nessuna foto.\nCarica le immagini dell'immobile (JPG, PNG) con “Aggiungi foto”.")
            } else {
                // Una foto per volta, grande; sotto la striscia per saltare a
                // qualsiasi altra senza scorrerle tutte in fila.
                GalleriaFoto(paths: salvate)

                // "Gestisci" si apre e si chiude: chi guarda la scheda vede solo
                // la galleria, chi deve mettere ordine entra qui e trascina.
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { gestisciAperto.toggle() }
                    if !gestisciAperto { selezioneFoto = [] }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .black))
                            .rotationEffect(.degrees(gestisciAperto ? 90 : 0))
                        Text("GESTISCI").font(.system(size: 9, weight: .heavy)).tracking(1.4)
                        if gestisciAperto {
                            Text("trascina per riordinare · clic per selezionare")
                                .font(.system(size: 10)).tracking(0)
                                .foregroundStyle(Holo.subDim)
                        }
                    }
                    .foregroundStyle(Csb.secFg)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 4)

                if gestisciAperto {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            barraSelezioneFoto(salvate)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                ForEach(salvate, id: \.self) { path in
                                    FotoRiordinabile(
                                        path: path,
                                        copertina: path == salvate.first,
                                        selezionata: selezioneFoto.contains(path),
                                        selezioneAttiva: !selezioneFoto.isEmpty,
                                        onToggle: { toggleSelezione(path) },
                                        onDelete: { Task { await eliminaFoto(path) } },
                                        onDropSopra: { src in Task { await spostaFoto(src, su: path) } })
                                }
                            }
                        }
                        .padding(14)
                    }
                    // Senza questo il trascinamento di una foto lo intercetta
                    // AppKit e si porta dietro tutta la finestra.
                    .nonTrascinaLaFinestra()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            sezioneVideo
        }
    }

    /// Stesso bottone per foto e video: cambiano icona, testo e cosa fanno.
    private func bottoneCarica(icona: String, label: String, inCorso: Bool,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if inCorso {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                } else {
                    Image(systemName: icona).font(.system(size: 10, weight: .bold))
                }
                Text(inCorso ? "Carico…" : label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Csb.itemFgOn)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabOn.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(inCorso).opacity(inCorso ? 0.6 : 1)
    }

    // ── Video ────────────────────────────────────────────────────────────────
    //
    // Blocco a parte sotto le foto: si vede solo quando c'è almeno un video,
    // così una scheda senza filmati resta corta com'era.
    @ViewBuilder
    private var sezioneVideo: some View {
        let video = p?.videos ?? []
        if !video.isEmpty {
            Text("VIDEO").font(.system(size: 10, weight: .heavy)).tracking(2)
                .foregroundStyle(Holo.hsl(210, 60, 66))
                .padding(.top, 8)
            GlassCard {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(video, id: \.self) { path in
                        VideoProprietaCard(
                            path: path,
                            onApri: { videoAperto = VideoDaGuardare(id: path) },
                            onDelete: { Task { await eliminaVideo(path) } })
                    }
                }
                .padding(14)
            }
        }
    }

    // ── Selezione multipla ───────────────────────────────────────────────────
    //
    // Le foto arrivano a decine per immobile e finora ogni operazione era una
    // alla volta: dieci scatti sbagliati erano dieci X e dieci salvataggi.
    // Selezionandole si spostano, si scaricano o si buttano tutte insieme.
    private func barraSelezioneFoto(_ salvate: [String]) -> some View {
        let n = selezioneFoto.count
        return HStack(spacing: 8) {
            if n == 0 {
                Text("Clic su una foto per selezionarla.")
                    .font(.system(size: 11)).foregroundStyle(Holo.subDim)
                Spacer(minLength: 0)
                Button("Seleziona tutte") { selezioneFoto = Set(salvate) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Holo.hsl(210, 70, 70))
            } else {
                Text(n == 1 ? "1 foto selezionata" : "\(n) foto selezionate")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Holo.hsl(210, 75, 74))
                Spacer(minLength: 0)
                pillFoto("Porta all'inizio", "arrow.up.to.line", 210) {
                    Task { await portaSelezione(inCima: true) }
                }
                pillFoto("Porta alla fine", "arrow.down.to.line", 210) {
                    Task { await portaSelezione(inCima: false) }
                }
                pillFoto("Scarica", "arrow.down.circle", 145) {
                    Task { await scaricaSelezionate() }
                }
                pillFoto("Elimina", "trash", 5) { confermaEliminaFoto = true }
                pillFoto("Annulla", "xmark", 220) { selezioneFoto = [] }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: n)
    }

    private func pillFoto(_ label: String, _ icon: String, _ hue: Double,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Holo.hsl(hue, 80, 74))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Holo.hsl(hue, 60, 45).opacity(0.16)))
            .overlay(Capsule().strokeBorder(Holo.hsl(hue, 60, 55).opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(fotoBusy).opacity(fotoBusy ? 0.5 : 1)
    }

    private func toggleSelezione(_ path: String) {
        if selezioneFoto.contains(path) { selezioneFoto.remove(path) }
        else { selezioneFoto.insert(path) }
    }

    /// Le selezionate in blocco, in testa (la prima diventa copertina) o in coda.
    private func portaSelezione(inCima: Bool) async {
        guard let id = proprietaId, !selezioneFoto.isEmpty else { return }
        let arr = p?.photos ?? []
        let gruppo = arr.filter { selezioneFoto.contains($0) }   // ordine attuale
        let resto = arr.filter { !selezioneFoto.contains($0) }
        await salvaOrdine(inCima ? gruppo + resto : resto + gruppo, id: id)
    }

    /// Salva le foto scelte in una cartella, con il nome che hanno nel bucket.
    private func scaricaSelezionate() async {
        guard !selezioneFoto.isEmpty, !fotoBusy else { return }
        let cartella: URL? = await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Salva qui"
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let cartella else { return }

        fotoBusy = true; fotoMsg = nil
        defer { fotoBusy = false }
        let scelte = (p?.photos ?? []).filter { selezioneFoto.contains($0) }
        var falliti = 0
        for path in scelte {
            do {
                let data = try await HubAPI.downloadProprietaPhoto(path: path)
                let nome = (path as NSString).lastPathComponent
                try data.write(to: cartella.appendingPathComponent(nome))
            } catch { falliti += 1 }
        }
        fotoMsg = falliti > 0
            ? "\(scelte.count - falliti) di \(scelte.count) foto salvate in \(cartella.lastPathComponent)"
            : "\(scelte.count) foto salvate in \(cartella.lastPathComponent)"
    }

    /// Un solo salvataggio per tutte: l'elenco resta coerente anche se poi
    /// qualche file del bucket non si cancella.
    private func eliminaSelezionate() async {
        guard let id = proprietaId, !selezioneFoto.isEmpty, !fotoBusy else { return }
        fotoBusy = true; fotoMsg = nil
        defer { fotoBusy = false }
        let daTogliere = selezioneFoto
        do {
            let restanti = (p?.photos ?? []).filter { !daTogliere.contains($0) }
            try await HubAPI.updateProprieta(id: id, fields: ["photos": restanti])
            for path in daTogliere {
                try? await HubAPI.deleteProprietaPhotoFile(path: path)
                await FotoCache.shared.dimentica(path)
            }
            selezioneFoto = []
            await load()
        } catch let e {
            fotoMsg = "Eliminazione non riuscita: \(e.localizedDescription)"
        }
    }

    /// Scrive l'ordine e lo mostra subito, tornando indietro se la rete rifiuta.
    private func salvaOrdine(_ arr: [String], id: String) async {
        let precedente = p?.photos
        withAnimation(.easeInOut(duration: 0.16)) { p?.photos = arr }
        fotoMsg = nil
        do {
            try await HubAPI.updateProprieta(id: id, fields: ["photos": arr])
        } catch let e {
            p?.photos = precedente
            fotoMsg = "Ordine non salvato: \(e.localizedDescription)"
        }
    }

    /// Stessa strada delle foto: si scelgono i file, si caricano nel bucket e
    /// l'elenco va subito sul database, senza passare dal salvataggio scheda.
    private func aggiungiVideo() async {
        guard let id = proprietaId, !videoBusy else { return }
        let scelte: [URL] = await MainActor.run {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            return panel.runModal() == .OK ? panel.urls : []
        }
        guard !scelte.isEmpty else { return }

        videoBusy = true
        defer { videoBusy = false }
        var paths = p?.videos ?? []
        var errori: [String] = []
        var caricati = 0
        for (i, url) in scelte.enumerated() {
            // La ricompressione di un video lungo prende minuti: senza dire a
            // che punto è, sembra che l'app si sia piantata.
            videoMsg = scelte.count > 1
                ? "Preparo \(url.lastPathComponent) (\(i + 1) di \(scelte.count))…"
                : "Preparo \(url.lastPathComponent)…"
            guard let pronto = await VideoDaCaricare.prepara(url) else {
                errori.append("\(url.lastPathComponent): file non leggibile")
                continue
            }
            videoMsg = "Carico \(url.lastPathComponent) (\(pronto.dati.count / 1_048_576) MB)…"
            do {
                paths.append(try await HubAPI.uploadProprietaVideo(
                    propId: id, data: pronto.dati, ext: pronto.ext))
                caricati += 1
            } catch let e {
                // Il limite di Supabase (50 MB per file, piano free) è il
                // motivo tipico: senza il peso in chiaro non si sa cosa tagliare.
                errori.append("\(url.lastPathComponent) — \(pronto.dati.count / 1_048_576) MB: \(e.localizedDescription)")
            }
        }
        do {
            if caricati > 0 {
                try await HubAPI.updateProprieta(id: id, fields: ["videos": paths])
                await load()
            }
            videoMsg = errori.isEmpty ? nil : "Non caricati — " + errori.joined(separator: " · ")
        } catch let e {
            videoMsg = "Caricamento non riuscito: \(e.localizedDescription)"
        }
    }

    private func eliminaVideo(_ path: String) async {
        guard let id = proprietaId, !videoBusy else { return }
        videoBusy = true; videoMsg = nil
        defer { videoBusy = false }
        do {
            let restanti = (p?.videos ?? []).filter { $0 != path }
            try await HubAPI.updateProprieta(id: id, fields: ["videos": restanti])
            try? await HubAPI.deleteProprietaVideoFile(path: path)
            await VideoPosterCache.shared.dimentica(path)
            await load()
        } catch let e {
            videoMsg = "Eliminazione non riuscita: \(e.localizedDescription)"
        }
    }

    /// Sceglie i file, li carica nel bucket e aggiorna subito l'immobile.
    private func aggiungiFoto() async {
        guard let id = proprietaId, !fotoBusy else { return }
        // Il pannello di sistema vive sul thread principale: da un contesto
        // asincrono va aperto lì e basta aspettarne la scelta.
        let scelte: [URL] = await MainActor.run {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.jpeg, .png, .image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            return panel.runModal() == .OK ? panel.urls : []
        }
        guard !scelte.isEmpty else { return }

        fotoBusy = true; fotoMsg = nil
        defer { fotoBusy = false }
        var paths = p?.photos ?? []
        var falliti = 0
        for url in scelte {
            do {
                let data = try Data(contentsOf: url)
                paths.append(try await HubAPI.uploadProprietaPhoto(
                    propId: id, data: data, ext: url.pathExtension.lowercased()))
            } catch { falliti += 1 }
        }
        do {
            try await HubAPI.updateProprieta(id: id, fields: ["photos": paths])
            await load()
            // Un fallimento parziale va detto: le altre foto sono comunque
            // salvate, e senza avviso sembrerebbe che siano entrate tutte.
            fotoMsg = falliti > 0 ? "\(falliti) file non caricati (formato non supportato?)" : nil
        } catch let e {
            fotoMsg = "Caricamento non riuscito: \(e.localizedDescription)"
        }
    }

    /// Sposta `src` nella posizione di `dst`. L'ordine è quello che vale sul
    /// sito (la prima è la copertina), quindi si salva subito; la griglia si
    /// aggiorna prima della rete, altrimenti la foto tornerebbe indietro
    /// sotto le dita per il tempo della chiamata.
    private func spostaFoto(_ src: String, su dst: String) async {
        guard let id = proprietaId, src != dst else { return }
        var arr = p?.photos ?? []
        guard let to = arr.firstIndex(of: dst) else { return }
        // Trascinando una foto già selezionata si porta dietro tutte le altre
        // selezionate: averle scelte e poi doverle spostare a una a una
        // sarebbe il lavoro che la selezione doveva togliere.
        let gruppo = selezioneFoto.contains(src)
            ? arr.filter { selezioneFoto.contains($0) }
            : [src]
        guard !gruppo.contains(dst), let from = arr.firstIndex(of: gruppo[0]) else { return }
        arr.removeAll { gruppo.contains($0) }
        // Trascinando in avanti si finisce dopo la foto di arrivo, indietro
        // prima: è il verso che ci si aspetta guardando dove si lascia.
        let dest = arr.firstIndex(of: dst).map { from < to ? $0 + 1 : $0 } ?? arr.count
        arr.insert(contentsOf: gruppo, at: dest)
        await salvaOrdine(arr, id: id)
    }

    private func eliminaFoto(_ path: String) async {
        guard let id = proprietaId, !fotoBusy else { return }
        fotoBusy = true; fotoMsg = nil
        defer { fotoBusy = false }
        do {
            let restanti = (p?.photos ?? []).filter { $0 != path }
            try await HubAPI.updateProprieta(id: id, fields: ["photos": restanti])
            // Il file si cancella dopo: se fallisce resta un orfano nel bucket,
            // molto meno grave di una scheda che punta a una foto sparita.
            try? await HubAPI.deleteProprietaPhotoFile(path: path)
            await FotoCache.shared.dimentica(path)
            selezioneFoto.remove(path)
            await load()
        } catch let e {
            fotoMsg = "Eliminazione non riuscita: \(e.localizedDescription)"
        }
    }

    // ── Proprietari ──────────────────────────────────────────────────────────
    private var sezioneProprietari: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CATENA DEI PROPRIETARI").font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(210, 60, 66))
                Spacer()
                MenuPillButton(label: "Aggiungi proprietario", icon: "person.badge.plus") {
                    showAddProprietario = true
                }
            }

            if proprietari.isEmpty {
                EmptyStateCard(icon: "person.2",
                    text: "Nessun proprietario registrato.\nAggiungi chi possiede l'immobile oggi e chi lo possedeva prima.")
            } else {
                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(proprietari.enumerated()), id: \.element.id) { i, pr in
                            RigaProprietario(p: pr, ultimo: i == proprietari.count - 1) {
                                Task {
                                    try? await HubAPI.deleteProprietario(id: pr.id)
                                    if let id = proprietaId { await caricaProprietari(id) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // ── Operazioni (storico) ─────────────────────────────────────────────────
    private func sezioneOperazioni(_ p: Proprieta) -> some View {
        let eventi = (p.proprieta_storico ?? []).sorted { ($0.event_date ?? "") > ($1.event_date ?? "") }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("STORICO OPERAZIONI").font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(210, 60, 66))
                Spacer()
                MenuPillButton(label: "Aggiungi evento", icon: "plus") { showAddEvent = true }
            }
            if eventi.isEmpty {
                EmptyStateCard(icon: "clock.arrow.circlepath",
                    text: "Nessuna operazione registrata.\nAggiungi acquisizione, vendita, affitto o traspaso.")
            } else {
                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(eventi.enumerated()), id: \.element.id) { i, ev in
                            storicoRow(ev)
                            if i < eventi.count - 1 {
                                Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 68)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func storicoRow(_ ev: ProprietaStorico) -> some View {
        let e = StoricoEvent.from(ev.event_type)
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: e.icon).font(.system(size: 16))
                .foregroundStyle(Holo.hsl(e.hue, 88, 70))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Holo.hsl(e.hue, 70, 45).opacity(0.16)))
                .overlay(Circle().strokeBorder(Holo.hsl(e.hue, 70, 55).opacity(0.35), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(e.label).font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Holo.hsl(e.hue, 82, 76))
                    Text(prettyDate(ev.event_date)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Csb.secFg)
                        .padding(.horizontal, 7).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                }
                if ev.counterparty != nil || ev.agent != nil {
                    Text([ev.counterparty, ev.agent.map { "Agente: \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(Holo.subDim).lineLimit(1)
                }
                if let n = ev.notes, !n.isEmpty {
                    Text(n).font(.system(size: 11)).foregroundStyle(Holo.labelDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            if let pr = ev.price {
                Text(LeadFmt.euro(pr)).font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Holo.titleText).monospacedDigit()
            }
            IconButton(icon: "trash", help: "Elimina", danger: true) {
                Task { try? await HubAPI.deleteStorico(id: ev.id); await load() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // ── PDF ──────────────────────────────────────────────────────────────────
    private func generaPDF() async {
        guard let id = proprietaId, pdfStato != .inCorso else { return }
        pdfStato = .inCorso
        do {
            let dati = try await WABridge.shared.schedaPDF(proprietaId: id)
            // Nome file dal riferimento: in Download le schede restano
            // riconoscibili senza doverle aprire una per una.
            let base = riferimento.isEmpty ? "immobile" : riferimento
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let url = dir.appendingPathComponent("Scheda-\(base).pdf")
            try dati.write(to: url)
            NSWorkspace.shared.open(url)
            pdfStato = .fatto(url.path)
        } catch let e as WABridge.Errore {
            pdfStato = .errore(e.rimedio)
            errorMsg = "Scheda PDF non generata: \(e.localizedDescription) — \(e.rimedio)"
        } catch let e {
            pdfStato = .errore(e.localizedDescription)
            errorMsg = "Scheda PDF non generata: \(e.localizedDescription)"
        }
    }

    // ── Dati ─────────────────────────────────────────────────────────────────
    private func load() async {
        if projects.isEmpty { projects = (try? await HubAPI.listProjects()) ?? [] }
        guard let id = proprietaId else { return }
        loading = true; defer { loading = false }
        do {
            p = try await HubAPI.getProprieta(id: id)
            if let p, !editing { draft = PropertyDraft(p) }
            await caricaProprietari(id)
        } catch let e { errorMsg = e.localizedDescription }
    }

    private func caricaProprietari(_ id: String) async {
        proprietari = (try? await HubAPI.listProprietari(proprietaId: id)) ?? []
    }

    private func cancelEdit() {
        if isNew { AppState.shared.route = .proprietaHub; return }
        if let p { draft = PropertyDraft(p) }
        editing = false
    }

    private func save() async {
        guard draft.isValid, !saving else { return }
        saving = true; errorMsg = nil
        defer { saving = false }
        do {
            var fields = draft.fields()
            // Indirizzo cambiato: azzero le coordinate, la lista le rigeocodifica.
            if let e = p, draft.addressChanged(from: e) {
                fields.updateValue(nil, forKey: "latitude")
                fields.updateValue(nil, forKey: "longitude")
            }

            let propId: String
            if let e = p { try await HubAPI.updateProprieta(id: e.id, fields: fields); propId = e.id }
            else { propId = try await HubAPI.createProprieta(fields).id }

            editing = false
            if isNew { AppState.shared.route = .proprieta(id: propId) } else { await load() }
        } catch let e {
            errorMsg = "Salvataggio fallito: \(e.localizedDescription)"
        }
    }

    private func delete() {
        guard let id = proprietaId else { return }
        Task {
            do {
                try await HubAPI.deleteProprieta(id: id)
                await MainActor.run { AppState.shared.route = .proprietaHub }
            } catch let e {
                await MainActor.run { errorMsg = "Eliminazione fallita: \(e.localizedDescription)" }
            }
        }
    }
}

// ── Foto trascinabile: si prende e si lascia sopra un'altra ─────────────────
//
// L'ordine delle foto è quello che finisce sul sito, copertina compresa, e
// finora si poteva cambiare solo ricaricandole nell'ordine giusto.
private struct FotoRiordinabile: View {
    let path: String
    let copertina: Bool
    let selezionata: Bool
    /// Con almeno una foto scelta il pallino resta visibile su tutte: si vede
    /// dove cliccare per aggiungerne altre senza andare a caccia col mouse.
    let selezioneAttiva: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onDropSopra: (String) -> Void
    @State private var targeted = false
    @State private var hover = false

    var body: some View {
        RemotePhotoThumb(path: path, altezza: 100, onDelete: onDelete)
            .overlay(alignment: .bottomLeading) {
                if copertina {
                    Text("COPERTINA")
                        .font(.system(size: 8, weight: .heavy)).tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if selezionata || selezioneAttiva || hover {
                    Image(systemName: selezionata ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(selezionata ? Holo.hsl(210, 90, 68) : .white.opacity(0.85))
                        .background(Circle().fill(.black.opacity(0.55)).padding(1))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                let bordo = targeted ? Holo.hsl(210, 90, 65)
                          : (selezionata ? Holo.hsl(210, 85, 60) : Color.clear)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(bordo, lineWidth: targeted ? 2.5 : 2)
                    .shadow(color: targeted ? Holo.hsl(210, 90, 60).opacity(0.8) : .clear, radius: 5)
            }
            .opacity(targeted ? 0.75 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .draggable(path)
            .dropDestination(for: String.self) { items, _ in
                guard let s = items.first, s != path else { return false }
                onDropSopra(s); return true
            } isTargeted: { targeted = $0 }
            .help("Clic per selezionare · trascina per cambiare l'ordine")
    }
}

// ── Galleria: una foto per volta, con la striscia per saltare a qualsiasi ────
//
// L'immagine grande è contenuta, non ritagliata: qui si guarda l'immobile, e
// una foto tagliata a metà non serve a nessuno. Il ritaglio resta alla
// copertina della testata, dove conta riempire la fascia.
struct GalleriaFoto: View {
    let paths: [String]
    @State private var images: [String: NSImage] = [:]
    @State private var index = 0
    /// Quale foto si sta guardando, per nome e non per posizione: le posizioni
    /// cambiano a ogni riordino.
    @State private var mostrata: String?

    private var corrente: String? { paths.indices.contains(index) ? paths[index] : nil }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x0a0f1a))
                if let corrente, let img = images[corrente] {
                    Image(nsImage: img).resizable().scaledToFit().padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 440)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .overlay(alignment: .leading) { if paths.count > 1 { freccia("chevron.left", -1) } }
            .overlay(alignment: .trailing) { if paths.count > 1 { freccia("chevron.right", 1) } }
            .overlay(alignment: .topTrailing) { contatore }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.width < -30 { passo(1) } else if v.translation.width > 30 { passo(-1) }
            })

            if paths.count > 1 { striscia }
        }
        .task(id: paths) { await carica() }
        .onChange(of: index) { _, i in
            mostrata = paths.indices.contains(i) ? paths[i] : nil
        }
    }

    private var contatore: some View {
        Text("\(index + 1) / \(paths.count)")
            .font(.system(size: 10.5, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(12)
    }

    private func freccia(_ icona: String, _ d: Int) -> some View {
        Button { passo(d) } label: {
            Image(systemName: icona).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.5)))
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain).padding(12)
    }

    private var striscia: some View {
        ScrollViewReader { sp in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(paths.enumerated()), id: \.element) { i, path in
                        Button { withAnimation(.easeInOut(duration: 0.16)) { index = i } } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x0c1220))
                                if let img = images[path] {
                                    Image(nsImage: img).resizable().scaledToFill()
                                }
                            }
                            .frame(width: 96, height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                                i == index ? Holo.hsl(217, 85, 62) : Color.white.opacity(0.1),
                                lineWidth: i == index ? 2 : 1))
                            .opacity(i == index ? 1 : 0.62)
                        }
                        .buttonStyle(.plain).id(i)
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 2)
            }
            // La miniatura attiva si porta in vista da sola: con venti foto
            // altrimenti sparisce fuori dalla striscia usando le frecce.
            .onChange(of: index) { _, i in
                withAnimation(.easeInOut(duration: 0.2)) { sp.scrollTo(i, anchor: .center) }
            }
        }
    }

    private func passo(_ d: Int) {
        guard !paths.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            index = (index + d + paths.count) % paths.count
        }
    }

    private func carica() async {
        // Riordinando cambia `paths` e la galleria ripartiva dalla prima foto:
        // si spostava una miniatura e la grande saltava altrove. Si segue la
        // foto che si stava guardando, ovunque sia finita.
        if let mostrata, let i = paths.firstIndex(of: mostrata) { index = i }
        else if index >= paths.count { index = 0 }
        // In ordine, quindi la prima foto — quella mostrata all'apertura —
        // arriva subito e il resto si riempie mentre guardi.
        for path in paths where images[path] == nil {
            if let d = await FotoCache.shared.dati(path) { images[path] = NSImage(data: d) }
        }
    }
}

// ── Foto di copertina della testata ──────────────────────────────────────────
private struct FotoCopertina: View {
    let path: String
    @State private var img: NSImage?

    var body: some View {
        ZStack {
            Color(hex: 0x0c1220)
            if let img {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: path) { await carica() }
    }

    private func carica() async {
        if let d = await FotoCache.shared.dati(path) { img = NSImage(data: d) }
    }
}
