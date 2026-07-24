import SwiftUI
import UserNotifications

// ============================================================================
// Scheda contatto, ricorrenze e form — la parte "anagrafica" della sezione
// Contatti (l'elenco sta in ContattiView.swift).
// ============================================================================

// ── Ricorrenze: calcoli di data e avviso di sistema ─────────────────────────
enum Ricorrenze {
    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let leggibile: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMMM yyyy"; return f
    }()
    private static let giornoMese: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "d MMM"; return f
    }()

    static func data(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: String(s.prefix(10)))
    }
    static func testoData(_ s: String?) -> String? {
        guard let d = data(s) else { return nil }
        return leggibile.string(from: d)
    }
    /// "24 lug" accanto al nome, solo se il compleanno è entro un mese.
    static func compleannoBreve(_ nascita: String?) -> String? {
        guard let d = data(nascita), let g = giorniAlCompleanno(d), g <= 30 else { return nil }
        return g == 0 ? "oggi" : giornoMese.string(from: prossimoCompleanno(d) ?? d)
    }
    static func eta(_ nascita: String?) -> Int? {
        guard let d = data(nascita) else { return nil }
        return Calendar.current.dateComponents([.year], from: d, to: Date()).year
    }

    private static func prossimoCompleanno(_ nascita: Date) -> Date? {
        let cal = Calendar.current
        let oggi = cal.startOfDay(for: Date())
        var comp = cal.dateComponents([.month, .day], from: nascita)
        comp.year = cal.component(.year, from: oggi)
        guard var prossimo = cal.date(from: comp) else { return nil }
        if prossimo < oggi {
            comp.year! += 1
            prossimo = cal.date(from: comp) ?? prossimo
        }
        return prossimo
    }
    private static func giorniAlCompleanno(_ nascita: Date) -> Int? {
        guard let p = prossimoCompleanno(nascita) else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: p).day
    }

    /// Giorni a Natale: la ricorrenza collettiva, sempre in fondo alla sezione.
    static var giorniANatale: Int {
        let cal = Calendar.current
        let oggi = cal.startOfDay(for: Date())
        var comp = DateComponents(year: cal.component(.year, from: oggi), month: 12, day: 25)
        var natale = cal.date(from: comp) ?? oggi
        if natale < oggi { comp.year! += 1; natale = cal.date(from: comp) ?? natale }
        return cal.dateComponents([.day], from: oggi, to: natale).day ?? 0
    }

    // ── Notifica di sistema ──
    // Chiesto una volta sola; se l'utente nega, la sezione Ricorrenze continua
    // a funzionare — l'avviso è un extra, non l'unico canale.
    static func chiediPermesso() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Un avviso al giorno, per i compleanni di oggi. La data dell'ultimo
    /// avviso sta nei UserDefaults: senza, riaprendo l'app arriverebbe una
    /// notifica ogni volta.
    static func avvisaSeOggi(_ compleanni: [Compleanno]) {
        let oggi = compleanni.filter { $0.giorni_mancanti == 0 }
        guard !oggi.isEmpty else { return }

        let chiave = "ultimo_avviso_compleanni"
        let oggiISO = iso.string(from: Date())
        guard UserDefaults.standard.string(forKey: chiave) != oggiISO else { return }
        UserDefaults.standard.set(oggiISO, forKey: chiave)

        let nomi = oggi.map(\.ragione_sociale).joined(separator: ", ")
        let contenuto = UNMutableNotificationContent()
        contenuto.title = oggi.count == 1 ? "Oggi è il compleanno di \(nomi)" : "Compleanni di oggi"
        contenuto.body = oggi.count == 1 ? "Compie \(oggi[0].eta) anni — mandagli gli auguri." : nomi
        contenuto.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "compleanni-\(oggiISO)", content: contenuto, trigger: nil))
    }
}

// ── Sezione Ricorrenze ───────────────────────────────────────────────────────
struct RicorrenzeView: View {
    let compleanni: [Compleanno]
    let contatti: [Contatto]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if compleanni.isEmpty {
                VStack(spacing: 5) {
                    Text("Nessun compleanno nei prossimi 30 giorni")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text)
                    Text("Compila la data di nascita nella scheda di un contatto per vederlo qui.")
                        .font(.system(size: 10.5)).foregroundStyle(UI.faint)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                VStack(spacing: 6) {
                    ForEach(compleanni) { c in rigaCompleanno(c) }
                }
            }

