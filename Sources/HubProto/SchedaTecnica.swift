import SwiftUI

/// Scheda tecnica dell'immobile.
///
/// Un tronco comune (superfici, stato, economia) più un ramo specifico:
/// GZ Ibiza tratta locali e traspasi, Wallis 57 residenziale, e mostrare a un
/// locale i campi "camere da letto" o a un appartamento la "capienza
/// autorizzata" farebbe sembrare la scheda compilata male.
struct SchedaTecnica: Decodable, Equatable {
    var scheda_tipo: String?

    // Comune — superfici e struttura
    var sup_costruita: Int?
    var sup_utile: Int?
    var piano: String?
    var anno_costruzione: Int?
    var stato_conserv: String?
    var cert_energetico: String?
    var rif_catastale: String?
    var disponibile_da: String?
    var climatizzazione: Bool?
    var riscaldamento: Bool?
    var terrazza_mq: Int?

    // Comune — condizioni economiche
    var cauzione: Int?
    var spese_condominio: Int?
    var ibi_annuale: Int?

    // Commerciale
    var facciata_ml: Double?
    var altezza_libera: Double?
    var vetrine: Int?
    var servizi_igienici: Int?
    var magazzino: Bool?
    var licenza_attivita: String?
    var uscita_fumi: Bool?
    var capienza: Int?
    var terrazza_autorizzata: Bool?
    var tavoli_terrazza: Int?
    var attivita_attuale: String?
    var anni_contratto: Int?
    var fatturato_annuo: Int?
    var cucina_industriale: Bool?
    var cella_frigorifera: Bool?

    // Residenziale
    var giardino_mq: Int?
    var piscina: Bool?
    var posti_auto: Int?
    var ascensore: Bool?
    var orientamento: String?
    var arredato: String?
    var vista: String?
    var ripostiglio: Bool?

    var commerciale: Bool { (scheda_tipo ?? "commerciale") != "residenziale" }

    /// Quanti campi sono compilati: serve a mostrare quanto è completa la scheda,
    /// perché un PDF con metà campi vuoti fa una figura peggiore del non mandarlo.
    var compilati: (fatti: Int, totali: Int) {
        var f = 0, t = 0
        func c(_ v: Any?) { t += 1; if v != nil { f += 1 } }
        c(sup_costruita); c(sup_utile); c(piano); c(anno_costruzione); c(stato_conserv)
        c(cert_energetico); c(disponibile_da); c(climatizzazione); c(terrazza_mq)
        c(cauzione); c(spese_condominio); c(ibi_annuale)
        if commerciale {
            c(facciata_ml); c(altezza_libera); c(vetrine); c(servizi_igienici); c(magazzino)
            c(licenza_attivita); c(uscita_fumi); c(capienza); c(terrazza_autorizzata)
            c(attivita_attuale); c(anni_contratto); c(fatturato_annuo)
            c(cucina_industriale); c(cella_frigorifera)
        } else {
            c(giardino_mq); c(piscina); c(posti_auto); c(ascensore)
            c(orientamento); c(arredato); c(vista); c(ripostiglio)
        }
        return (f, t)
    }
}

extension HubAPI {
    static func getSchedaTecnica(_ id: String) async throws -> SchedaTecnica? {
        let campi = "scheda_tipo,sup_costruita,sup_utile,piano,anno_costruzione,stato_conserv," +
            "cert_energetico,rif_catastale,disponibile_da,climatizzazione,riscaldamento,terrazza_mq," +
            "cauzione,spese_condominio,ibi_annuale,facciata_ml,altezza_libera,vetrine,servizi_igienici," +
            "magazzino,licenza_attivita,uscita_fumi,capienza,terrazza_autorizzata,tavoli_terrazza," +
            "attivita_attuale,anni_contratto,fatturato_annuo,cucina_industriale,cella_frigorifera," +
            "giardino_mq,piscina,posti_auto,ascensore,orientamento,arredato,vista,ripostiglio"
        let righe: [SchedaTecnica] = try await sb.fetch("proprieta?select=\(campi)&id=eq.\(id)")
        return righe.first
    }

    static func salvaSchedaTecnica(_ id: String, _ campi: [String: Any?]) async throws {
        var body = campi
        body["updated_at"] = isoNowString()
        try await sb.mutate("proprieta?id=eq.\(id)", method: "PATCH", body: body)
    }
}

