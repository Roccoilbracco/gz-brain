import SwiftUI

// ─── Modelli ───
struct Cliente: Decodable, Identifiable {
    let id: String
    let ragione_sociale: String
    let piva: String?
    let comune: String?
    let provincia: String?
    let indirizzo: String?
    let email: String?
    let telefono: String?
    let note: String?
    let source: String
    let lead_id: String?
    let created_at: String?
    var commesse: [Commessa]?
}

struct Commessa: Decodable, Identifiable {
    let id: String
    let cliente_id: String?
    let nome: String
    let tipo: String?
    let stato: String
    let importo: Double?
    let note: String?
    let data_inizio: String?
    let data_fine: String?
    let created_at: String?
}

// ─── Clienti: tabella unica, commesse come "progetti" del cliente ───
struct ClientiView: View {
    @ObservedObject var model: PanoramicaModel
    @State private var clienti: [Cliente] = []
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var search = ""
    @State private var showAdd = false

    private func luogo(_ c: Cliente) -> String {
        switch (c.comune, c.provincia) {
        case let (com?, prov?): return "\(com) (\(prov))"
        case let (com?, nil):   return com
        default:                return "—"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("CLIENTI").font(.system(size: 19, weight: .heavy)).tracking(5)
                        .foregroundStyle(Holo.titleText)
                        .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                    Text(loading ? "…" : "\(clienti.count)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Holo.subDim)
                    Spacer()
                    searchField
                    addButton
                }
                Text("Lead Energizzo diventati clienti (automatico) + clienti inseriti a mano. Ogni cliente può avere più progetti.")
                    .font(.system(size: 12)).foregroundStyle(Holo.subDim)

                if let errorMsg {
                    GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                } else if loading {
                    Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.top, 8)
                } else if clienti.isEmpty {
                    Text(search.isEmpty ? "Nessun cliente ancora." : "Nessun cliente trovato.")
                        .font(.system(size: 13)).foregroundStyle(Holo.labelDim).padding(.top, 8)
                } else {
                    GlassCard {
                        VStack(spacing: 0) {
                            header
                            Divider().overlay(Color.white.opacity(0.1))
                            ForEach(Array(clienti.enumerated()), id: \.element.id) { i, c in
                                row(c)
                                if i < clienti.count - 1 {
                                    Divider().overlay(Color.white.opacity(0.06))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task(id: search) { await load() }
        .sheet(isPresented: $showAdd) {
            ClienteFormView { Task { await load() } }
        }
    }

    private var addButton: some View {
        Button { showAdd = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Aggiungi cliente").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color(hex: 0xeaf0fb))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color(red: 40/255, green: 70/255, blue: 140/255).opacity(0.55)))
            .overlay(Capsule().strokeBorder(Holo.hsl(217, 85, 62).opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
            TextField("Cerca cliente…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Holo.text)
                .frame(width: 170)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
        .overlay(Capsule().strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.25), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 14) {
            col("RAGIONE SOCIALE", width: nil)
            col("ORIGINE", width: 100)
            col("PROGETTI", width: 230)
            col("COMUNE (PROV)", width: 150)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
    private func col(_ t: String, width: CGFloat?) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1)
            .foregroundStyle(Holo.labelDim)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ c: Cliente) -> some View {
        Button { AppState.shared.route = .cliente(id: c.id) } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.ragione_sociale).font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.text)
                        .lineLimit(1)
                    if let piva = c.piva, !piva.isEmpty {
                        Text(piva).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                origineBadge(c.source).frame(width: 100, alignment: .leading)
                commesseTags(c.commesse ?? []).frame(width: 230, alignment: .leading)
                Text(luogo(c)).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                    .lineLimit(1).frame(width: 150, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func origineBadge(_ source: String) -> some View {
        let energizzo = source == "energizzo"
        return Text(energizzo ? "ENERGIZZO" : "MANUALE")
            .font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
            .foregroundStyle(energizzo ? Holo.hsl(152, 80, 72) : Holo.hsl(217, 70, 75))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(
                (energizzo ? Holo.hsl(152, 80, 60) : Holo.hsl(217, 60, 60)).opacity(0.5), lineWidth: 1))
    }

    private func commesseTags(_ items: [Commessa]) -> some View {
        HStack(spacing: 5) {
            if items.isEmpty {
                Text("—").font(.system(size: 11)).foregroundStyle(Holo.labelDim)
            } else {
                ForEach(items.prefix(2)) { c in
                    Text(c.nome).font(.system(size: 10, weight: .medium)).foregroundStyle(Holo.subDim)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                if items.count > 2 {
                    Text("+\(items.count - 2)").font(.system(size: 10, weight: .bold)).foregroundStyle(Holo.labelDim)
                }
            }
        }
    }

    private func load() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        loading = true
        defer { loading = false }
        do { clienti = try await HubAPI.listClienti(search: search) }
        catch let e { errorMsg = e.localizedDescription }
    }
}
