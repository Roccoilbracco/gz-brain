import SwiftUI
import AppKit
import UniformTypeIdentifiers

// stringa "vuota" → nil, così non scriviamo campi vuoti
private func nz(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

// ─── Campo di input scuro coerente col tema ───
struct HoloField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Color(hex: 0xe8f2ff))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
        }
    }
}

// ─── Form: nuovo cliente (manuale) + opzionale primo progetto ───
struct ClienteFormView: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var ragioneSociale = ""
    @State private var piva = ""
    @State private var indirizzo = ""
    @State private var cap = ""
    @State private var comune = ""
    @State private var provincia = ""
    @State private var email = ""
    @State private var telefono = ""
    @State private var sitoWeb = ""
    @State private var note = ""
    @State private var docs: [URL] = []
    @State private var saving = false
    @State private var errorMsg: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("NUOVO CLIENTE").font(.system(size: 15, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.titleText)

                HoloField(label: "Ragione sociale *", text: $ragioneSociale, placeholder: "Es. Rossi Energia SRL")
                HStack(spacing: 12) {
                    HoloField(label: "P.IVA", text: $piva)
                    HoloField(label: "Telefono", text: $telefono)
                }
                HoloField(label: "Email", text: $email)
                HoloField(label: "Sito web", text: $sitoWeb, placeholder: "Es. www.okenergia.it")
                HoloField(label: "Indirizzo", text: $indirizzo, placeholder: "Es. Via Properzio 5")
                HStack(spacing: 12) {
                    HoloField(label: "CAP", text: $cap, placeholder: "00193").frame(width: 110)
                    HoloField(label: "Comune", text: $comune)
                    HoloField(label: "Provincia", text: $provincia).frame(width: 110)
                }
                HoloField(label: "Note", text: $note)
                DocumentiStaging(docs: $docs)

                if let errorMsg {
                    Text(errorMsg).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad))
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                    Button { save() } label: {
                        Text(saving ? "Salvataggio…" : "Salva cliente")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || nz(ragioneSociale) == nil)
                    .opacity(nz(ragioneSociale) == nil ? 0.5 : 1)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 720)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255),
                                            Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard let rs = nz(ragioneSociale) else { return }
        saving = true; errorMsg = nil
        Task {
            do {
                let cliente = try await HubAPI.createCliente([
                    "ragione_sociale": rs, "piva": nz(piva), "indirizzo": nz(indirizzo),
                    "cap": nz(cap), "comune": nz(comune),
                    "provincia": nz(provincia), "email": nz(email), "telefono": nz(telefono),
                    "sito_web": nz(sitoWeb), "note": nz(note),
                ])
                for url in docs { try await HubAPI.addClienteDocumento(clienteId: cliente.id, fileURL: url) }
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; errorMsg = error.localizedDescription }
            }
        }
    }
}

// placeholder "vuoto" come card (usato dalle sezioni della scheda cliente)
struct EmptyStateCard: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Holo.labelDim.opacity(0.85))
            Text(text).font(.system(size: 12.5)).foregroundStyle(Holo.labelDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30).padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
    }
}

// Bottone-icona uniforme: monocromo, sfondo + leggero scale al passaggio del mouse (animazione)
// ─── Campo ricerca condiviso (stile holo): radius 999 = capsula ───
struct HoloSearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 170
    var radius: CGFloat = 10

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Holo.text).frame(width: width)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: radius).fill(Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.25), lineWidth: 1))
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var danger: Bool = false
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? (danger ? Color(hex: 0xff8f8a) : Color(hex: 0xeaf2ff)) : Holo.subDim)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill((danger ? Color(hex: 0xff8f8a) : Color.white).opacity(hover ? 0.12 : 0)))
                .scaleEffect(hover ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
    }
}

// Bottone "pill" nello stile dei tab del menu (Dash/Code/Boss) — usato per le azioni di sezione
struct MenuPillButton: View {
    let label: String
    var icon: String? = nil
    var disabled: Bool = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Csb.itemFgOn)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabOn.opacity(hover ? 1 : 0.9)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled).opacity(disabled ? 0.45 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
    }
}