// ─── Valori proposti nei menu: evitano che ogni immobile usi parole diverse ──
let STATI_CONSERVAZIONE = ["Nuovo", "Ristrutturato", "Buono stato", "Da ristrutturare"]
let PIANI = ["Terra", "Seminterrato", "Ammezzato", "Primo", "Secondo", "Ultimo", "Attico"]
let CLASSI_ENERGETICHE = ["A", "B", "C", "D", "E", "F", "G", "In corso", "Esente"]
let ARREDAMENTO = ["Arredato", "Parzialmente arredato", "Non arredato"]
let ORIENTAMENTI = ["Nord", "Sud", "Est", "Ovest", "Nord-Est", "Nord-Ovest", "Sud-Est", "Sud-Ovest"]

// ─── Sezione nella pagina della proprietà ────────────────────────────────────
struct SchedaTecnicaSection: View {
    let proprietaId: String
    /// Serve a proporre il ramo giusto quando la scheda è ancora vuota.
    var tipoSuggerito: String?

    @State private var s = SchedaTecnica()
    @State private var editing = false
    @State private var loading = true
    @State private var saving = false
    @State private var errore: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                intestazione

                if loading {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
                } else {
                    if let errore {
                        Text(errore).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad))
                    }
                    blocchi
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 20, trailing: 22))
        }
        .task(id: proprietaId) { await carica() }
    }

    // ── Intestazione con avanzamento ──
    private var intestazione: some View {
        let (fatti, totali) = s.compilati
        let quota = totali > 0 ? Double(fatti) / Double(totali) : 0
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SCHEDA TECNICA").font(.system(size: 11, weight: .heavy)).tracking(2.5)
                    .foregroundStyle(Holo.hsl(217, 90, 70))
                Text(s.commerciale ? "Locale commerciale · traspaso" : "Immobile residenziale")
                    .font(.system(size: 10)).foregroundStyle(Holo.labelDim)
            }

            Spacer()

            // Completamento: un PDF con metà campi vuoti fa più danno che bene.
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 3).frame(width: 22, height: 22)
                    Circle().trim(from: 0, to: quota)
                        .stroke(Holo.hsl(quota > 0.7 ? 145 : (quota > 0.35 ? 45 : 5), 80, 62),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 22, height: 22).rotationEffect(.degrees(-90))
                }
                Text("\(fatti)/\(totali) compilati").font(.system(size: 10)).foregroundStyle(Holo.subDim)
            }

            if editing {
                Button("Annulla") { editing = false; Task { await carica() } }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                Button(saving ? "Salvo…" : "Salva") { Task { await salva() } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: 0x08130d))
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(Capsule().fill(Holo.hsl(150, 72, 62)))
                    .disabled(saving)
            } else {
                IconButton(icon: "square.and.pencil", help: "Modifica la scheda tecnica") {
                    editing = true
                }
            }
        }
    }

    // ── Blocchi ──
    @ViewBuilder
    private var blocchi: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editing { selettoreTipo }

            gruppo("SUPERFICI E STRUTTURA", [
                .num("Superficie costruita", "m²", $s.sup_costruita),
                .num("Superficie utile", "m²", $s.sup_utile),
                .menu("Piano", PIANI, $s.piano),
                .num("Anno di costruzione", "", $s.anno_costruzione),
                .num("Terrazza", "m²", $s.terrazza_mq),
            ] + (s.commerciale ? [
                .dec("Facciata", "m lineari", $s.facciata_ml),
                .dec("Altezza libera", "m", $s.altezza_libera),
                .num("Vetrine", "", $s.vetrine),
                .num("Servizi igienici", "", $s.servizi_igienici),
                .si("Magazzino", $s.magazzino),
            ] : [
                .num("Giardino", "m²", $s.giardino_mq),
                .num("Posti auto", "", $s.posti_auto),
                .si("Piscina", $s.piscina),
                .si("Ascensore", $s.ascensore),
                .menu("Orientamento", ORIENTAMENTI, $s.orientamento),
                .testo("Vista", $s.vista),
            ]))

            if s.commerciale {
                gruppo("LICENZE E ATTIVITÀ", [
                    .testo("Licenza di attività", $s.licenza_attivita),
                    .si("Uscita fumi", $s.uscita_fumi),
                    .num("Capienza autorizzata", "persone", $s.capienza),
                    .si("Terrazza autorizzata", $s.terrazza_autorizzata),
                    .num("Tavoli in terrazza", "", $s.tavoli_terrazza),
                    .testo("Attività attuale", $s.attivita_attuale),
                ])
            }

            gruppo("CONDIZIONI ECONOMICHE", [
                .num("Cauzione", "€", $s.cauzione),
                .num("Spese condominiali", "€/mese", $s.spese_condominio),
                .num("IBI annuale", "€", $s.ibi_annuale),
            ] + (s.commerciale ? [
                .num("Anni di contratto residui", "", $s.anni_contratto),
                .num("Fatturato annuo", "€", $s.fatturato_annuo),
            ] : []))

            gruppo("STATO E IMPIANTI", [
                .menu("Stato di conservazione", STATI_CONSERVAZIONE, $s.stato_conserv),
                .si("Climatizzazione", $s.climatizzazione),
                .si("Riscaldamento", $s.riscaldamento),
                .menu("Certificato energetico", CLASSI_ENERGETICHE, $s.cert_energetico),
                .testo("Disponibile da", $s.disponibile_da),
                .testo("Riferimento catastale", $s.rif_catastale),
            ] + (s.commerciale ? [
                .si("Cucina industriale", $s.cucina_industriale),
                .si("Cella frigorifera", $s.cella_frigorifera),
            ] : [
                .menu("Arredamento", ARREDAMENTO, $s.arredato),
                .si("Ripostiglio", $s.ripostiglio),
            ]))
        }
    }

    private var selettoreTipo: some View {
        HStack(spacing: 10) {
            Text("Tipo di scheda").font(.system(size: 11, weight: .semibold)).foregroundStyle(Holo.text)
            Picker("", selection: Binding(
                get: { s.commerciale ? "commerciale" : "residenziale" },
                set: { s.scheda_tipo = $0 })) {
                Text("Commerciale").tag("commerciale")
                Text("Residenziale").tag("residenziale")
            }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
            Text("cambia i campi mostrati").font(.system(size: 10)).foregroundStyle(Holo.labelDim)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
    }

    // ── Un gruppo di campi, in due colonne ──
    private func gruppo(_ titolo: String, _ campi: [CampoScheda]) -> some View {
        // In lettura nascondo i campi vuoti: una scheda piena di trattini
        // sembra incompleta anche quando i dati che contano ci sono tutti.
        let visibili = editing ? campi : campi.filter { !$0.vuoto }
        return Group {
            if !visibili.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(titolo).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(Holo.hsl(210, 70, 62).opacity(0.9))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 22),
                                        GridItem(.flexible(), spacing: 22)],
                              alignment: .leading, spacing: 6) {
                        ForEach(visibili) { c in RigaCampo(campo: c, editing: editing) }
                    }
                }
            }
        }
    }

    // ── Dati ──
    private func carica() async {
        do {
            if let caricata = try await HubAPI.getSchedaTecnica(proprietaId) {
                s = caricata
                if s.scheda_tipo == nil { s.scheda_tipo = tipoSuggerito ?? "commerciale" }
            }
            errore = nil
        } catch { errore = "Non riesco a leggere la scheda: \(error.localizedDescription)" }
        loading = false
    }

    private func salva() async {
        saving = true
        defer { saving = false }
        do {
            try await HubAPI.salvaSchedaTecnica(proprietaId, [
                "scheda_tipo": s.scheda_tipo,
                "sup_costruita": s.sup_costruita, "sup_utile": s.sup_utile, "piano": s.piano,
                "anno_costruzione": s.anno_costruzione, "stato_conserv": s.stato_conserv,
                "cert_energetico": s.cert_energetico, "rif_catastale": s.rif_catastale,
                "disponibile_da": s.disponibile_da, "climatizzazione": s.climatizzazione,
                "riscaldamento": s.riscaldamento, "terrazza_mq": s.terrazza_mq,
                "cauzione": s.cauzione, "spese_condominio": s.spese_condominio,
                "ibi_annuale": s.ibi_annuale, "facciata_ml": s.facciata_ml,
                "altezza_libera": s.altezza_libera, "vetrine": s.vetrine,
                "servizi_igienici": s.servizi_igienici, "magazzino": s.magazzino,
                "licenza_attivita": s.licenza_attivita, "uscita_fumi": s.uscita_fumi,
                "capienza": s.capienza, "terrazza_autorizzata": s.terrazza_autorizzata,
                "tavoli_terrazza": s.tavoli_terrazza, "attivita_attuale": s.attivita_attuale,
                "anni_contratto": s.anni_contratto, "fatturato_annuo": s.fatturato_annuo,
                "cucina_industriale": s.cucina_industriale, "cella_frigorifera": s.cella_frigorifera,
                "giardino_mq": s.giardino_mq, "piscina": s.piscina, "posti_auto": s.posti_auto,
                "ascensore": s.ascensore, "orientamento": s.orientamento, "arredato": s.arredato,
                "vista": s.vista, "ripostiglio": s.ripostiglio,
            ])
            editing = false
            errore = nil
        } catch { errore = "Salvataggio fallito: \(error.localizedDescription)" }
    }
}

