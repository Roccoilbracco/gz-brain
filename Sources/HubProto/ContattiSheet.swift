import SwiftUI

@MainActor
final class ContattiModel: ObservableObject {
    let slug: String
    @Published var contatti: [WAContatto] = []
    @Published var loading = true
    @Published var error: String?
    @Published var filtro: Filtro = .tutti
    @Published var search = ""

    enum Filtro: String, CaseIterable, Identifiable {
        case tutti, agente, manuale
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tutti: return "Tutti"
            case .agente: return "Risponde l'agente"
            case .manuale: return "Rispondi tu"
            }
        }
    }

    init(slug: String) { self.slug = slug }

    var filtrati: [WAContatto] {
        contatti.filter { c in
            switch filtro {
            case .tutti: break
            case .agente: if !c.agente_attivo { return false }
            case .manuale: if c.agente_attivo { return false }
            }
            guard !search.isEmpty else { return true }
            return [c.nome ?? "", c.telefono ?? "", c.wa_jid]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var inManuale: Int { contatti.filter { !$0.agente_attivo }.count }

    func load() async {
        do {
            contatti = try await HubAPI.listWAContatti(slug: slug)
                .sorted { ($0.nome ?? $0.telefono ?? "") < ($1.nome ?? $1.telefono ?? "") }
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    func set(_ c: WAContatto, _ attivo: Bool) async {
        // Aggiorno subito in locale: con liste lunghe aspettare la ricarica
        // rende l'interruttore lento e si finisce per cliccare due volte.
        if let i = contatti.firstIndex(where: { $0.id == c.id }) { contatti[i].agente_attivo = attivo }
        do { try await HubAPI.setAgenteContatto(id: c.id, attivo: attivo) }
        catch {
            self.error = error.localizedDescription
            await load()
        }
    }

    /// Applica la scelta a tutti i contatti attualmente filtrati.
    func setTuttiVisibili(_ attivo: Bool) async {
        let bersagli = filtrati.filter { $0.agente_attivo != attivo }
        for c in bersagli { await set(c, attivo) }
    }
}

// ─── Pannello contatti: chi risponde a chi ───────────────────────────────────
struct ContattiSheet: View {
    let slug: String
    var onClose: () -> Void
    @StateObject private var model: ContattiModel

    init(slug: String, onClose: @escaping () -> Void) {
        self.slug = slug
        self.onClose = onClose
        _model = StateObject(wrappedValue: ContattiModel(slug: slug))
    }

    var body: some View {
        ZStack {
            Color(hex: 0x070a14).ignoresSafeArea()
            RadialGradient(colors: [Holo.hsl(210, 90, 50).opacity(0.14), .clear],
                           center: .top, startRadius: 5, endRadius: 480).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Rectangle().fill(Holo.cardBorder.opacity(0.5)).frame(height: 1)
                barra

                if model.loading {
                    Spacer(); ProgressView().controlSize(.small); Spacer()
                } else if let e = model.error {
                    Spacer()
                    Text(e).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xffb3ad)).padding()
                    Spacer()
                } else if model.contatti.isEmpty {
                    vuoto
                } else {
                    elenco
                }

                Rectangle().fill(Holo.cardBorder.opacity(0.5)).frame(height: 1)
                footer
            }
        }
        .frame(width: 620, height: 700)
        .task { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Holo.hsl(210, 80, 50).opacity(0.18)).frame(width: 32, height: 32)
                Image(systemName: "person.2.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Holo.hsl(210, 85, 72))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("CONTATTI WHATSAPP").font(.system(size: 13, weight: .heavy)).tracking(3)
                    .foregroundStyle(Holo.titleText)
                Text("Decidi a chi risponde l'agente e a chi rispondi tu")
                    .font(.system(size: 10.5)).foregroundStyle(Holo.subDim)
            }
            Spacer()
            IconButton(icon: "arrow.clockwise", help: "Ricarica") { Task { await model.load() } }
            IconButton(icon: "xmark", help: "Chiudi", action: onClose)
        }
        .padding(EdgeInsets(top: 15, leading: 20, bottom: 13, trailing: 14))
    }

    private var barra: some View {
        HStack(spacing: 8) {
            ForEach(ContattiModel.Filtro.allCases) { f in
                let on = model.filtro == f
                Button { model.filtro = f } label: {
                    Text(f.label).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(on ? Color(hex: 0x0b1020) : Holo.subDim)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(on ? Holo.hsl(210, 85, 68) : Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
            Spacer()
            HoloSearchField(placeholder: "Cerca contatto…", text: $model.search, width: 150)
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 10, trailing: 20))
    }

    private var vuoto: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.2").font(.system(size: 24)).foregroundStyle(Holo.labelDim.opacity(0.5))
            Text("Nessun contatto ancora importato")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Holo.subDim)
            Text("La rubrica arriva da WhatsApp alla connessione del numero.\nSe hai appena collegato il numero, dai a WhatsApp qualche minuto\ne poi ricarica — oppure usa Ricollega nel pannello Agente.")
                .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private var elenco: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 5) {
                ForEach(model.filtrati) { c in riga(c) }
            }
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
        }
    }

    private func riga(_ c: WAContatto) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Holo.hsl(c.agente_attivo ? 140 : 35, 70, 55).opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: c.agente_attivo ? "sparkles" : "person.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Holo.hsl(c.agente_attivo ? 140 : 35, 80, 70)))

            VStack(alignment: .leading, spacing: 1) {
                Text(c.nome?.isEmpty == false ? c.nome! : (c.telefono ?? c.wa_jid))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Holo.titleText).lineLimit(1)
                if c.nome?.isEmpty == false, let t = c.telefono {
                    Text(t).font(.system(size: 9.5)).foregroundStyle(Holo.labelDim)
                }
            }
            Spacer(minLength: 8)

            Text(c.agente_attivo ? "Agente" : "Manuale")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Holo.hsl(c.agente_attivo ? 140 : 35, 80, 70))

            Toggle("", isOn: Binding(
                get: { c.agente_attivo },
                set: { v in Task { await model.set(c, v) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(Holo.hsl(145, 70, 52))
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(model.contatti.count) contatti · \(model.inManuale) in gestione manuale")
                .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
            Spacer()
            if !model.filtrati.isEmpty {
                // Agisce sui contatti VISIBILI: combinato con la ricerca è il modo
                // veloce di mettere in manuale un gruppo ("tutti i Rossi", ecc.).
                Button("Tutti manuale") { Task { await model.setTuttiVisibili(false) } }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Holo.hsl(35, 88, 72))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Holo.hsl(35, 80, 65).opacity(0.4), lineWidth: 1))

                Button("Tutti agente") { Task { await model.setTuttiVisibili(true) } }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Holo.hsl(140, 80, 70))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Holo.hsl(140, 75, 60).opacity(0.4), lineWidth: 1))
            }
            Button("Chiudi", action: onClose)
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Holo.subDim)
        }
        .padding(EdgeInsets(top: 10, leading: 20, bottom: 13, trailing: 20))
    }
}
