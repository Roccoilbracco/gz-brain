import SwiftUI

// ─── Sidebar: grafite freddo neutro (punta di blu) per dialogare col blu della
//     dashboard senza essere blu. Accenti caldi tenuti: avatar arancio + pallini progetti. ───
enum Csb {
    static let panel = Color(hex: 0x10141d)        // grafite freddo, quasi nero
    static let panelBorder = Color(hex: 0x232b3b)  // bordo cool sottile
    static let tabsBg = Color(hex: 0x161b26)
    static let tabOn = Color(hex: 0x222c40)         // elevazione blu-tinta
    static let tabOnBorder = Color(hex: 0x33405c)
    static let itemFg = Color(hex: 0xaeb6c6)        // grigio freddo chiaro
    static let itemFgOn = Color(hex: 0xeaf0fb)
    static let itemOn = Color(hex: 0x1c2436)        // selezione blu-tinta desaturata
    static let secFg = Color(hex: 0x6b7384)
    static let tagFg = Color(hex: 0x7c8496)
    static let footBorder = Color(hex: 0x1e2536)
    static let avatar = Color(hex: 0xd97757)        // accento caldo: pop arancio
}

struct SidebarView: View {
    let projects: [Project]
    var reload: () async -> Void = {}
    @ObservedObject private var state = AppState.shared
    @State private var ordered: [Project] = []
    @State private var showAddProject = false

    /// Sposta il progetto trascinato (slug) prima di quello di destinazione e salva l'ordine.
    private func moveProject(_ slug: String, before targetSlug: String) {
        guard slug != targetSlug else { return }
        var arr = ordered
        guard let from = arr.firstIndex(where: { $0.slug == slug }) else { return }
        let item = arr.remove(at: from)
        let insertAt = arr.firstIndex(where: { $0.slug == targetSlug }) ?? arr.count
        arr.insert(item, at: insertAt)
        ordered = arr
        let ids = arr.map { $0.id }
        Task { try? await HubAPI.reorderProjects(ids) }
    }

    // progetto e tab correnti ricavati dalla route (come in Sidebar.tsx)
    private var curSlug: String? {
        if case .progetto(let slug, _) = state.route { return slug }
        return nil
    }
    // tab segmentate top-level: Dash · Code (modalità del click sui progetti) · Clienti
    private var isClienti: Bool {
        switch state.route { case .clienti, .cliente: return true; default: return false }
    }
    private var isProprieta: Bool {
        switch state.route { case .proprietaHub, .proprieta, .proprietaNuova: return true; default: return false }
    }
    private var isImpostazioni: Bool { state.route == .impostazioni }
    private var isDash: Bool { !isClienti && !isImpostazioni && state.sidebarMode == .dash }
    private var isCode: Bool { !isClienti && !isImpostazioni && state.sidebarMode == .code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // il pannello ora parte sotto i semafori: solo un filo di respiro in alto
            Color.clear.frame(height: 4)

            // tab segmentate Dash · Code · Clienti
            HStack(spacing: 3) {
                segButton("Dash", icon: "square.grid.2x2", on: isDash) {
                    state.sidebarMode = .dash; state.route = .panoramica
                }
                segButton("Code", icon: "chevron.left.forwardslash.chevron.right", on: isCode) {
                    state.sidebarMode = .code
                    if let s = curSlug { state.route = .progetto(slug: s, tab: .code) }
                    else { state.route = .codeGeneric }   // nessun progetto → terminale generico
                }
                segButton("Boss", icon: "person.2", on: isClienti) {
                    if state.isClientiArea {
                        // già in area Clienti → puro toggle del pannello (mantieni la sotto-sezione)
                        state.clientiPanelOpen.toggle()
                    } else {
                        state.clientiTab = .clienti
                        state.clientiPanelOpen = true
                        state.route = .clienti
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11).fill(Csb.tabsBg))
            .padding(.bottom, 12)

            // voce Contatti: anagrafica clienti e potenziali clienti, con ricorrenze
            navRow("Contatti", icon: "person.crop.circle", on: state.route == .contatti) {
                state.route = .contatti
            }
            .padding(.bottom, 6)

            // voce Proprietà: registro immobili (globale) + visibilità sui siti
            navRow("Proprietà", icon: "house", on: isProprieta) {
                state.route = .proprietaHub
            }
            .padding(.bottom, 6)

            // voce Calendario: disponibilità per le visite + appuntamenti fissati
            navRow("Calendario", icon: "calendar", on: state.route == .calendario) {
                state.route = .calendario
            }
            .padding(.bottom, 14)

            Text("PROGETTI").font(.system(size: 9, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Csb.tagFg).padding(.leading, 6).padding(.bottom, 6)

            // lista progetti (uno sotto l'altro): click apre Dash o Code del progetto
            // a seconda della modalità scelta in alto
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(ordered) { p in
                        DraggableProjectRow(project: p) { dragged in
                            moveProject(dragged, before: p.slug)
                        }
                    }
                }
            }
            .onAppear { ordered = projects }
            .onChange(of: projects) { _, new in ordered = new }

            // aggiungi progetto (nome, repo, cartella locale)
            Button { showAddProject = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("Aggiungi progetto").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Csb.tagFg)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.white.opacity(0.12)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Spacer(minLength: 0)

            // separatore sopra il profilo
            Rectangle().fill(Csb.footBorder).frame(height: 1).padding(.bottom, 8)

            // footer: profilo cliccabile → Impostazioni (con ingranaggio)
            profileFooter
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 19, y: 14)
        .sheet(isPresented: $showAddProject) {
            ProjectCreateModalView(sortOrder: ordered.count) { await reload() }
        }
    }

    private var profileFooter: some View {
        let on = state.route == .impostazioni
        return Button { state.route = .impostazioni } label: {
            HStack(spacing: 10) {
                Text("G")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x1a1208))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Csb.avatar))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Giorgio").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(on ? Csb.itemFgOn : Color(hex: 0xe0ddd4))
                    Text("GZ Ibiza Properties").font(.system(size: 11)).foregroundStyle(Csb.tagFg)
                }
                Spacer(minLength: 0)
                Image(systemName: "gearshape").font(.system(size: 13))
                    .foregroundStyle(on ? Csb.itemFgOn : Csb.secFg)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Csb.itemOn : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func navRow(_ label: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Csb.itemFgOn : Csb.avatar)
                    .frame(width: 18)
                Text(label).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Csb.itemFgOn : Color(hex: 0xd7dae2))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Csb.itemOn : Color.white.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                on ? Csb.avatar.opacity(0.4) : Color.white.opacity(0.05), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func segButton(_ label: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(on ? Csb.itemFgOn : Color(hex: 0x9b988f))
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Csb.tabOn : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Csb.tabOnBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

}