// ─── Campi ───────────────────────────────────────────────────────────────────

enum CampoScheda: Identifiable {
    case num(String, String, Binding<Int?>)
    case dec(String, String, Binding<Double?>)
    case testo(String, Binding<String?>)
    case menu(String, [String], Binding<String?>)
    case si(String, Binding<Bool?>)

    var id: String { etichetta }

    var etichetta: String {
        switch self {
        case .num(let e, _, _), .dec(let e, _, _), .testo(let e, _), .menu(let e, _, _), .si(let e, _): return e
        }
    }

    var vuoto: Bool {
        switch self {
        case .num(_, _, let b): return b.wrappedValue == nil
        case .dec(_, _, let b): return b.wrappedValue == nil
        case .testo(_, let b): return (b.wrappedValue ?? "").isEmpty
        case .menu(_, _, let b): return (b.wrappedValue ?? "").isEmpty
        case .si(_, let b): return b.wrappedValue == nil
        }
    }
}

private struct RigaCampo: View {
    let campo: CampoScheda
    let editing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(campo.etichetta)
                .font(.system(size: 11)).foregroundStyle(Holo.labelDim)
                .frame(width: 148, alignment: .leading)
            if editing { controllo } else { valore }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // ── Lettura ──
    @ViewBuilder private var valore: some View {
        switch campo {
        case .num(_, let unita, let b):
            testoValore(b.wrappedValue.map { "\(fmt($0))\(unita.isEmpty ? "" : " \(unita)")" })
        case .dec(_, let unita, let b):
            testoValore(b.wrappedValue.map { String(format: "%g %@", $0, unita) })
        case .testo(_, let b), .menu(_, _, let b):
            testoValore(b.wrappedValue?.isEmpty == false ? b.wrappedValue : nil)
        case .si(_, let b):
            if let v = b.wrappedValue {
                HStack(spacing: 4) {
                    Image(systemName: v ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 10))
                    Text(v ? "Sì" : "No").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(v ? Holo.hsl(145, 75, 68) : Holo.subDim)
            } else { testoValore(nil) }
        }
    }

