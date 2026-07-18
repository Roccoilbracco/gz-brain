import SwiftUI

// ─── Modelli ─────────────────────────────────────────────────────────────────

struct Disponibilita: Identifiable, Decodable, Equatable {
    let id: String
    var project_slug: String
    var giorno: Int          // 1 = lunedì … 7 = domenica (ISO 8601)
    var ora_inizio: String   // "10:00:00"
    var ora_fine: String
    var durata_minuti: Int
    var attivo: Bool

    var hhmmInizio: String { String(ora_inizio.prefix(5)) }
    var hhmmFine: String { String(ora_fine.prefix(5)) }
}

struct Visita: Identifiable, Decodable, Equatable {
    let id: String
    var project_slug: String
    var proprieta_id: String?
    var cliente_nome: String?
    var cliente_telefono: String?
    var inizio: String
    var fine: String
    var stato: String
    var note: String?
}

enum StatoVisita: String, CaseIterable {
    case proposta, confermata, annullata, fatta
    var label: String {
        switch self {
        case .proposta: return "Da confermare"
        case .confermata: return "Confermata"
        case .annullata: return "Annullata"
        case .fatta: return "Fatta"
        }
    }
    var hue: Double {
        switch self {
        case .proposta: return 35
        case .confermata: return 145
        case .annullata: return 5
        case .fatta: return 215
        }
    }
    static func from(_ raw: String?) -> StatoVisita { StatoVisita(rawValue: raw ?? "") ?? .proposta }
}

let GIORNI_SETTIMANA = ["", "Lunedì", "Martedì", "Mercoledì", "Giovedì", "Venerdì", "Sabato", "Domenica"]

// ─── API ─────────────────────────────────────────────────────────────────────

extension HubAPI {
    static func listDisponibilita(slug: String) async throws -> [Disponibilita] {
        try await sb.fetch("visite_disponibilita?select=*&project_slug=eq.\(slug)&order=giorno,ora_inizio")
    }
    static func createDisponibilita(_ f: [String: Any?]) async throws {
        try await sb.mutate("visite_disponibilita", method: "POST", body: f)
    }
    static func updateDisponibilita(id: String, fields: [String: Any?]) async throws {
        try await sb.mutate("visite_disponibilita?id=eq.\(id)", method: "PATCH", body: fields)
    }
    static func deleteDisponibilita(id: String) async throws {
        try await sb.mutate("visite_disponibilita?id=eq.\(id)", method: "DELETE")
    }
    static func listVisite(slug: String) async throws -> [Visita] {
        try await sb.fetch("visite?select=*&project_slug=eq.\(slug)&order=inizio.asc&limit=200")
    }
    static func setStatoVisita(id: String, stato: String) async throws {
        try await sb.mutate("visite?id=eq.\(id)", method: "PATCH", body: ["stato": stato])
    }
}

@MainActor
final class CalendarioModel: ObservableObject {
    @Published var slug = "gz-ibiza"
    @Published var disponibilita: [Disponibilita] = []
    @Published var visite: [Visita] = []
    @Published var loading = true
    @Published var error: String?
    @Published var confermando: String?