// ─── Riga progetto trascinabile (drag-and-drop per riordinare) ───
private struct DraggableProjectRow: View {
    let project: Project
    let onDrop: (String) -> Void   // slug trascinato, rilasciato prima di questo progetto
    @State private var targeted = false

    var body: some View {
        ProjectCard(project: project)
            .overlay(alignment: .top) {
                if targeted {
                    Capsule().fill(Holo.hsl(210, 90, 65))
                        .frame(height: 2.5).offset(y: -4)
                        .shadow(color: Holo.hsl(210, 90, 60).opacity(0.8), radius: 4)
                }
            }
            .draggable(project.slug) {
                ProjectCard(project: project).frame(width: 240).opacity(0.92)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let s = items.first, s != project.slug else { return false }
                onDrop(s); return true
            } isTargeted: { targeted = $0 }
    }
}

// ─── Mini-card progetto: compatta, accento colore + hover/attivo a "chip" ───
private struct ProjectCard: View {
    let project: Project
    @ObservedObject private var state = AppState.shared
    @State private var hover = false

    private var active: Bool {
        if case .progetto(let slug, _) = state.route { return slug == project.slug }
        return false
    }
    private var hue: Double { project.hue }
    private var hasCode: Bool { project.local_path != nil }

    var body: some View {
        Button {
            state.route = .progetto(slug: project.slug, tab: state.sidebarMode)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Holo.hsl(hue, 78, 60))
                    .frame(width: 3, height: 20)
                    .shadow(color: Holo.hsl(hue, 85, 55).opacity(active ? 0.8 : 0), radius: 4)
                Text(project.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(active ? Color(hex: 0xf4f2ec) : Csb.itemFg)
                Spacer(minLength: 0)
                if hasCode {
                    Text("CODE")
                        .font(.system(size: 9, weight: .bold)).tracking(0.4)
                        .foregroundStyle(Csb.avatar)
                        .padding(.horizontal, 7).padding(.vertical, 1.5)
                        .overlay(Capsule().strokeBorder(Csb.avatar.opacity(0.45), lineWidth: 1))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(active ? Csb.itemOn : (hover ? Color.white.opacity(0.045) : Color.white.opacity(0.02))))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                active ? Holo.hsl(hue, 70, 55).opacity(0.45) : Color.white.opacity(0.05), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