    private func testoValore(_ t: String?) -> some View {
        Text(t ?? "—").font(.system(size: 11.5, weight: t == nil ? .regular : .semibold))
            .foregroundStyle(t == nil ? Holo.labelDim.opacity(0.5) : Holo.text)
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // ── Modifica ──
    @ViewBuilder private var controllo: some View {
        switch campo {
        case .num(_, let unita, let b):
            HStack(spacing: 4) {
                TextField("—", value: b, format: .number).textFieldStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(Holo.text)
                    .frame(width: 66).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0d152c).opacity(0.8)))
                if !unita.isEmpty {
                    Text(unita).font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
                }
            }
        case .dec(_, let unita, let b):
            HStack(spacing: 4) {
                TextField("—", value: b, format: .number).textFieldStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(Holo.text)
                    .frame(width: 66).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0d152c).opacity(0.8)))
                Text(unita).font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
            }
        case .testo(_, let b):
            TextField("—", text: Binding(get: { b.wrappedValue ?? "" },
                                         set: { b.wrappedValue = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Holo.text)
                .frame(maxWidth: 190).padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0d152c).opacity(0.8)))
        case .menu(_, let opzioni, let b):
            Picker("", selection: Binding(get: { b.wrappedValue ?? "" },
                                          set: { b.wrappedValue = $0.isEmpty ? nil : $0 })) {
                Text("—").tag("")
                ForEach(opzioni, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 170)
        case .si(_, let b):
            Picker("", selection: Binding(
                get: { b.wrappedValue == nil ? 0 : (b.wrappedValue! ? 1 : 2) },
                set: { b.wrappedValue = $0 == 0 ? nil : ($0 == 1) })) {
                Text("—").tag(0); Text("Sì").tag(1); Text("No").tag(2)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 118)
        }
    }
}