    func load() async {
        do {
            async let d = HubAPI.listDisponibilita(slug: slug)
            async let v = HubAPI.listVisite(slug: slug)
            disponibilita = try await d
            visite = try await v
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    func aggiungi(giorno: Int, da: String, a: String, durata: Int) async {
        do {
            try await HubAPI.createDisponibilita([
                "project_slug": slug, "giorno": giorno,
                "ora_inizio": da, "ora_fine": a, "durata_minuti": durata,
            ])
            await load()
        } catch { self.error = "Non riesco a salvare la fascia: \(error.localizedDescription)" }
    }

    func elimina(_ d: Disponibilita) async {
        do { try await HubAPI.deleteDisponibilita(id: d.id); await load() }
        catch { self.error = error.localizedDescription }
    }

    func attiva(_ d: Disponibilita, _ on: Bool) async {
        do { try await HubAPI.updateDisponibilita(id: d.id, fields: ["attivo": on]); await load() }
        catch { self.error = error.localizedDescription }
    }

    func setStato(_ v: Visita, _ s: StatoVisita) async {
        do { try await HubAPI.setStatoVisita(id: v.id, stato: s.rawValue); await load() }
        catch { self.error = error.localizedDescription }
    }

    /// Conferma con avviso al cliente. Se il servizio WhatsApp non risponde,
    /// NON confermo lo stesso: una visita "confermata" di cui il cliente non
    /// sa nulla è peggio di una ancora da confermare.
    func conferma(_ v: Visita) async {
        confermando = v.id
        defer { confermando = nil }
        do {
            try await WABridge.shared.confermaVisita(id: v.id)
            await load()
        } catch {
            self.error = "Conferma non inviata al cliente: \(error.localizedDescription). "
                + "L'appuntamento resta da confermare."
        }
    }
}


// ─── Vista ───────────────────────────────────────────────────────────────────

struct CalendarioVisiteView: View {
    @StateObject private var model = CalendarioModel()
    @State private var giornoScelto = Calendar.current.startOfDay(for: Date())
    @State private var mostraOrari = false
    @State private var nuovoGiorno = 1
    @State private var nuovoDa = "10:00"
    @State private var nuovoA = "14:00"
    @State private var nuovaDurata = 60

    // Le visite si fanno a Ibiza: tutto il calendario ragiona in quel fuso,
    // altrimenti una visita delle 10 comparirebbe in un giorno diverso.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .current
        c.locale = Locale(identifier: "it_IT")
        return c
    }()

    /// Finestra scorrevole: tre giorni indietro per vedere l'appena passato.
    private var giorni: [Date] {
        let da = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        return (0..<45).compactMap { cal.date(byAdding: .day, value: $0, to: da) }
    }

    private func data(_ iso: String) -> Date? {
        ISO8601DateFormatter.flexible.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private func visiteDel(_ g: Date) -> [Visita] {
        model.visite
            .filter { $0.stato != "annullata" }
            .filter { data($0.inizio).map { cal.isDate($0, inSameDayAs: g) } ?? false }
            .sorted { ($0.inizio) < ($1.inizio) }
    }

    /// Quanti slot esistono in quel giorno secondo la disponibilità settimanale.
    private func slotTotali(_ g: Date) -> Int {
        let iso = cal.component(.weekday, from: g)          // domenica = 1
        let giornoISO = iso == 1 ? 7 : iso - 1              // → lunedì = 1 … domenica = 7
        return model.disponibilita
            .filter { $0.giorno == giornoISO && $0.attivo }
            .reduce(0) { tot, f in
                let m = { (s: String) -> Int in
                    let p = s.split(separator: ":").compactMap { Int($0) }
                    return p.count >= 2 ? p[0] * 60 + p[1] : 0
                }
                let durata = max(1, f.durata_minuti)
                return tot + max(0, (m(f.ora_fine) - m(f.ora_inizio)) / durata)
            }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let e = model.error {
                    GlassCard { Text("Errore: \(e)").font(.system(size: 11.5))
                        .foregroundStyle(Color(hex: 0xffb3ad)).padding(16) }
                        .frame(maxWidth: 980)
                }

                if model.loading {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.top, 40)
                } else {
                    statRow
                    striscia
                    giornoCard
                    orariCard
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
        .task { await model.load() }
    }

    // ── Testata ──
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CALENDARIO VISITE")
                    .font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                Text("Appuntamenti fissati dall'agente e disponibilità settimanale")
                    .font(.system(size: 11)).foregroundStyle(Holo.subDim)
            }
            Spacer()
            Picker("", selection: $model.slug) {
                Text("GZ Ibiza").tag("gz-ibiza")
                Text("Wallis 57").tag("wallis-57")
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 190)
            .onChange(of: model.slug) { _, _ in Task { await model.load() } }
            IconButton(icon: "arrow.clockwise", help: "Ricarica") { Task { await model.load() } }
        }
        .frame(maxWidth: 980)
    }

    // ── Totali in cima ──
    private var statRow: some View {
        let oggi = cal.startOfDay(for: Date())
        let visiteOggi = visiteDel(oggi)
        let liberiOggi = max(0, slotTotali(oggi) - visiteOggi.count)
        // "Da confermare" conta solo le future: quelle passate non le confermi più.
        let daConfermare = model.visite.filter {
            $0.stato == "proposta" && (data($0.inizio) ?? .distantPast) >= Date()
        }.count
        let fineSettimana = cal.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        let settimana = model.visite.filter {
            guard $0.stato != "annullata", let d = data($0.inizio) else { return false }
            return d >= Date() && d <= fineSettimana
        }.count

        return HStack(spacing: 12) {
            statCard("VISITE OGGI", visiteOggi.count, hue: 210, glow: !visiteOggi.isEmpty)
            statCard("DA CONFERMARE", daConfermare, hue: 35, glow: daConfermare > 0)
            statCard("PROSSIMI 7 GIORNI", settimana, hue: 145, glow: false)
            statCard("SLOT LIBERI OGGI", liberiOggi, hue: 265, glow: false)
        }
        .frame(maxWidth: 980)
    }

    private func statCard(_ label: String, _ n: Int, hue: Double, glow: Bool) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(n)").font(.system(size: 26, weight: .black)).monospacedDigit()
                    .foregroundStyle(Holo.hsl(hue, 90, 70))
                    .shadow(color: glow ? Holo.hsl(hue, 90, 60).opacity(0.7) : .clear, radius: 8)
                Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.labelDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 15, bottom: 11, trailing: 15))
        }
    }

    // ── Striscia dei giorni ──
    private var striscia: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(giorni, id: \.self) { g in cardGiorno(g) }
                }
                .padding(.vertical, 2).padding(.horizontal, 1)
            }
            .onAppear { proxy.scrollTo(cal.startOfDay(for: Date()), anchor: .leading) }
        }
        .frame(maxWidth: 980)
    }

    private func cardGiorno(_ g: Date) -> some View {
        let visite = visiteDel(g)
        let totali = slotTotali(g)
        let scelto = cal.isDate(g, inSameDayAs: giornoScelto)
        let oggi = cal.isDateInToday(g)
        let chiuso = totali == 0
        let quota = totali > 0 ? min(1, CGFloat(visite.count) / CGFloat(totali)) : 0
        // Arancione se qualcosa è ancora da confermare: è ciò che richiede te.
        let daConf = visite.contains { $0.stato == "proposta" }
        let tinta: Double = daConf ? 35 : 210

        return Button { withAnimation(.easeOut(duration: 0.15)) { giornoScelto = g } } label: {
            VStack(spacing: 4) {
                Text(fmt(g, "EEE").uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(scelto ? Holo.titleText : Holo.labelDim)
                Text(fmt(g, "d")).font(.system(size: 18, weight: .bold)).monospacedDigit()
                    .foregroundStyle(chiuso ? Holo.labelDim.opacity(0.45)
                                     : (scelto ? Holo.titleText : Holo.text))
                Text(fmt(g, "MMM").uppercased()).font(.system(size: 7.5, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Holo.labelDim.opacity(0.8))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        if quota > 0 {
                            Capsule().fill(Holo.hsl(tinta, 80, 62)).frame(width: geo.size.width * quota)
                        }
                    }
                }.frame(height: 3)

                Text(chiuso ? "chiuso" : (visite.isEmpty ? "libero" : "\(visite.count)/\(totali)"))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(visite.isEmpty ? Holo.labelDim.opacity(0.7) : Holo.hsl(tinta, 80, 72))
            }
            .frame(width: 58)
            .padding(.vertical, 9).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(scelto ? Holo.hsl(tinta, 70, 50).opacity(0.2) : Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                scelto ? Holo.hsl(tinta, 80, 62).opacity(0.8)
                       : (oggi ? Holo.hsl(210, 80, 62).opacity(0.5) : Color.white.opacity(0.07)),
                lineWidth: (scelto || oggi) ? 1.3 : 1))
        }
        .buttonStyle(.plain)
        .id(g)
    }

    // ── Giorno selezionato ──
    private var giornoCard: some View {
        let visite = visiteDel(giornoScelto)
        let totali = slotTotali(giornoScelto)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(fmt(giornoScelto, "EEEE d MMMM").capitalized)
                        .font(.system(size: 13.5, weight: .bold)).foregroundStyle(Holo.titleText)
                    if cal.isDateInToday(giornoScelto) {
                        Text("OGGI").font(.system(size: 8, weight: .heavy)).tracking(1)
                            .foregroundStyle(Holo.hsl(210, 85, 75))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Holo.hsl(210, 80, 55).opacity(0.2)))
                    }
                    Spacer()
                    Text(totali == 0 ? "Nessuna disponibilità in questo giorno"
                                     : "\(visite.count) su \(totali) slot occupati")
                        .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
                }

                if visite.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: totali == 0 ? "moon.zzz" : "calendar.badge.checkmark")
                            .font(.system(size: 14)).foregroundStyle(Holo.labelDim.opacity(0.6))
                        Text(totali == 0
                             ? "Giorno chiuso: l'agente non proporrà visite."
                             : "Nessuna visita fissata. Gli slot sono tutti liberi.")
                            .font(.system(size: 11.5)).foregroundStyle(Holo.subDim)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(visite) { rigaVisita($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(maxWidth: 980)
    }

    private func rigaVisita(_ v: Visita) -> some View {
        let st = StatoVisita.from(v.stato)
        let passata = (data(v.inizio) ?? .distantFuture) < Date()
        return HStack(spacing: 12) {
            // L'ora, in evidenza: è l'informazione che cerchi guardando l'agenda.
            Text(data(v.inizio).map { fmt($0, "HH:mm") } ?? "—")
                .font(.system(size: 15, weight: .heavy)).monospacedDigit()
                .foregroundStyle(passata ? Holo.labelDim : Holo.hsl(st.hue, 80, 70))
                .frame(width: 52, alignment: .leading)

            Rectangle().fill(Holo.hsl(st.hue, 80, 60).opacity(0.5)).frame(width: 2, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(v.cliente_nome ?? "Cliente senza nome")
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Holo.titleText)
                HStack(spacing: 6) {
                    if let t = v.cliente_telefono, !t.isEmpty {
                        Text(t).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                    }
                    if let n = v.note, !n.isEmpty {
                        Text(n).font(.system(size: 10)).foregroundStyle(Holo.subDim).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)

            Text(st.label).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
                .foregroundStyle(Holo.hsl(st.hue, 80, 70))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Holo.hsl(st.hue, 80, 60).opacity(0.16)))

            if st == .proposta {
                Button(model.confermando == v.id ? "Invio…" : "Conferma") {
                    Task { await model.conferma(v) }
                }
                .disabled(model.confermando != nil)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: 0x08130d))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Holo.hsl(150, 72, 62)))
            }
            if st == .confermata && passata {
                Button("Fatta") { Task { await model.setStato(v, .fatta) } }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Holo.hsl(215, 80, 75))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Holo.hsl(215, 80, 65).opacity(0.45), lineWidth: 1))
            }
            if st != .fatta {
                IconButton(icon: "xmark", help: "Annulla la visita", danger: true) {
                    Task { await model.setStato(v, .annullata) }
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(passata ? 0.02 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    // ── Disponibilità settimanale (richiudibile: si imposta di rado) ──
    private var orariCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Button { withAnimation(.easeOut(duration: 0.18)) { mostraOrari.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mostraOrari ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Holo.labelDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QUANDO SEI DISPONIBILE").font(.system(size: 10, weight: .heavy)).tracking(2)
                                .foregroundStyle(Holo.hsl(217, 90, 70))
                            Text(riepilogoOrari).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)

                if mostraOrari {
                    formAggiunta
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(1...7, id: \.self) { g in colonnaGiorno(g) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(maxWidth: 980)
    }

    private var riepilogoOrari: String {
        let attive = model.disponibilita.filter(\.attivo)
        if attive.isEmpty { return "Nessuna fascia impostata: l'agente non può proporre visite" }
        let giorni = Set(attive.map(\.giorno)).count
        return "\(attive.count) fasce su \(giorni) giorni — clicca per modificarle"
    }

    private var formAggiunta: some View {
        HStack(spacing: 10) {
            Picker("", selection: $nuovoGiorno) {
                ForEach(1...7, id: \.self) { Text(GIORNI_SETTIMANA[$0]).tag($0) }
            }.labelsHidden().frame(width: 110)
            campoOra("dalle", $nuovoDa)
            campoOra("alle", $nuovoA)
            HStack(spacing: 4) {
                Text("visite da").font(.system(size: 10)).foregroundStyle(Holo.labelDim)
                Picker("", selection: $nuovaDurata) {
                    ForEach([30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }.labelsHidden().frame(width: 92)
            }
            Button("Aggiungi") {
                Task { await model.aggiungi(giorno: nuovoGiorno, da: nuovoDa + ":00",
                                            a: nuovoA + ":00", durata: nuovaDurata) }
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(hex: 0x08130d))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Holo.hsl(150, 72, 62)))
            Spacer()
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    private func campoOra(_ label: String, _ binding: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(Holo.labelDim)
            TextField("10:00", text: binding)
                .textFieldStyle(.plain).font(.system(size: 11.5).monospaced())
                .foregroundStyle(Holo.text).frame(width: 46)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0d152c).opacity(0.8)))
        }
    }

    private func colonnaGiorno(_ g: Int) -> some View {
        let fasce = model.disponibilita.filter { $0.giorno == g }
        return VStack(spacing: 6) {
            Text(GIORNI_SETTIMANA[g].prefix(3).uppercased())
                .font(.system(size: 9, weight: .heavy)).tracking(1)
                .foregroundStyle(fasce.isEmpty ? Holo.labelDim.opacity(0.5) : Holo.hsl(210, 85, 72))
            if fasce.isEmpty {
                Text("—").font(.system(size: 11)).foregroundStyle(Holo.labelDim.opacity(0.4))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                ForEach(fasce) { f in
                    VStack(spacing: 2) {
                        Text("\(f.hhmmInizio)–\(f.hhmmFine)")
                            .font(.system(size: 10.5, weight: .semibold).monospaced())
                            .foregroundStyle(f.attivo ? Holo.text : Holo.labelDim.opacity(0.5))
                        Text("\(f.durata_minuti)′").font(.system(size: 8)).foregroundStyle(Holo.labelDim)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(f.attivo ? Holo.hsl(210, 70, 50).opacity(0.16) : Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                    .contextMenu {
                        Button(f.attivo ? "Disattiva" : "Attiva") { Task { await model.attiva(f, !f.attivo) } }
                        Button("Elimina", role: .destructive) { Task { await model.elimina(f) } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func fmt(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.timeZone = TimeZone(identifier: "Europe/Madrid")
        f.dateFormat = pattern
        return f.string(from: d)
    }
}
