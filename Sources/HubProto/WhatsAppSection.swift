import SwiftUI

@MainActor
final class WAModel: ObservableObject {
    let slug: String
    @Published var conversations: [WAConversation] = []
    @Published var contatti: [String: WAContatto] = [:]   // per wa_jid
    @Published var messages: [WAMessage] = []
    @Published var selected: WAConversation?
    @Published var loading = true
    @Published var error: String?

    init(slug: String) { self.slug = slug }

    func load() async {
        do {
            async let conv = HubAPI.listWAConversations(slug: slug)
            async let cont = HubAPI.listWAContatti(slug: slug)
            conversations = try await conv
            contatti = Dictionary(uniqueKeysWithValues: try await cont.map { ($0.wa_jid, $0) })
            error = nil
            // Se una conversazione è aperta, ricarico anche i suoi messaggi.
            if let sel = selected, let fresh = conversations.first(where: { $0.id == sel.id }) {
                selected = fresh
                await openThread(fresh)
            }
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    func openThread(_ c: WAConversation) async {
        selected = c
        do { messages = try await HubAPI.listWAMessages(conversationId: c.id) }
        catch { self.error = error.localizedDescription }
    }

    /// Subentro manuale: l'agente tace su questa conversazione da qui in poi,
    /// altrimenti tu e lui rispondereste sovrapponendovi.
    func inviaManuale(_ testo: String) async {
        guard let c = selected else { return }
        do {
            try await WABridge.shared.invia(slug: slug, jid: c.wa_jid, testo: testo, conversationId: c.id)
            // Se subentri tu, l'agente si zittisce su QUESTO CONTATTO: altrimenti
            // vi accavallereste, e la scelta deve durare oltre questa chat.
            if agenteAttivo(c) { await setAgente(false, per: c) }
            await load()
        } catch { self.error = "Invio fallito: \(error.localizedDescription)" }
    }

    /// Accende o spegne l'agente per QUESTA persona. La preferenza sta sul
    /// contatto, non sulla conversazione, così resta anche se la chat si azzera.
    func setAgente(_ on: Bool, per c: WAConversation) async {
        do {
            if let contatto = contatti[c.wa_jid] {
                try await HubAPI.setAgenteContatto(id: contatto.id, attivo: on)
            } else {
                // Conversazione più vecchia della tabella contatti: la creo ora.
                try await HubAPI.creaContatto(slug: slug, jid: c.wa_jid,
                                              nome: c.customer_name, telefono: c.phone, attivo: on)
            }
            // Allineo anche la conversazione, così la vista resta coerente.
            try? await HubAPI.updateWAConversation(id: c.id, fields: ["agent_enabled": on])
            await load()
        } catch { self.error = "Non riesco a cambiare la gestione: \(error.localizedDescription)" }
    }

    /// Chi risponde a questo contatto: l'agente o tu.
    func agenteAttivo(_ c: WAConversation) -> Bool {
        contatti[c.wa_jid]?.agente_attivo ?? c.agent_enabled
    }
}

// ─── Sezione WhatsApp: elenco conversazioni + thread ─────────────────────────
struct WhatsAppSection: View {
    let slug: String
    @StateObject private var model: WAModel
    @State private var bozza = ""
    @State private var search = ""
    @State private var mostraRubrica = false

    init(slug: String) {
        self.slug = slug
        _model = StateObject(wrappedValue: WAModel(slug: slug))
    }

    private var filtered: [WAConversation] {
        guard !search.isEmpty else { return model.conversations }
        return model.conversations.filter {
            [$0.titolo, $0.phone ?? "", $0.summary ?? ""].joined(separator: " ")
                .localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 30)
            } else if let e = model.error {
                GlassCard { Text("Errore: \(e)").font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: 0xffb3ad)).padding(16) }
            } else if model.conversations.isEmpty {
                vuoto
            } else {
                HStack(alignment: .top, spacing: 12) {
                    lista.frame(width: 260)
                    thread.frame(maxWidth: .infinity)
                }
                .frame(height: 420)
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $mostraRubrica) {
            ContattiSheet(slug: slug) {
                mostraRubrica = false
                Task { await model.load() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "message.fill").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Holo.hsl(140, 70, 60))
            Text("WHATSAPP").font(.system(size: 13, weight: .heavy)).tracking(3)
                .foregroundStyle(Holo.titleText)
            Text("\(model.conversations.count)")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Holo.labelDim)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            Spacer()
            if !model.conversations.isEmpty {
                HoloSearchField(placeholder: "Cerca…", text: $search, width: 130)
            }

            // Rubrica del numero di QUESTO progetto: si apre di fianco alle
            // conversazioni a cui si riferisce, così non c'è modo di cambiare
            // per sbaglio i contatti dell'altro numero.
            Button { mostraRubrica = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill").font(.system(size: 10, weight: .bold))
                    Text("Rubrica").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Holo.hsl(210, 90, 74))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Holo.hsl(210, 90, 65).opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Scegli a quali contatti risponde l'agente e a quali rispondi tu")