            // Natale: una riga sempre presente, con il conto alla rovescia.
            HStack(spacing: 10) {
                Image(systemName: "snowflake").font(.system(size: 13)).foregroundStyle(UI.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auguri di Natale").font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.ink)
                    Text(Ricorrenze.giorniANatale == 0
                         ? "È oggi: \(contatti.count) contatti da salutare."
                         : "Fra \(Ricorrenze.giorniANatale) giorni · \(contatti.count) contatti in rubrica")
                        .font(.system(size: 10.5)).foregroundStyle(UI.faint)
                }
                Spacer()
                if Ricorrenze.giorniANatale <= 30 {
                    StatusPill(label: "in arrivo", tint: UI.tint(.attesa))
                }
            }
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
        }
    }

    private func rigaCompleanno(_ c: Compleanno) -> some View {
        HStack(spacing: 10) {
            Avatar(nome: c.ragione_sociale)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.ragione_sociale).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink)
                    StatusPill(label: c.giorni_mancanti == 0 ? "oggi"
                               : c.giorni_mancanti == 1 ? "domani"
                               : "fra \(c.giorni_mancanti) giorni",
                               tint: c.giorni_mancanti <= 1 ? UI.tint(.attesa) : UI.tint(.neutro))
                }
                Text("compie \(c.eta) anni · \(Ricorrenze.testoData(c.compleanno) ?? "")")
                    .font(.system(size: 10.5)).foregroundStyle(UI.faint)
            }
            Spacer()
            // Gli auguri li scrivi tu: qui c'è solo la scorciatoia per aprire la chat.
            if let tel = c.telefono, let url = waURL(tel) {
                Link(destination: url) {
                    Label("WhatsApp", systemImage: "message")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(UI.text)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(UI.surfaceHi))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(c.giorni_mancanti <= 1 ? UI.accent.opacity(0.10) : UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(c.giorni_mancanti <= 1 ? UI.accent.opacity(0.4) : UI.line, lineWidth: 1))
    }

    private func waURL(_ tel: String) -> URL? {
        let n = tel.filter(\.isNumber)
        return n.isEmpty ? nil : URL(string: "https://wa.me/\(n)")
    }
}

// ── Scheda contatto ──────────────────────────────────────────────────────────
struct SchedaContattoView: View {
    let contatto: Contatto
    let onEdit: () -> Void
    let onClose: () -> Void

