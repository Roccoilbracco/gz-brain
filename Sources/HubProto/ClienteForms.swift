import SwiftUI

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
    @State private var comune = ""
    @State private var provincia = ""
    @State private var email = ""
    @State private var telefono = ""
    @State private var note = ""
    @State private var commessaNome = ""
    @State private var commessaTipo = ""
    @State private var saving = false
    @State private var errorMsg: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("NUOVO CLIENTE").font(.system(size: 15, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.titleText)

                HoloField(label: "Ragione sociale *", text: $ragioneSociale, placeholder: "Es. Rossi Energia SRL")
                HStack(spacing: 12) {
                    HoloField(label: "P.IVA", text: $piva)
                    HoloField(label: "Telefono", text: $telefono)
                }
                HoloField(label: "Email", text: $email)
                HStack(spacing: 12) {
                    HoloField(label: "Comune", text: $comune)
                    HoloField(label: "Provincia", text: $provincia).frame(width: 110)
                }
                HoloField(label: "Note", text: $note)

                Divider().overlay(Color.white.opacity(0.1))
                Text("PRIMO PROGETTO (opzionale)").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.labelDim)
                HStack(spacing: 12) {
                    HoloField(label: "Nome progetto", text: $commessaNome, placeholder: "Es. Sito vetrina")
                    HoloField(label: "Tipo", text: $commessaTipo, placeholder: "Es. Web").frame(width: 150)
                }

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
        .frame(width: 480, height: 620)
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
                    "ragione_sociale": rs, "piva": nz(piva), "comune": nz(comune),
                    "provincia": nz(provincia), "email": nz(email), "telefono": nz(telefono),
                    "note": nz(note),
                ])
                if let nome = nz(commessaNome) {
                    try await HubAPI.createCommessa([
                        "cliente_id": cliente.id, "nome": nome, "tipo": nz(commessaTipo),
                    ])
                }
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; errorMsg = error.localizedDescription }
            }
        }
    }
}

// ─── Scheda cliente: anagrafica + lista progetti (commesse) ───
struct ClienteDetailView: View {
    let clienteId: String
    @State private var cliente: Cliente?
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var showAddCommessa = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
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
                    commesseSection(c)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task(id: clienteId) { await load() }
        .sheet(isPresented: $showAddCommessa) {
            CommessaFormView(clienteId: clienteId) { Task { await load() } }
        }
    }

    private func anagrafica(_ c: Cliente) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.ragione_sociale).font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(Holo.titleText)
                        if let piva = c.piva, !piva.isEmpty {
                            Text(piva).font(.system(size: 12)).foregroundStyle(Holo.labelDim)
                        }
                    }
                    Spacer()
                    Text(c.source == "energizzo" ? "DA ENERGIZZO" : "MANUALE")
                        .font(.system(size: 8.5, weight: .heavy)).tracking(0.8)
                        .foregroundStyle(c.source == "energizzo" ? Holo.hsl(152, 80, 72) : Holo.hsl(217, 70, 75))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(
                            (c.source == "energizzo" ? Holo.hsl(152, 80, 60) : Holo.hsl(217, 60, 60)).opacity(0.5), lineWidth: 1))
                }
                HStack(spacing: 22) {
                    info("COMUNE", [c.comune, c.provincia].compactMap { $0 }.joined(separator: ", "))
                    info("EMAIL", c.email ?? "—")
                    info("TELEFONO", c.telefono ?? "—")
                }
                if let note = c.note, !note.isEmpty {
                    info("NOTE", note)
                }
                Button { confirmDelete = true } label: {
                    Text("Elimina cliente").font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xffb3ad))
                }
                .buttonStyle(.plain)
                .confirmationDialog("Eliminare il cliente e tutti i suoi progetti?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Elimina", role: .destructive) { delete() }
                    Button("Annulla", role: .cancel) {}
                }
            }
            .padding(20)
        }
    }
    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Holo.labelDim)
            Text(value).font(.system(size: 12.5)).foregroundStyle(Holo.text)
        }
    }

    private func commesseSection(_ c: Cliente) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PROGETTI").font(.system(size: 13, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.hsl(217, 90, 76))
                Text("\(c.commesse?.count ?? 0)").font(.system(size: 11, weight: .bold)).foregroundStyle(Holo.subDim)
                Spacer()
                Button { showAddCommessa = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Aggiungi progetto").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0xeaf0fb))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 40/255, green: 70/255, blue: 140/255).opacity(0.5)))
                    .overlay(Capsule().strokeBorder(Holo.hsl(217, 85, 62).opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            let items = c.commesse ?? []
            if items.isEmpty {
                Text("Nessun progetto. Aggiungine uno con “+ Aggiungi progetto”.")
                    .font(.system(size: 12)).foregroundStyle(Holo.labelDim).padding(.vertical, 6)
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
                Task { try? await HubAPI.deleteCommessa(id: com.id); await load() }
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
            try? await HubAPI.deleteCliente(id: clienteId)
            await MainActor.run { AppState.shared.route = .clienti }
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
        ScrollView {
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
                    "importo": nz(importo).flatMap { Double($0) }, "note": nz(note),
                ])
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; errorMsg = error.localizedDescription }
            }
        }
    }
}
