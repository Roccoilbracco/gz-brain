import SwiftUI

/// Modelli proposti, dal più economico al più capace. `costo` e `resa` sono
/// indicatori relativi da 1 a 3: servono a far scegliere a colpo d'occhio senza
/// dover conoscere i listini.
private struct ModelloOpt: Identifiable {
    let id: String
    let label: String
    let tagline: String
    let costo: Int
    let resa: Int
    let hue: Double
}

private let MODELLI: [ModelloOpt] = [
    .init(id: "claude-haiku-4-5", label: "Haiku 4.5",
          tagline: "Il più rapido e leggero. Regge bene le conversazioni semplici.",
          costo: 1, resa: 2, hue: 150),
    .init(id: "claude-sonnet-5", label: "Sonnet 5",
          tagline: "L'equilibrio giusto: segue il copione senza sbavature, costa poco.",
          costo: 2, resa: 3, hue: 205),
    .init(id: "claude-opus-4-8", label: "Opus 4.8",
          tagline: "Il più capace, ma più lento e caro del necessario qui.",
          costo: 3, resa: 3, hue: 275),
]

// ─── Pannello impostazioni agente (bottone "Agente" nelle dash) ──────────────
struct AgenteSheet: View {
    let slug: String
    var onClose: () -> Void

    @State private var agent: WAAgent?
    @State private var prompt = ""
    @State private var knowledge = ""
    @State private var greeting = ""
    @State private var modello = "claude-sonnet-5"
    @State private var maxMsg = 20
    @State private var keywords = ""
    @State private var enabled = false
    @State private var linkAnnunci = ""

    @State private var qr: String?
    @State private var connesso = false
    @State private var numero: String?
    @State private var ponteErr: WABridge.Errore?
    @State private var pontePronto = false
    @State private var collegando = false
    @State private var chiedeScollega = false

    @State private var loading = true
    @State private var saving = false
    @State private var errore: String?
    @State private var salvato = false

    var body: some View {
        ZStack {
            // Sfondo a due strati come il resto dell'app: blu profondo + alone.
            Color(hex: 0x070a14).ignoresSafeArea()
            RadialGradient(colors: [Holo.hsl(210, 90, 50).opacity(0.16), .clear],
                           center: .top, startRadius: 5, endRadius: 520)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                bordo

                if loading {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            if let errore {
                                avviso(errore, hue: 5, icona: "exclamationmark.triangle.fill")
                            }
                            statoBlocco
                            modelloBlocco
                            messaggiBlocco
                            conoscenzaBlocco
                            limitiBlocco
                        }
                        .padding(EdgeInsets(top: 20, leading: 22, bottom: 26, trailing: 22))
                    }
                }

