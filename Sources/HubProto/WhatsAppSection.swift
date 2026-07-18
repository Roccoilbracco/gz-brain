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
                                              nome: c.customer_name, telefono: c.telefono, attivo: on)
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
        SectionCard(title: "WhatsApp", count: model.conversations.count, icon: "message") {
            HStack(spacing: 6) {
                if !model.conversations.isEmpty {
                    HoloSearchField(placeholder: "Cerca…", text: $search, width: 130)
                }
                GhostButton(label: "Rubrica", icon: "person.2") { mostraRubrica = true }
                GhostButton(label: "Aggiorna", icon: "arrow.clockwise") { Task { await model.load() } }
            }
        } content: {
            if model.loading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 30)
            } else if let e = model.error {
                Text("Errore: \(e)").font(.system(size: 11.5)).foregroundStyle(UI.tint(.stop))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.conversations.isEmpty {
                vuoto
            } else {
                HStack(alignment: .top, spacing: 12) {
                    lista.frame(width: 272)
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

    private var vuoto: some View {
        VStack(spacing: 5) {
            Image(systemName: "message").font(.system(size: 20)).foregroundStyle(UI.faint)
            Text("Nessuna conversazione").font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text)
            Text("Compariranno qui appena qualcuno scriverà al numero collegato.")
                .font(.system(size: 10.5)).foregroundStyle(UI.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
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

    /// Riga conversazione: avatar, nome, stato, anteprima. Chi risponde è
    /// un'etichetta piccola con un comando esplicito, non più un blocco colorato
    /// che pesava quanto il nome della persona.
    private func rigaConv(_ c: WAConversation) -> some View {
        let st = WAStatus.from(c.status)
        let on = model.selected?.id == c.id
        let agente = model.agenteAttivo(c)
        return HStack(alignment: .top, spacing: 9) {
            Avatar(nome: c.titolo)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.titolo).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UI.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if st != .attiva {
                        StatusPill(label: st.label, tint: UI.tint(st == .escalata ? .attesa : .ok))
                    }
                }

                if let s = c.summary, !s.isEmpty {
                    Text(s).font(.system(size: 10.5)).foregroundStyle(UI.dim).lineLimit(2)
                } else if let p = c.telefono {
                    Text(p).font(.system(size: 10.5)).foregroundStyle(UI.faint).monospacedDigit()
                }

                HStack(spacing: 5) {
                    Image(systemName: agente ? "sparkles" : "person.fill")
                        .font(.system(size: 8)).foregroundStyle(UI.faint)
                    Text(agente ? "Agente" : "Rispondi tu")
                        .font(.system(size: 9.5)).foregroundStyle(UI.faint)
                    Button { Task { await model.setAgente(!agente, per: c) } } label: {
                        Text(agente ? "disattiva" : "attiva")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(UI.accent)
                    }
                    .buttonStyle(.plain)
                    .help(agente
                          ? "L'agente risponde da solo a questo contatto. Premi per rispondere tu."
                          : "A questo contatto rispondi tu. Premi per riattivare l'agente.")
                }
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? UI.surfaceHi : UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(on ? UI.accent.opacity(0.55) : UI.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var thread: some View {
        VStack(spacing: 0) {
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
                        .font(.system(size: 20)).foregroundStyle(UI.faint.opacity(0.5))
                    Text("Scegli una conversazione").font(.system(size: 12)).foregroundStyle(UI.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UI.line, lineWidth: 1))
    }

    private func threadHeader(_ c: WAConversation) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.titolo).font(.system(size: 12.5, weight: .bold)).foregroundStyle(UI.ink)
                // Senza numero (chat via LID) non mostriamo l'identificatore:
                // sarebbero cifre inutili al posto di un dato utile.
                if let tel = c.telefono {
                    Text(tel).font(.system(size: 10)).foregroundStyle(UI.faint).monospacedDigit()
                } else {
                    Text("numero non condiviso").font(.system(size: 10)).foregroundStyle(UI.faint)
                }
            }
            Spacer()
            if c.lead_id != nil {
                Text("SCHEDA CREATA").font(.system(size: 8, weight: .heavy)).tracking(1)
                    .foregroundStyle(UI.tint(.ok))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(UI.tint(.ok).opacity(0.5), lineWidth: 1))
            }
            HStack(spacing: 6) {
                Text(model.agenteAttivo(c) ? "Agente" : "Manuale")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(model.agenteAttivo(c) ? UI.tint(.ok) : UI.tint(.attesa))
                Toggle("", isOn: Binding(
                    get: { model.agenteAttivo(c) },
                    set: { v in Task { await model.setAgente(v, per: c) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .tint(UI.accent)
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
                Text(m.body).font(.system(size: 11.5)).foregroundStyle(UI.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(mio ? .trailing : .leading)
                Text(m.author.capitalized).font(.system(size: 8, weight: .bold))
                    .foregroundStyle(UI.faint)
            }
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 9).fill(UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(UI.line, lineWidth: 1))
            if !mio { Spacer(minLength: 40) }
        }
        .id(m.id)
    }

    private func composer(_ c: WAConversation) -> some View {
        HStack(spacing: 8) {
            TextField("Scrivi tu al cliente…", text: $bozza, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(UI.text)
                .lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
                .onSubmit { invia() }

            Button { invia() } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(UI.ink)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Capsule().fill(UI.accent))
            }
            .buttonStyle(.plain)
            .disabled(bozza.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
        .overlay(alignment: .top) {
            if model.agenteAttivo(c) {
                Text("Se scrivi, l'agente smette di rispondere a questo contatto")
                    .font(.system(size: 9)).foregroundStyle(UI.faint.opacity(0.8))
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