    @State private var transazioni: [TransazioneContatto] = []
    @State private var caricando = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(nome: contatto.ragione_sociale, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(contatto.ragione_sociale)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(UI.ink)
                    HStack(spacing: 6) {
                        StatusPill(label: contatto.isAzienda ? "Azienda" : "Privato")
                        if contatto.source == "lead" { StatusPill(label: "Da lead", tint: UI.tint(.ok)) }
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.dim)
                        .frame(width: 28, height: 28).background(Circle().fill(UI.surface))
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 46, leading: 22, bottom: 16, trailing: 20))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    sezione("CONTATTI") {
                        VStack(alignment: .leading, spacing: 8) {
                            riga("envelope.fill", contatto.email ?? "—")
                            riga("phone.fill", contatto.telefono ?? "—")
                            if let c = contatto.comune, !c.isEmpty { riga("mappin.and.ellipse", c) }
                            if let i = contatto.indirizzo, !i.isEmpty { riga("house", i) }
                            if let p = contatto.piva, !p.isEmpty { riga("number", "P.IVA \(p)") }
                        }
                    }

                    sezione("ANAGRAFICA") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let n = Ricorrenze.testoData(contatto.data_nascita) {
                                riga("gift", "\(n)" + (Ricorrenze.eta(contatto.data_nascita).map { " · \($0) anni" } ?? ""))
                            } else {
                                riga("gift", "data di nascita non inserita")
                            }
                            if let l = contatto.lingua, !l.isEmpty { riga("globe", l.uppercased()) }
                            riga("calendar.badge.plus", "in rubrica dal " + (Ricorrenze.testoData(contatto.created_at) ?? "—"))
                        }
                    }

                    sezione("STORICO TRANSAZIONI") {
                        if caricando {
                            ProgressView().controlSize(.small)
                        } else if transazioni.isEmpty {
                            Text("Nessuna transazione registrata. Si popola dallo storico di una proprietà, indicando questo contatto come controparte.")
                                .font(.system(size: 11)).foregroundStyle(UI.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(spacing: 6) { ForEach(transazioni) { t in rigaTransazione(t) } }
                        }
                    }

                    if let n = contatto.note, !n.isEmpty {
                        sezione("NOTE") {
                            Text(n).font(.system(size: 12)).lineSpacing(3).foregroundStyle(UI.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }

            HStack(spacing: 10) {
                if let tel = contatto.telefono, let url = waURL(tel) {
                    Link(destination: url) {
                        azione("WhatsApp", "message.fill")
                    }.buttonStyle(.plain)
                }
                if let mail = contatto.email, !mail.isEmpty, let url = URL(string: "mailto:\(mail)") {
                    Link(destination: url) { azione("Email", "envelope.fill") }.buttonStyle(.plain)
                }
                GhostButton(label: "Modifica", icon: "pencil", action: onEdit)
            }
            .padding(EdgeInsets(top: 12, leading: 22, bottom: 18, trailing: 22))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UI.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(UI.line), alignment: .leading)
        .ignoresSafeArea()
        .task {
            caricando = true
            transazioni = (try? await HubAPI.transazioniContatto(clienteId: contatto.id)) ?? []
            caricando = false
        }
    }

    private func rigaTransazione(_ t: TransazioneContatto) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.proprieta?.title ?? t.proprieta?.reference ?? "Proprietà")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(UI.ink).lineLimit(1)
                HStack(spacing: 6) {
                    if let e = t.event_type { StatusPill(label: e.capitalized) }
                    if let d = Ricorrenze.testoData(t.event_date) {
                        Text(d).font(.system(size: 10)).foregroundStyle(UI.faint)
                    }
                }
            }
            Spacer()
            if let p = t.price { Text(LeadFmt.euro(p)).font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text) }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
    }

    private func azione(_ label: String, _ icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.text)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
    }
    private func sezione<C: View>(_ titolo: String, @ViewBuilder _ contenuto: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(titolo).font(.system(size: 9.5, weight: .bold)).tracking(1.4).foregroundStyle(UI.dim)
            contenuto()
        }
    }
    private func riga(_ icon: String, _ testo: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(UI.faint).frame(width: 16)
            Text(testo).font(.system(size: 12.5)).foregroundStyle(UI.text).textSelection(.enabled)
        }
    }
    private func waURL(_ tel: String) -> URL? {
        let n = tel.filter(\.isNumber)
        return n.isEmpty ? nil : URL(string: "https://wa.me/\(n)")
    }
}

