import SwiftUI
import UserNotifications

// ============================================================================
// Contatti — l'anagrafica delle persone, separata dalla pipeline.
//
// Tre viste dello stesso mondo: chi ha già comprato o affittato (Clienti), chi
// non ancora (Potenziali), e le ricorrenze da non dimenticare. La pipeline nelle
// dash di progetto serve a far avanzare le trattative; qui si cerca una persona
// e si guarda la sua storia.
//
// Un lead che arriva a "vinto" diventa cliente da solo: se ne occupa il trigger
// sync_re_lead_cliente sul database, non l'app, così vale anche per le chiusure
// fatte dall'agente WhatsApp.
// ============================================================================

// ── Modelli ─────────────────────────────────────────────────────────────────
struct Contatto: Decodable, Identifiable, Equatable {
    let id: String
    var ragione_sociale: String
    var tipo: String?              // privato | azienda
    var nome: String?
    var cognome: String?
    var data_nascita: String?      // yyyy-MM-dd
    var lingua: String?
    var email: String?
    var telefono: String?
    var comune: String?
    var indirizzo: String?
    var piva: String?
    var note: String?
    var source: String?
    var re_lead_id: String?
    var created_at: String?

    var iniziali: String { ragione_sociale }
    var isAzienda: Bool { tipo == "azienda" }
}

/// Riga di `prossimi_compleanni`: il calcolo sta sul database, non qui.
struct Compleanno: Decodable, Identifiable, Equatable {
    let id: String
    let ragione_sociale: String
    let data_nascita: String
    let email: String?
    let telefono: String?
    let lingua: String?
    let compleanno: String
    let giorni_mancanti: Int
    let eta: Int
}

/// Una transazione: cosa ha comprato/affittato e quando.
struct TransazioneContatto: Decodable, Identifiable {
    let id: String
    let event_type: String?
    let event_date: String?
    let price: Int?
    let notes: String?
    let proprieta: ProprietaMini?

    struct ProprietaMini: Decodable { let title: String?; let reference: String?; let zone: String? }
}

// ── API ──────────────────────────────────────────────────────────────────────
extension HubAPI {
    static func listContatti() async throws -> [Contatto] {
        try await sb.fetch("clienti?select=*&order=ragione_sociale.asc&limit=2000")
    }
    static func updateContatto(id: String, fields: [String: Any?]) async throws {
        var b = fields; b["updated_at"] = isoNowString()
        try await sb.mutate("clienti?id=eq.\(id)", method: "PATCH", body: b)
    }
    @discardableResult
    static func createContatto(_ fields: [String: Any?]) async throws -> Contatto {
        try await sb.insertReturning("clienti", body: fields)
    }
    static func deleteContatto(id: String) async throws {
        try await sb.mutate("clienti?id=eq.\(id)", method: "DELETE")
    }
    static func prossimiCompleanni(giorni: Int = 30) async throws -> [Compleanno] {
        try await sb.fetch("rpc/prossimi_compleanni?giorni=\(giorni)")
    }
    static func transazioniContatto(clienteId: String) async throws -> [TransazioneContatto] {
        try await sb.fetch("proprieta_storico?select=id,event_type,event_date,price,notes," +
                           "proprieta(title,reference,zone)&cliente_id=eq.\(clienteId)&order=event_date.desc")
    }
}

// ── Model ────────────────────────────────────────────────────────────────────
@MainActor
final class ContattiHubModel: ObservableObject {
    @Published var contatti: [Contatto] = []
    @Published var compleanni: [Compleanno] = []
    @Published var loading = true
    @Published var error: String?

    func load() async {
        loading = true
        do {
            async let c = HubAPI.listContatti()
            async let b = HubAPI.prossimiCompleanni(giorni: 30)
            contatti = try await c
            compleanni = try await b
            error = nil
            Ricorrenze.avvisaSeOggi(compleanni)
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    var clienti: [Contatto] { contatti }
}

// ── Vista principale ─────────────────────────────────────────────────────────
enum ContattiTab: String, CaseIterable, Identifiable {
    case clienti, potenziali, ricorrenze
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clienti: return "Clienti"
        case .potenziali: return "Potenziali"
        case .ricorrenze: return "Ricorrenze"
        }
    }
    var icon: String {
        switch self {
        case .clienti: return "person.crop.circle.badge.checkmark"
        case .potenziali: return "person.crop.circle.dashed"
        case .ricorrenze: return "gift"
        }
    }
}

struct ContattiView: View {
    @StateObject private var model = ContattiHubModel()
    @StateObject private var leadModel = GZIbizaModel()
    @State private var tab: ContattiTab = .clienti
    @State private var search = ""
    @State private var selected: Contatto?
    @State private var mostraForm = false
    @State private var inModifica: Contatto?