            IconButton(icon: "arrow.clockwise", help: "Ricarica conversazioni") { Task { await model.load() } }
        }
    }

    private var vuoto: some View {
        GlassCard {
            VStack(spacing: 6) {
                Image(systemName: "message").font(.system(size: 22)).foregroundStyle(Holo.labelDim.opacity(0.5))
                Text("Nessuna conversazione").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Holo.subDim)
                Text("Compariranno qui appena qualcuno scriverà al numero collegato.")
                    .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }

    private var lista: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(filtered) { c in
                    Button { Task { await model.openThread(c) } } label: { rigaConv(c) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func rigaConv(_ c: WAConversation) -> some View {
        let st = WAStatus.from(c.status)
        let on = model.selected?.id == c.id
        let agente = model.agenteAttivo(c)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(c.titolo).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Holo.titleText).lineLimit(1)
                Spacer(minLength: 4)
                Text(st.label).font(.system(size: 8, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(Holo.hsl(st.hue, 80, 68))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Holo.hsl(st.hue, 80, 60).opacity(0.15)))
            }

            // Chi risponde a questa persona: la scelta più importante della riga,
            // quindi è un comando vero e non un'icona da interpretare.
            Button {
                Task { await model.setAgente(!agente, per: c) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: agente ? "sparkles" : "person.fill")
                        .font(.system(size: 8.5, weight: .bold))
                    Text(agente ? "Risponde l'agente" : "Rispondi tu")
                        .font(.system(size: 9.5, weight: .bold))
                    Spacer(minLength: 0)
                    Text(agente ? "spegni" : "attiva")
                        .font(.system(size: 8.5)).foregroundStyle(Holo.labelDim)
                }
                .foregroundStyle(agente ? Holo.hsl(140, 75, 68) : Holo.hsl(35, 88, 70))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Holo.hsl(agente ? 140 : 35, 70, 50).opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Holo.hsl(agente ? 140 : 35, 70, 60).opacity(0.3), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(agente
                  ? "L'agente risponde da solo a questo contatto. Premi per rispondere tu."
                  : "A questo contatto rispondi tu. Premi per riattivare l'agente.")
            if let s = c.summary, !s.isEmpty {
                Text(s).font(.system(size: 10)).foregroundStyle(Holo.subDim).lineLimit(2)
            } else if let p = c.phone {
                Text(p).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(on ? 0.09 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(on ? Holo.hsl(140, 70, 60).opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var thread: some View {
        GlassCard {
            if let c = model.selected {
                VStack(spacing: 0) {
                    threadHeader(c)
                    Divider().overlay(Color.white.opacity(0.08))
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.messages) { m in bolla(m) }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: model.messages.count) { _, _ in
                            if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                    composer(c)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20)).foregroundStyle(Holo.labelDim.opacity(0.5))
                    Text("Scegli una conversazione").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func threadHeader(_ c: WAConversation) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.titolo).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Holo.titleText)
                Text(c.phone ?? c.wa_jid).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
            }
            Spacer()
            if c.lead_id != nil {
                Text("SCHEDA CREATA").font(.system(size: 8, weight: .heavy)).tracking(1)
                    .foregroundStyle(Color(hex: 0x9af0c5))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Color(hex: 0x34d399).opacity(0.5), lineWidth: 1))
            }
            HStack(spacing: 6) {
                Text(model.agenteAttivo(c) ? "Agente" : "Manuale")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(model.agenteAttivo(c) ? Holo.hsl(140, 75, 68) : Holo.hsl(35, 88, 70))
                Toggle("", isOn: Binding(
                    get: { model.agenteAttivo(c) },
                    set: { v in Task { await model.setAgente(v, per: c) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .tint(Holo.hsl(145, 70, 52))
            }
            .help(model.agenteAttivo(c)
                  ? "L'agente risponde a questo contatto"
                  : "A questo contatto rispondi tu: l'agente resta zitto")
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }

    private func bolla(_ m: WAMessage) -> some View {
        // cliente a sinistra, agente e umano a destra (colori diversi tra loro)
        let mio = !m.daCliente
        let hue: Double = m.author == "umano" ? 35 : (mio ? 140 : 215)
        return HStack {
            if mio { Spacer(minLength: 40) }
            VStack(alignment: mio ? .trailing : .leading, spacing: 3) {
                Text(m.body).font(.system(size: 11.5)).foregroundStyle(Holo.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(mio ? .trailing : .leading)
                Text(m.author.capitalized).font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Holo.hsl(hue, 70, 65).opacity(0.8))
            }
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 10).fill(Holo.hsl(hue, 60, 50).opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Holo.hsl(hue, 70, 60).opacity(0.25), lineWidth: 1))
            if !mio { Spacer(minLength: 40) }
        }
        .id(m.id)
    }

    private func composer(_ c: WAConversation) -> some View {
        HStack(spacing: 8) {
            TextField("Scrivi tu al cliente…", text: $bozza, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Holo.text)
                .lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x0d152c).opacity(0.7)))
                .onSubmit { invia() }

            Button { invia() } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0b1020))
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Capsule().fill(Holo.hsl(140, 70, 60)))
            }
            .buttonStyle(.plain)
            .disabled(bozza.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
        .overlay(alignment: .top) {
            if model.agenteAttivo(c) {
                Text("Se scrivi, l'agente smette di rispondere a questo contatto")
                    .font(.system(size: 9)).foregroundStyle(Holo.labelDim.opacity(0.8))
                    .offset(y: -1)
            }
        }
    }

    private func invia() {
        let t = bozza.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        bozza = ""
        Task { await model.inviaManuale(t) }
    }
}