// ── Form contatto ────────────────────────────────────────────────────────────
struct ContattoFormView: View {
    let existing: Contatto?
    /// Agenzia a cui il contatto appartiene: la porta la vista che apre il form.
    var slug: String = "gz-ibiza"
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var ragioneSociale = ""
    @State private var tipo = "privato"
    @State private var nome = ""; @State private var cognome = ""
    @State private var dataNascita = ""          // gg/mm/aaaa, come lo scrivi a mano
    @State private var email = ""; @State private var telefono = ""
    @State private var comune = ""; @State private var indirizzo = ""; @State private var piva = ""
    @State private var lingua = ""; @State private var note = ""
    @State private var saving = false
    @State private var errore: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Nuovo contatto" : "Modifica contatto")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.ink)
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 13) {
                    scelta("Tipo", [("privato", "Privato"), ("azienda", "Azienda")], tipo) { tipo = $0 }
                    campo("Nome mostrato", $ragioneSociale, tipo == "azienda" ? "Es. Acme SL" : "Es. Mario Rossi")
                    if tipo == "privato" {
                        HStack(spacing: 12) { campo("Nome", $nome, "Mario"); campo("Cognome", $cognome, "Rossi") }
                        HStack(spacing: 12) {
                            campo("Data di nascita", $dataNascita, "gg/mm/aaaa")
                            campo("Lingua", $lingua, "it · es · en")
                        }
                    } else {
                        HStack(spacing: 12) { campo("P.IVA", $piva, "B12345678"); campo("Lingua", $lingua, "it · es · en") }
                    }
                    HStack(spacing: 12) { campo("Email", $email, "nome@email.com"); campo("Telefono", $telefono, "+34 …") }
                    HStack(spacing: 12) { campo("Comune", $comune, "Ibiza"); campo("Indirizzo", $indirizzo, "Calle …") }
                    campoLungo("Note", $note)
                    if let e = errore { Text(e).font(.system(size: 11)).foregroundStyle(UI.tint(.stop)) }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }

            HStack(spacing: 10) {
                Spacer()
                GhostButton(label: "Annulla") { dismiss() }
                Button { salva() } label: {
                    Text(saving ? "Salvataggio…" : "Salva")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.ink)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(UI.accent.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .disabled(saving || ragioneSociale.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 20, trailing: 24))
        }
        .frame(width: 580, height: 640)
        .background(UI.panel)
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let c = existing else { return }
        ragioneSociale = c.ragione_sociale; tipo = c.tipo ?? "privato"
        nome = c.nome ?? ""; cognome = c.cognome ?? ""
        dataNascita = Self.aFormatoItaliano(c.data_nascita)
        email = c.email ?? ""; telefono = c.telefono ?? ""
        comune = c.comune ?? ""; indirizzo = c.indirizzo ?? ""; piva = c.piva ?? ""
        lingua = c.lingua ?? ""; note = c.note ?? ""
    }

    /// "1985-07-24" → "24/07/1985"
    private static func aFormatoItaliano(_ iso: String?) -> String {
        guard let iso, iso.count >= 10 else { return "" }
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3 else { return "" }
        return "\(p[2])/\(p[1])/\(p[0])"
    }
    /// "24/07/1985" → "1985-07-24". nil se non è una data valida: meglio non
    /// salvare niente che salvare un compleanno sbagliato.
    private static func aISO(_ testo: String) -> String? {
        let p = testo.trimmingCharacters(in: .whitespaces).split(whereSeparator: { "/-.".contains($0) })
        guard p.count == 3, let g = Int(p[0]), let m = Int(p[1]), let a = Int(p[2]),
              (1...31).contains(g), (1...12).contains(m), (1900...2100).contains(a) else { return nil }
        return String(format: "%04d-%02d-%02d", a, m, g)
    }

    private func salva() {
        saving = true; errore = nil
        let nascita = dataNascita.trimmingCharacters(in: .whitespaces)
        if !nascita.isEmpty && Self.aISO(nascita) == nil {
            errore = "Data di nascita non valida: usa gg/mm/aaaa."
            saving = false
            return
        }
        var campi: [String: Any?] = [
            "ragione_sociale": ragioneSociale.trimmingCharacters(in: .whitespaces),
            "tipo": tipo,
            "nome": vuotoNil(nome), "cognome": vuotoNil(cognome),
            "data_nascita": nascita.isEmpty ? nil : Self.aISO(nascita),
            "email": vuotoNil(email), "telefono": vuotoNil(telefono),
            "comune": vuotoNil(comune), "indirizzo": vuotoNil(indirizzo),
            "lingua": vuotoNil(lingua), "note": vuotoNil(note),
        ]
        if tipo == "azienda" { campi["piva"] = vuotoNil(piva) }
        if existing == nil { campi["source"] = "manuale"; campi["project_slug"] = slug }
        let daSalvare = campi
        Task {
            do {
                if let c = existing { try await HubAPI.updateContatto(id: c.id, fields: daSalvare) }
                else { try await HubAPI.createContatto(daSalvare) }
                await onSaved()
                dismiss()
            } catch {
                errore = error.localizedDescription
                saving = false
            }
        }
    }
    private func vuotoNil(_ s: String) -> String? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines); return v.isEmpty ? nil : v
    }

    private func campo(_ label: String, _ text: Binding<String>, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.faint)
            TextField(hint, text: text)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UI.text)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func campoLungo(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.faint)
            TextEditor(text: text)
                .font(.system(size: 12.5)).foregroundStyle(UI.text)
                .scrollContentBackground(.hidden).background(Color.clear)
                .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                .frame(height: 70)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }
    private func scelta(_ label: String, _ opts: [(String, String)], _ sel: String,
                        _ onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.faint)
            HStack(spacing: 5) {
                ForEach(opts, id: \.0) { o in
                    FilterChip(label: o.1, selected: o.0 == sel) { onPick(o.0) }
                }
            }
        }
    }
}