                bordo
                footer
            }
        }
        .frame(width: 700, height: 760)
        .alert("Scollegare il numero?", isPresented: $chiedeScollega) {
            Button("Annulla", role: .cancel) { }
            Button("Scollega", role: .destructive) { Task { await scollega() } }
        } message: {
            Text("Il numero \(numero.map { "+\($0)" } ?? "") verrà disconnesso e sparirà dai dispositivi collegati sul telefono. L'agente smetterà di ricevere e rispondere finché non riscansioni il QR.\n\nLe conversazioni, i lead e le visite restano: si perde solo il collegamento.")
        }
        .task {
            await load()
            // La scansione avviene sul telefono: l'app non può esserne avvisata,
            // deve chiedere. Sondo spesso mentre aspetto il collegamento, poi
            // rallento a controllo di cortesia una volta connesso.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(connesso ? 15 : 3))
                if Task.isCancelled { break }
                await aggiornaPonte()
            }
        }
    }

    private var bordo: some View {
        Rectangle().fill(Holo.cardBorder.opacity(0.5)).frame(height: 1)
    }

    // ── Testata ──────────────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Holo.hsl(140, 70, 50).opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "sparkles").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Holo.hsl(140, 75, 65))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AGENTE WHATSAPP")
                    .font(.system(size: 14, weight: .heavy)).tracking(4)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Holo.hsl(210, 90, 60).opacity(0.6), radius: 8)
                Text(agent?.display_name ?? slug)
                    .font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
            Spacer()
            IconButton(icon: "xmark", help: "Chiudi", action: onClose)
        }
        .padding(EdgeInsets(top: 16, leading: 22, bottom: 14, trailing: 16))
    }

    // ── Stato: due tessere affiancate ───────────────────────────────────────
    private var statoBlocco: some View {
        VStack(alignment: .leading, spacing: 10) {
            titoloSezione("STATO", "Chi risponde, e da quale numero")

            HStack(spacing: 10) {
                tessera(
                    acceso: enabled,
                    hue: 140,
                    titolo: enabled ? "Agente attivo" : "Agente spento",
                    sotto: enabled
                        ? "Risponde da solo a chi scrive."
                        : "I messaggi si salvano lo stesso: rispondi tu."
                ) {
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        // Verde: qui l'interruttore dice "acceso/spento", e il
                        // verde è lo stesso che segna l'agente attivo altrove.
                        .tint(Holo.hsl(145, 70, 52))
                }

                tessera(
                    acceso: connesso,
                    hue: connesso ? 140 : (ponteErr == nil ? 35 : 250),
                    titolo: titoloNumero,
                    sotto: sottoNumero
                ) {
                    // Senza servizio attivo non c'è nulla da collegare: nascondo
                    // il bottone invece di offrire un'azione che fallirebbe.
                    if pontePronto {
                        // Collegato → l'unica azione sensata è scollegare: un
                        // "ricollega" con le credenziali salvate si riconnette
                        // in silenzio e il QR non compare mai.
                        if connesso {
                            Button { chiedeScollega = true } label: {
                                Text(collegando ? "Attendo…" : "Scollega")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Holo.hsl(5, 85, 72))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .overlay(Capsule().strokeBorder(Holo.hsl(5, 80, 65).opacity(0.45), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(collegando)
                        } else {
                            Button { Task { await collega() } } label: {
                                Text(collegando ? "Attendo…" : "Collega")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Holo.hsl(205, 90, 74))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .overlay(Capsule().strokeBorder(Holo.hsl(205, 90, 65).opacity(0.45), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(collegando)
                        }
                    } else {
                        Text("IN ATTESA").font(.system(size: 8.5, weight: .heavy)).tracking(1)
                            .foregroundStyle(Holo.labelDim)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.05)))
                    }
                }
            }

            if let qr, let img = immagineQR(qr) {
                HStack(spacing: 16) {
                    Image(nsImage: img).resizable().interpolation(.none)
                        .frame(width: 168, height: 168)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("COLLEGA IL NUMERO").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Holo.hsl(140, 70, 65))
                        ForEach(Array([
                            "Apri WhatsApp sul telefono dell'agenzia",
                            "Impostazioni → Dispositivi collegati",
                            "Collega dispositivo, poi inquadra questo codice",
                        ].enumerated()), id: \.offset) { i, riga in
                            HStack(alignment: .top, spacing: 7) {
                                Text("\(i + 1)").font(.system(size: 9, weight: .black))
                                    .foregroundStyle(Holo.hsl(140, 70, 65))
                                    .frame(width: 15, height: 15)
                                    .background(Circle().fill(Holo.hsl(140, 70, 50).opacity(0.2)))
                                Text(riga).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                            }
                        }
                        Text("Il codice scade dopo qualche secondo: se non fai in tempo, premi Ricollega.")
                            .font(.system(size: 9.5)).foregroundStyle(Holo.labelDim).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(pannello)
            }
        }
    }

    private var titoloNumero: String {
        if connesso { return "Numero collegato" }
        if let e = ponteErr { return e.errorDescription ?? "Servizio non disponibile" }
        return "Numero non collegato"
    }

    private var sottoNumero: String {
        if connesso, let n = numero { return "+\(n)" }
        if let e = ponteErr { return e.rimedio }
        return "Premi Collega e inquadra il QR col telefono dell'agenzia."
    }

    private func tessera<T: View>(acceso: Bool, hue: Double, titolo: String, sotto: String,
                                  @ViewBuilder controllo: () -> T) -> some View {
        HStack(spacing: 10) {
            Circle().fill(acceso ? Holo.hsl(hue, 75, 58) : Color(hex: 0x59617a))
                .frame(width: 8, height: 8)
                .shadow(color: acceso ? Holo.hsl(hue, 75, 58) : .clear, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(titolo).font(.system(size: 12, weight: .bold)).foregroundStyle(Holo.titleText)
                Text(sotto).font(.system(size: 10)).foregroundStyle(Holo.subDim)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            controllo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 12))
        .background(pannello)
    }

    // ── Modello: tre schede, niente segmented di sistema ────────────────────
    private var modelloBlocco: some View {
        VStack(alignment: .leading, spacing: 10) {
            titoloSezione("MODELLO", "Quanto deve essere sveglio l'agente")
            HStack(spacing: 10) {
                ForEach(MODELLI) { m in schedaModello(m) }
            }
        }
    }

    private func schedaModello(_ m: ModelloOpt) -> some View {
        let on = modello == m.id
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { modello = m.id }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    Text(m.label).font(.system(size: 12.5, weight: .heavy))
                        .foregroundStyle(on ? Holo.titleText : Holo.text.opacity(0.75))
                    Spacer(minLength: 2)
                    if on {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                            .foregroundStyle(Holo.hsl(m.hue, 80, 68))
                    }
                }

                Text(m.tagline)
                    .font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
                    .lineLimit(3, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                misura("COSTO", m.costo, hue: m.hue, on: on)
                misura("RESA", m.resa, hue: m.hue, on: on)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(on ? Holo.hsl(m.hue, 70, 45).opacity(0.16) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                on ? Holo.hsl(m.hue, 80, 62).opacity(0.75) : Color.white.opacity(0.07),
                lineWidth: on ? 1.5 : 1))
            .shadow(color: on ? Holo.hsl(m.hue, 80, 55).opacity(0.35) : .clear, radius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Barrette 1-3: costo e resa a colpo d'occhio, senza numeri da interpretare.
    private func misura(_ label: String, _ n: Int, hue: Double, on: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 8, weight: .heavy)).tracking(1)
                .foregroundStyle(Holo.labelDim.opacity(0.8))
                .lineLimit(1).fixedSize()          // "COSTO" non deve spezzarsi
                .frame(width: 42, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i < n
                              ? (on ? Holo.hsl(hue, 80, 65) : Holo.text.opacity(0.35))
                              : Color.white.opacity(0.08))
                        .frame(width: 14, height: 3.5)
                }
            }
        }
    }

    // ── Messaggi ────────────────────────────────────────────────────────────
    private var messaggiBlocco: some View {
        VStack(alignment: .leading, spacing: 10) {
            titoloSezione("COME PARLA", "Il tono e le regole della conversazione")

            campoEtichettato(
                "Primo messaggio",
                "Come si presenta a chi scrive per la prima volta.",
                $greeting, altezza: 52)

            campoEtichettato(
                "Istruzioni specifiche",
                "Si sommano alle regole di base: qualificare, non inventare immobili, non promettere prezzi.",
                $prompt, altezza: 96)

            Text("Link agli annunci").font(.system(size: 11, weight: .bold))
                .foregroundStyle(Holo.text).padding(.top, 4)
            Text("Indirizzo delle schede sul sito, con \u{7B}ref\u{7D} al posto del riferimento. Es. https://gzibizaproperties.com/propiedad/\u{7B}ref\u{7D} — l'agente manderà quel link a chi chiede le foto. Lascialo vuoto finché il sito non è online: senza, non inventa URL.")
                .font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…/\u{7B}ref\u{7D}", text: $linkAnnunci)
                .textFieldStyle(.plain).font(.system(size: 11).monospaced())
                .foregroundStyle(Holo.text)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 8/255, green: 14/255, blue: 32/255).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Holo.hsl(210, 90, 65).opacity(0.22), lineWidth: 1))
        }
    }

    private var conoscenzaBlocco: some View {
        VStack(alignment: .leading, spacing: 10) {
            titoloSezione("COSA SA", "L'unica fonte da cui può attingere")
            campoEtichettato(
                nil,
                "Orari, zone servite, commissioni, come funziona una visita… Fuori da questo testo l'agente risponde che verifica e fa richiamare un collega.",
                $knowledge, altezza: 140)
        }
    }

    // ── Limiti ──────────────────────────────────────────────────────────────
    private var limitiBlocco: some View {
        VStack(alignment: .leading, spacing: 10) {
            titoloSezione("QUANDO PASSA A TE", "I due freni automatici")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tetto di messaggi").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Holo.text)
                    HStack(spacing: 10) {
                        Text("\(maxMsg)").font(.system(size: 22, weight: .black))
                            .foregroundStyle(Holo.hsl(35, 85, 68))
                            .frame(minWidth: 34, alignment: .leading)
                        Stepper("", value: $maxMsg, in: 5...80).labelsHidden()
                    }
                    Text("Oltre questo numero di sue risposte si ferma e marca la chat da seguire.")
                        .font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(pannello)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Parole che lo fermano").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Holo.text)
                    campoTesto($keywords, altezza: 46)
                    Text("Separate da virgola. Se il cliente le scrive, l'agente tace subito.")
                        .font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(pannello)
            }
        }
    }

    // ── Footer ──────────────────────────────────────────────────────────────
    private var footer: some View {
        HStack(spacing: 12) {
            if salvato {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                    Text("Salvato").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Holo.hsl(150, 70, 68))
                .transition(.opacity)
            }
            Spacer()
            Button("Chiudi", action: onClose)
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Holo.subDim)
            Button { Task { await salva() } } label: {
                Text(saving ? "Salvo…" : "Salva")
                    .font(.system(size: 11.5, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x08130d))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Capsule().fill(Holo.hsl(150, 72, 62)))
                    .shadow(color: Holo.hsl(150, 72, 55).opacity(0.5), radius: 8)
            }
            .buttonStyle(.plain)
            .disabled(saving || loading)
        }
        .padding(EdgeInsets(top: 12, leading: 22, bottom: 14, trailing: 22))
    }

    // ── Pezzi riusabili ─────────────────────────────────────────────────────
    private var pannello: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(red: 14/255, green: 22/255, blue: 46/255).opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func titoloSezione(_ t: String, _ sotto: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 10, weight: .heavy)).tracking(2.5)
                .foregroundStyle(Holo.hsl(210, 90, 72))
            Text(sotto).font(.system(size: 10)).foregroundStyle(Holo.labelDim.opacity(0.8))
        }
    }

    private func avviso(_ testo: String, hue: Double, icona: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icona).font(.system(size: 11)).foregroundStyle(Holo.hsl(hue, 85, 70))
            Text(testo).font(.system(size: 11)).foregroundStyle(Holo.hsl(hue, 60, 82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Holo.hsl(hue, 70, 50).opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Holo.hsl(hue, 70, 60).opacity(0.35), lineWidth: 1))
    }

    private func campoEtichettato(_ titolo: String?, _ aiuto: String,
                                  _ binding: Binding<String>, altezza: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let titolo {
                Text(titolo).font(.system(size: 11, weight: .bold)).foregroundStyle(Holo.text)
            }
            Text(aiuto).font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
                .fixedSize(horizontal: false, vertical: true)
            campoTesto(binding, altezza: altezza)
        }
    }

    private func campoTesto(_ binding: Binding<String>, altezza: CGFloat) -> some View {
        TextEditor(text: binding)
            .font(.system(size: 11.5))
            .foregroundStyle(Holo.text)
            .scrollContentBackground(.hidden)
            .padding(7)
            .frame(height: altezza)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 8/255, green: 14/255, blue: 32/255).opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Holo.hsl(210, 90, 65).opacity(0.22), lineWidth: 1))
    }

    /// Il ponte manda il QR come data URL (`data:image/png;base64,…`).
    private func immagineQR(_ dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }

    // ── Dati ────────────────────────────────────────────────────────────────
    private func load() async {
        do {
            guard let a = try await HubAPI.getWAAgent(slug: slug) else {
                errore = "Nessun agente configurato per \(slug)"; loading = false; return
            }
            agent = a
            prompt = a.system_prompt
            knowledge = a.knowledge
            greeting = a.greeting ?? ""
            modello = MODELLI.contains { $0.id == a.model } ? a.model : "claude-sonnet-5"
            maxMsg = a.max_agent_messages
            keywords = a.escalation_keywords.joined(separator: ", ")
            enabled = a.enabled
            linkAnnunci = a.listing_url_template ?? ""
            connesso = a.connesso
            numero = a.phone_number
        } catch { errore = error.localizedDescription }
        loading = false
        await aggiornaPonte()
    }

    /// Lo stato in DB lo scrive il servizio; qui chiediamo al ponte quello vivo
    /// (incluso il QR). Se il ponte non c'è ancora non è un errore bloccante:
    /// tutto il resto del pannello resta usabile.
    private func aggiornaPonte() async {
        pontePronto = await WABridge.shared.configurato()
        do {
            let s = try await WABridge.shared.stato(slug: slug)
            connesso = s.connected
            qr = s.qr
            if let p = s.phone { numero = p }
            ponteErr = nil
        } catch let e as WABridge.Errore {
            ponteErr = e
        } catch {
            ponteErr = .nonRaggiungibile(error.localizedDescription)
        }
    }

    /// Scollega e riapre: senza credenziali la sessione genera un QR nuovo.
    private func scollega() async {
        collegando = true
        defer { collegando = false }
        do {
            try await WABridge.shared.scollega(slug: slug)
            connesso = false
            numero = nil
            // Il QR impiega qualche secondo a comparire dopo il logout.
            try? await Task.sleep(for: .seconds(4))
            await aggiornaPonte()
        } catch let e as WABridge.Errore {
            ponteErr = e
        } catch {
            ponteErr = .nonRaggiungibile(error.localizedDescription)
        }
    }

    private func collega() async {
        collegando = true
        defer { collegando = false }
        do {
            try await WABridge.shared.riavvia(slug: slug)
            // Il QR impiega un attimo a comparire dopo il riavvio della sessione.
            try? await Task.sleep(for: .seconds(3))
            await aggiornaPonte()
        } catch let e as WABridge.Errore {
            ponteErr = e
        } catch {
            ponteErr = .nonRaggiungibile(error.localizedDescription)
        }
    }

    private func salva() async {
        saving = true
        defer { saving = false }
        let kw = keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        do {
            try await HubAPI.updateWAAgent(slug: slug, fields: [
                "enabled": enabled,
                "model": modello,
                "system_prompt": prompt,
                "knowledge": knowledge,
                "greeting": greeting.isEmpty ? nil : greeting,
                "max_agent_messages": maxMsg,
                "escalation_keywords": kw,
                "listing_url_template": linkAnnunci.trimmingCharacters(in: .whitespaces).isEmpty ? nil : linkAnnunci.trimmingCharacters(in: .whitespaces),
            ])
            errore = nil
            withAnimation { salvato = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { salvato = false }
        } catch { errore = "Salvataggio fallito: \(error.localizedDescription)" }
    }
}