// Badge nello stile menu: chrome scuro + bordo sottile, testo (eventuale) in tinta status tenue
struct StatusChip: View {
    let text: String
    var hue: Double? = nil   // nil = neutro
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.8)
            .foregroundStyle(hue == nil ? Csb.itemFg : Holo.hsl(hue!, 60, 72))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Csb.tabsBg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
    }
}

// sezioni della scheda cliente, mostrate una alla volta via menu a tab
private enum ClienteDetailTab: CaseIterable { case documenti, fatture, progetti
    var label: String {
        switch self { case .documenti: return "Documenti"; case .fatture: return "Fatture"; case .progetti: return "Progetti" }
    }
    var icon: String {
        switch self { case .documenti: return "paperclip"; case .fatture: return "doc.text"; case .progetti: return "folder" }
    }
}

// ─── Scheda cliente: anagrafica + menu sezioni (documenti / fatture) ───
struct ClienteDetailView: View {
    let clienteId: String
    @State private var cliente: Cliente?
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var showAddCommessa = false
    @State private var tab: ClienteDetailTab = .documenti

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Button { AppState.shared.route = .clienti } label: {
                    Text("← CLIENTI").font(.system(size: 11)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
                }.buttonStyle(.plain)

                if let errorMsg {
                    GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                } else if let c = cliente {
                    anagrafica(c)
                    sectionTabs
                    switch tab {
                    case .documenti: ClienteDocumentiSection(clienteId: clienteId)
                    case .fatture:   ClienteFattureSection(clienteId: clienteId)
                    case .progetti:  commesseSection(c)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task(id: clienteId) { await load() }
        .sheet(isPresented: $showAddCommessa) {
            CommessaFormView(clienteId: clienteId) { Task { await load() } }
        }
        .sheet(isPresented: $showEdit) {
            if let c = cliente { ClienteEditFormView(cliente: c) { Task { await load() } } }
        }
    }

    private func anagrafica(_ c: Cliente) -> some View {
        let energizzo = c.source == "energizzo"
        let hue: Double = energizzo ? 152 : 217
        let initials = c.ragione_sociale.split(separator: " ").prefix(2)
            .compactMap { $0.first }.map(String.init).joined().uppercased()
        return VStack(alignment: .leading, spacing: 0) {
            // ── testata: monogramma · nome/P.IVA · badge ──
            HStack(spacing: 14) {
                Text(initials.isEmpty ? "—" : initials)
                    .font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Holo.hsl(hue, 55, 42), Holo.hsl(hue, 60, 28)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Holo.hsl(hue, 60, 55).opacity(0.45), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.ragione_sociale).font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Holo.titleText).lineLimit(1)
                    if let piva = c.piva, !piva.isEmpty {
                        Text("P.IVA \(piva)").font(.system(size: 11, weight: .medium)).foregroundStyle(Csb.tagFg)
                    }
                }
                Spacer(minLength: 12)
                StatusChip(text: energizzo ? "Da Energizzo" : "Manuale", hue: energizzo ? 152 : nil)
                Menu {
                    Button { showEdit = true } label: { Label("Modifica dati", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Csb.itemFg)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Csb.tabsBg))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Csb.tabOnBorder, lineWidth: 1))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))

            divider
            // ── record campi: etichetta a sinistra · valore ──
            defRow("INDIRIZZO", { let i = clienteIndirizzoCompleto(c); return i.isEmpty ? "—" : i }(), last: false)
            divider
            defRow("EMAIL", c.email ?? "—", last: false)
            divider
            defRow("TELEFONO", c.telefono ?? "—", last: false)
            if let sito = c.sito_web, !sito.isEmpty {
                divider
                linkRow("SITO WEB", sito)
            }
            if let note = c.note, !note.isEmpty {
                divider
                defRow("NOTE", note, last: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Csb.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Csb.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .confirmationDialog("Eliminare il cliente e tutti i suoi progetti?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { delete() }
            Button("Annulla", role: .cancel) {}
        }
    }
    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }
    private func defRow(_ label: String, _ value: String, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2)
                .foregroundStyle(Csb.secFg).frame(width: 110, alignment: .leading).padding(.top, 1)
            Text(value).font(.system(size: 13)).foregroundStyle(Holo.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18))
    }
    // riga con valore cliccabile (apre l'URL nel browser)
    private func linkRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2)
                .foregroundStyle(Csb.secFg).frame(width: 110, alignment: .leading).padding(.top, 1)
            Button { openWeb(value) } label: {
                Text(value).font(.system(size: 13)).foregroundStyle(Holo.hsl(217, 85, 72)).underline()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18))
    }
    private func openWeb(_ s: String) {
        var str = s.trimmingCharacters(in: .whitespaces)
        if !str.lowercased().hasPrefix("http") { str = "https://" + str }
        if let u = URL(string: str) { NSWorkspace.shared.open(u) }
    }

    // menu a tab sotto la card anagrafica: una sezione alla volta
    private var sectionTabs: some View {
        HStack(spacing: 3) {
            ForEach(ClienteDetailTab.allCases, id: \.self) { t in
                let on = tab == t
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 11, weight: .semibold))
                        Text(t.label).font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .foregroundStyle(on ? Csb.itemFgOn : Color(hex: 0xa6adbd))
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color(hex: 0x2c3850) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color(hex: 0x4a5a7a) : .clear, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x1b2230)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Csb.panelBorder, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commesseSection(_ c: Cliente) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                MenuPillButton(label: "Aggiungi progetto", icon: "plus") { showAddCommessa = true }
            }
            let items = c.commesse ?? []
            if items.isEmpty {
                EmptyStateCard(icon: "folder", text: "Nessun progetto.\nAggiungine uno con “+ Aggiungi progetto”.")
            } else {
                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, com in
                            commessaRow(com)
                            if i < items.count - 1 {
                                Divider().overlay(Color.white.opacity(0.06))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func commessaRow(_ com: Commessa) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(com.nome).font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.text)
                if let tipo = com.tipo, !tipo.isEmpty {
                    Text(tipo).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statoBadge(com.stato)
            if let importo = com.importo {
                Text("€ \(Int(importo))").font(.system(size: 12, weight: .semibold)).foregroundStyle(Holo.subDim)
                    .frame(width: 90, alignment: .trailing)
            }
            Button {
                Task {
                    do { try await HubAPI.deleteCommessa(id: com.id); await load() }
                    catch let e { errorMsg = "Eliminazione commessa fallita: \(e.localizedDescription)" }
                }
            } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Holo.labelDim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func statoBadge(_ s: String) -> some View {
        let hue: Double = s == "completata" ? 152 : s == "sospesa" ? 38 : s == "annullata" ? 0 : 217
        return Text(s.replacingOccurrences(of: "_", with: " ").uppercased())
            .font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
            .foregroundStyle(Holo.hsl(hue, 85, 75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Holo.hsl(hue, 80, 60).opacity(0.5), lineWidth: 1))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { cliente = try await HubAPI.getCliente(id: clienteId) }
        catch let e { errorMsg = e.localizedDescription }
    }
    private func delete() {
        Task {
            do {
                try await HubAPI.deleteCliente(id: clienteId)
                await MainActor.run { AppState.shared.route = .clienti }
            } catch let e {
                // se il DELETE fallisce (es. FK su fatture) il cliente esiste ancora: niente navigazione
                await MainActor.run { errorMsg = "Eliminazione fallita: \(e.localizedDescription)" }
            }
        }
    }
}

// ─── Form: modifica dati cliente ───
struct ClienteEditFormView: View {
    let cliente: Cliente
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var ragioneSociale: String
    @State private var piva: String
    @State private var indirizzo: String
    @State private var cap: String
    @State private var comune: String
    @State private var provincia: String
    @State private var email: String
    @State private var telefono: String
    @State private var sitoWeb: String
    @State private var note: String
    @State private var docs: [URL] = []
    @State private var saving = false
    @State private var errorMsg: String?

    init(cliente: Cliente, onSaved: @escaping () -> Void) {
        self.cliente = cliente
        self.onSaved = onSaved
        _ragioneSociale = State(initialValue: cliente.ragione_sociale)
        _piva = State(initialValue: cliente.piva ?? "")
        _indirizzo = State(initialValue: cliente.indirizzo ?? "")
        _cap = State(initialValue: cliente.cap ?? "")
        _comune = State(initialValue: cliente.comune ?? "")
        _provincia = State(initialValue: cliente.provincia ?? "")
        _email = State(initialValue: cliente.email ?? "")
        _telefono = State(initialValue: cliente.telefono ?? "")
        _sitoWeb = State(initialValue: cliente.sito_web ?? "")
        _note = State(initialValue: cliente.note ?? "")
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("MODIFICA CLIENTE").font(.system(size: 15, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.titleText)
                Text("Anteprima indirizzo in fattura: \(previewIndirizzo)")
                    .font(.system(size: 10.5)).foregroundStyle(Holo.hsl(152, 75, 70))

                HoloField(label: "Ragione sociale *", text: $ragioneSociale)
                HStack(spacing: 12) {
                    HoloField(label: "P.IVA", text: $piva)
                    HoloField(label: "Telefono", text: $telefono)
                }
                HoloField(label: "Email", text: $email)
                HoloField(label: "Sito web", text: $sitoWeb, placeholder: "Es. www.okenergia.it")
                HoloField(label: "Indirizzo", text: $indirizzo, placeholder: "Es. Via Properzio 5")
                HStack(spacing: 12) {
                    HoloField(label: "CAP", text: $cap, placeholder: "00193").frame(width: 110)
                    HoloField(label: "Comune", text: $comune)
                    HoloField(label: "Provincia", text: $provincia).frame(width: 110)
                }
                HoloField(label: "Note", text: $note)
                DocumentiStaging(docs: $docs, hint: "Aggiungi nuovi documenti (i già caricati si gestiscono nella scheda).")

                if let errorMsg {
                    Text(errorMsg).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad))
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                    Button { save() } label: {
                        Text(saving ? "Salvataggio…" : "Salva modifiche")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || nz(ragioneSociale) == nil)
                    .opacity(nz(ragioneSociale) == nil ? 0.5 : 1)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 740)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255),
                                            Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    // anteprima live dell'indirizzo che finirà in fattura
    private var previewIndirizzo: String {
        let s = formatIndirizzo(indirizzo: nz(indirizzo), cap: nz(cap),
                                comune: nz(comune), provincia: nz(provincia))
        return s.isEmpty ? "—" : s
    }

    private func save() {
        guard let rs = nz(ragioneSociale) else { return }
        saving = true; errorMsg = nil
        Task {
            do {
                try await HubAPI.updateCliente(id: cliente.id, fields: [
                    "ragione_sociale": rs, "piva": nz(piva), "indirizzo": nz(indirizzo),
                    "cap": nz(cap), "comune": nz(comune), "provincia": nz(provincia),
                    "email": nz(email), "telefono": nz(telefono),
                    "sito_web": nz(sitoWeb), "note": nz(note),
                ])
                for url in docs { try await HubAPI.addClienteDocumento(clienteId: cliente.id, fileURL: url) }
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; errorMsg = error.localizedDescription }
            }
        }
    }
}

