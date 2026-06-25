import SwiftUI

// ─── Modelli ───
struct Cliente: Decodable, Identifiable {
    let id: String
    let ragione_sociale: String
    let piva: String?
    let comune: String?
    let provincia: String?
    let cap: String?
    let indirizzo: String?
    let email: String?
    let telefono: String?
    let sito_web: String?
    let note: String?
    let source: String
    let lead_id: String?
    let created_at: String?
    var commesse: [Commessa]?
}

// Documento allegato a un cliente (contratto, ecc.)
struct ClienteDocumento: Decodable, Identifiable {
    let id: String
    let cliente_id: String
    let nome: String
    let path: String
    let created_at: String?
}

/// Indirizzo completo formattato per fattura/scheda: "Via X - CAP Comune (Prov)".
/// Pulisce i dati sporchi: se l'indirizzo contiene già il comune (import Energizzo
/// tipo "Via X - Roma ( Roma )"), taglia dal comune in poi per non duplicarlo.
func clienteIndirizzoCompleto(_ c: Cliente) -> String {
    formatIndirizzo(indirizzo: c.indirizzo, cap: c.cap, comune: c.comune, provincia: c.provincia)
}
func formatIndirizzo(indirizzo: String?, cap: String?, comune: String?, provincia: String?) -> String {
    var via = (indirizzo ?? "").trimmingCharacters(in: .whitespaces)
    if let com = comune, !com.isEmpty, let r = via.range(of: com) {
        via = String(via[..<r.lowerBound])
    }
    via = via.trimmingCharacters(in: CharacterSet(charactersIn: " -–·(),"))

    var loc = ""
    if let cap = cap, !cap.isEmpty { loc += cap + " " }
    if let com = comune, !com.isEmpty { loc += com }
    if let prov = provincia, !prov.isEmpty { loc += " (\(prov))" }
    loc = loc.trimmingCharacters(in: .whitespaces)

    return [via, loc].filter { !$0.isEmpty }.joined(separator: " - ")
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
        GeometryReader { geo in
            let inner = max(minTableWidth, geo.size.width - 60)   // 60 = padding orizzontale (30+30)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Spacer()
                        searchField
                        addButton
                    }

                    if let errorMsg {
                        GlassCard { Text("Errore: \(errorMsg)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                    } else if loading {
                        Text("Caricamento…").font(.system(size: 13)).foregroundStyle(Holo.subDim).padding(.top, 8)
                    } else if clienti.isEmpty {
                        Text(search.isEmpty ? "Nessun cliente ancora." : "Nessun cliente trovato.")
                            .font(.system(size: 13)).foregroundStyle(Holo.labelDim).padding(.top, 8)
                    } else {
                        // tabella: riempie la larghezza disponibile (colonna EMAIL elastica);
                        // se l'area è più stretta della larghezza minima, scorre in orizzontale
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(spacing: 0) {
                                header.background(Color(hex: 0x171c28))
                                VStack(spacing: 0) {
                                    ForEach(Array(clienti.enumerated()), id: \.element.id) { i, c in
                                        row(c)
                                        if i < clienti.count - 1 {
                                            Divider().overlay(Color.white.opacity(0.05))
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .frame(width: inner, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x10141d)))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0x232b3b), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 54, leading: 30, bottom: 34, trailing: 30))
            }
        }
        .task(id: search) { await load() }
        .sheet(isPresented: $showAdd) {
            ClienteFormView { Task { await load() } }
        }
    }

    private var addButton: some View {
        MenuPillButton(label: "Aggiungi cliente", icon: "plus") { showAdd = true }
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.25), lineWidth: 1))
    }

    // larghezza minima tabella (EMAIL ha min 180) = colonne + spacing(12×5) + padding orizzontale(14×2)
    // se l'area è più larga, la tabella si estende e la colonna EMAIL assorbe lo spazio extra
    private var minTableWidth: CGFloat { 240 + 90 + 150 + 130 + 120 + 180 + 60 + 28 }
    private var header: some View {
        HStack(spacing: 12) {
            col("RAGIONE SOCIALE", width: 240)
            col("ORIGINE", width: 90)
            col("PROGETTI", width: 150)
            col("COMUNE (PROV)", width: 130)
            col("TELEFONO", width: 120)
            col("EMAIL", width: nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
    private func col(_ t: String, width: CGFloat?) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1)
            .foregroundStyle(Holo.labelDim)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ c: Cliente) -> some View {
        Button { AppState.shared.route = .cliente(id: c.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.ragione_sociale).font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.text)
                        .lineLimit(1)
                    if let piva = c.piva, !piva.isEmpty {
                        Text(piva).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                    }
                }
                .frame(width: 240, alignment: .leading)
                origineBadge(c.source).frame(width: 90, alignment: .leading)
                commesseTags(c.commesse ?? []).frame(width: 150, alignment: .leading)
                Text(luogo(c)).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                    .lineLimit(1).frame(width: 130, alignment: .leading)
                Text(c.telefono ?? "—").font(.system(size: 11)).foregroundStyle(Holo.subDim)
                    .lineLimit(1).frame(width: 120, alignment: .leading)
                Text(c.email ?? "—").font(.system(size: 11)).foregroundStyle(Holo.subDim)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func origineBadge(_ source: String) -> some View {
        let energizzo = source == "energizzo"
        return StatusChip(text: energizzo ? "Energizzo" : "Manuale", hue: energizzo ? 152 : nil)
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
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
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