    private var clientiFiltrati: [Contatto] {
        guard !search.isEmpty else { return model.contatti }
        return model.contatti.filter {
            [$0.ragione_sociale, $0.email ?? "", $0.telefono ?? "", $0.comune ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    /// Potenziali: i lead non ancora chiusi. La stessa persona può comparire
    /// qui e fra i clienti solo se ha una trattativa nuova aperta, ed è giusto.
    private var potenziali: [RELead] {
        leadModel.leads.filter { !LeadStage.from($0.stage).isClosed }
            .filter {
                search.isEmpty ||
                [$0.name, $0.email ?? "", $0.phone ?? "", $0.zone ?? ""]
                    .joined(separator: " ").localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 14) {
                header
                statRow

                SectionCard(title: tab.label, count: conteggio, icon: tab.icon) {
                    HStack(spacing: 6) {
                        ForEach(ContattiTab.allCases) { t in
                            FilterChip(label: t.label, icon: t.icon, selected: tab == t) { tab = t }
                        }
                        HoloSearchField(placeholder: "Cerca…", text: $search, width: 150)
                    }
                } content: {
                    if model.loading {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 40)
                    } else if let e = model.error {
                        Text("Errore: \(e)").font(.system(size: 12)).foregroundStyle(UI.tint(.stop))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else {
                        switch tab {
                        case .clienti: elencoClienti
                        case .potenziali: elencoPotenziali
                        case .ricorrenze: RicorrenzeView(compleanni: model.compleanni, contatti: model.contatti)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 24, trailing: 30))
            .blur(radius: selected != nil ? 2 : 0)
            .disabled(selected != nil)

            if let sel = selected {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                SchedaContattoView(
                    contatto: sel,
                    onEdit: {
                        inModifica = sel
                        withAnimation(.easeInOut(duration: 0.2)) { selected = nil }
                        mostraForm = true
                    },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                )
                .frame(width: 460)
                .transition(.move(edge: .trailing))
            }
        }
        .task {
            await model.load()
            await leadModel.load()
            Ricorrenze.chiediPermesso()
        }
        .sheet(isPresented: $mostraForm, onDismiss: { inModifica = nil }) {
            ContattoFormView(existing: inModifica) { await model.load() }
        }
    }

    private var conteggio: Int {
        switch tab {
        case .clienti: return model.contatti.count
        case .potenziali: return potenziali.count
        case .ricorrenze: return model.compleanni.count
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Contatti").font(.system(size: 20, weight: .semibold)).foregroundStyle(UI.ink)
                Text("Clienti, potenziali clienti e ricorrenze")
                    .font(.system(size: 11.5)).foregroundStyle(UI.faint)
            }
            Spacer()
            GhostButton(label: "Nuovo contatto", icon: "plus") { inModifica = nil; mostraForm = true }
            GhostButton(label: "Aggiorna", icon: "arrow.clockwise") {
                Task { await model.load(); await leadModel.load() }
            }
        }
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            StatTile(label: "Clienti", value: model.contatti.count)
            StatTile(label: "Potenziali", value: potenziali.count)
            StatTile(label: "Privati", value: model.contatti.filter { !$0.isAzienda }.count)
            StatTile(label: "Aziende", value: model.contatti.filter { $0.isAzienda }.count)
            StatTile(label: "Compleanni 30gg", value: model.compleanni.count, evidenzia: true)
        }
    }

    private var elencoClienti: some View {
        VStack(spacing: 6) {
            if clientiFiltrati.isEmpty {
                vuoto("Nessun cliente", "Un lead che arriva a \"Chiuso vinto\" compare qui da solo.")
            }
            ForEach(clientiFiltrati) { c in
                Button { withAnimation(.easeInOut(duration: 0.2)) { selected = c } } label: {
                    rigaContatto(c)
                }.buttonStyle(.plain)
            }
        }
    }

    private func rigaContatto(_ c: Contatto) -> some View {
        HStack(spacing: 10) {
            Avatar(nome: c.ragione_sociale)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.ragione_sociale).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink)
                    if c.isAzienda { StatusPill(label: "Azienda") }
                    if let d = Ricorrenze.compleannoBreve(c.data_nascita) {
                        StatusPill(label: d, tint: UI.tint(.attesa))
                    }
                }
                HStack(spacing: 10) {
                    if let m = c.email, !m.isEmpty {
                        Text(m).font(.system(size: 10.5)).foregroundStyle(UI.dim).lineLimit(1)
                    }
                    if let t = c.telefono, !t.isEmpty {
                        Text(t).font(.system(size: 10.5)).foregroundStyle(UI.faint).monospacedDigit()
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(UI.faint)
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var elencoPotenziali: some View {
        VStack(spacing: 6) {
            if potenziali.isEmpty {
                vuoto("Nessun potenziale cliente",
                      "Qui finiscono i lead ancora aperti: diventano clienti quando li chiudi come vinti.")
            }
            ForEach(potenziali) { l in
                HStack(spacing: 10) {
                    Avatar(nome: l.name)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(l.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink)
                            StatusPill(label: LeadStage.from(l.stage).label,
                                       tint: LeadStage.from(l.stage).color)
                        }
                        HStack(spacing: 10) {
                            if let m = l.email, !m.isEmpty {
                                Text(m).font(.system(size: 10.5)).foregroundStyle(UI.dim).lineLimit(1)
                            }
                            if let t = l.phone, !t.isEmpty {
                                Text(t).font(.system(size: 10.5)).foregroundStyle(UI.faint).monospacedDigit()
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: LeadSource.from(l.source).icon)
                        .font(.system(size: 10)).foregroundStyle(UI.faint)
                }
                .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
            }
        }
    }

    private func vuoto(_ titolo: String, _ dettaglio: String) -> some View {
        VStack(spacing: 5) {
            Text(titolo).font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text)
            Text(dettaglio).font(.system(size: 10.5)).foregroundStyle(UI.faint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}