// ─── Form: nuovo progetto (commessa) per un cliente ───
struct CommessaFormView: View {
    let clienteId: String
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var nome = ""
    @State private var tipo = ""
    @State private var stato = "in_corso"
    @State private var importo = ""
    @State private var note = ""
    @State private var saving = false
    @State private var errorMsg: String?

    private let stati = ["in_corso", "completata", "sospesa", "annullata"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("NUOVO PROGETTO").font(.system(size: 15, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.titleText)
                HoloField(label: "Nome *", text: $nome, placeholder: "Es. Sito e-commerce")
                HStack(spacing: 12) {
                    HoloField(label: "Tipo", text: $tipo, placeholder: "Es. Web / App")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("STATO").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                        Menu {
                            ForEach(stati, id: \.self) { s in Button(s.replacingOccurrences(of: "_", with: " ")) { stato = s } }
                        } label: {
                            HStack {
                                Text(stato.replacingOccurrences(of: "_", with: " "))
                                    .font(.system(size: 13)).foregroundStyle(Color(hex: 0xe8f2ff))
                                Spacer()
                                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Holo.labelDim)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .frame(width: 150)
                }
                HoloField(label: "Importo (€)", text: $importo, placeholder: "Es. 1500")
                HoloField(label: "Note", text: $note)

                if let errorMsg {
                    Text(errorMsg).font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad))
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Annulla") { dismiss() }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Holo.subDim)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                    Button { save() } label: {
                        Text(saving ? "Salvataggio…" : "Salva progetto")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Capsule().fill(LinearGradient(
                                colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || nz(nome) == nil)
                    .opacity(nz(nome) == nil ? 0.5 : 1)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 480)
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255),
                                            Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard let n = nz(nome) else { return }
        saving = true; errorMsg = nil
        Task {
            do {
                try await HubAPI.createCommessa([
                    "cliente_id": clienteId, "nome": n, "tipo": nz(tipo), "stato": stato,
                    // Money.parse gestisce "1.500" e "1500,50" (Double() grezzo li perdeva in silenzio)
                    "importo": nz(importo).flatMap { Money.parse($0) }.map { Double($0) / 100 }, "note": nz(note),
                ])
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; errorMsg = error.localizedDescription }
            }
        }
    }
}

// ─── Staging documenti nei form (scelta file locali, caricati al salvataggio) ───
struct DocumentiStaging: View {
    @Binding var docs: [URL]
    var hint: String = "Carica il contratto firmato o altri allegati (PDF, immagini)."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DOCUMENTI").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.65))
                Spacer()
                Button { pick() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip").font(.system(size: 10, weight: .bold))
                        Text("Aggiungi").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0xeaf0fb))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 40/255, green: 70/255, blue: 140/255).opacity(0.5)))
                    .overlay(Capsule().strokeBorder(Holo.hsl(217, 85, 62).opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            if docs.isEmpty {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
            } else {
                VStack(spacing: 6) {
                    ForEach(docs, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill").font(.system(size: 11)).foregroundStyle(Holo.hsl(38, 85, 72))
                            Text(url.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(Holo.text).lineLimit(1)
                            Spacer()
                            Button { docs.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Holo.labelDim)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.7)))
                    }
                }
            }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .png, .jpeg, .image, .data]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        if p.runModal() == .OK { docs.append(contentsOf: p.urls.filter { !docs.contains($0) }) }
    }
}

// ─── Sezione documenti del cliente (nella scheda) — lista con apri/elimina/carica ───
struct ClienteDocumentiSection: View {
    let clienteId: String
    @State private var docs: [ClienteDocumento] = []
    @State private var loading = true
    @State private var busy = false
    @State private var msg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                MenuPillButton(label: "Carica", icon: "paperclip", disabled: busy) { pick() }
            }
            if let msg { Text(msg).font(.system(size: 11)).foregroundStyle(Holo.subDim) }

            if loading {
                Text("Caricamento…").font(.system(size: 12)).foregroundStyle(Holo.subDim).padding(.vertical, 6)
            } else if docs.isEmpty {
                EmptyStateCard(icon: "doc.text", text: "Nessun documento.\nCarica il contratto o altri allegati con “Carica”.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(docs.enumerated()), id: \.element.id) { i, d in
                        row(d)
                        if i < docs.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                    }
                }
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .task { await load() }
    }

    private func row(_ d: ClienteDocumento) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Csb.itemFg)
            Text(d.nome).font(.system(size: 12.5)).foregroundStyle(Holo.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(icon: "arrow.up.right.square", help: "Apri") { Task { await apri(d) } }
            IconButton(icon: "trash", help: "Elimina", danger: true) { Task { await elimina(d) } }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { docs = try await HubAPI.listClienteDocumenti(clienteId) }
        catch let e { msg = "Errore: \(e.localizedDescription)" }
    }
    private func apri(_ d: ClienteDocumento) async {
        guard let data = try? await HubAPI.downloadClienteFile(path: d.path) else { msg = "Documento non disponibile."; return }
        let ext = (d.path as NSString).pathExtension
        let base = (d.nome as NSString).deletingPathExtension
        let url = appTempDir()
            .appendingPathComponent(base.isEmpty ? "documento" : base)
            .appendingPathExtension(ext.isEmpty ? "pdf" : ext)
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }
    private func elimina(_ d: ClienteDocumento) async {
        busy = true; defer { busy = false }
        do { try await HubAPI.deleteClienteDocumento(id: d.id, path: d.path); await load() }
        catch let e { msg = "Errore eliminazione: \(e.localizedDescription)" }
    }
    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .png, .jpeg, .image, .data]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let urls = p.urls
        Task {
            busy = true; defer { busy = false }
            do {
                for url in urls { try await HubAPI.addClienteDocumento(clienteId: clienteId, fileURL: url) }
                await load()
            } catch let e { msg = "Errore caricamento: \(e.localizedDescription)" }
        }
    }
}
