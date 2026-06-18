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
    static let tagBorder = Color(hex: 0x2a3344)
    static let footBorder = Color(hex: 0x1e2536)
    static let avatar = Color(hex: 0xd97757)        // accento caldo: pop arancio
}

struct SidebarView: View {
    let projects: [Project]
    @ObservedObject private var state = AppState.shared

    // progetto e tab correnti ricavati dalla route (come in Sidebar.tsx)
    private var curSlug: String? {
        if case .progetto(let slug, _) = state.route { return slug }
        return nil
    }
    private var curTab: ProjectTab? {
        switch state.route {
        case .progetto(_, let tab): return tab
        case .impostazioni, .clienti: return nil
        default: return .dash // una tab è sempre accesa: fuori dai progetti resta Dash
        }
    }

    private func goTab(_ tab: ProjectTab) {
        if let slug = curSlug { state.route = .progetto(slug: slug, tab: tab) }
        else { state.route = .progetti }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // il pannello ora parte sotto i semafori: solo un filo di respiro in alto
            Color.clear.frame(height: 4)

            // tab segmentate Dash · Code · Altro
            HStack(spacing: 3) {
                tabButton(.dash, "Dash", icon: "square.grid.2x2")
                tabButton(.code, "Code", icon: "chevron.left.forwardslash.chevron.right")
                tabButton(.altro, "Altro", icon: "ellipsis")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11).fill(Csb.tabsBg))
            .padding(.bottom, 12)

            // azioni
            VStack(spacing: 1) {
                navItem(.panoramica, "Panoramica", icon: "clock")
                navItem(.progetti, "Progetti", icon: "square.grid.2x2")
                navItem(.clienti, "Clienti", icon: "person.2")
                navItem(.impostazioni, "Impostazioni", icon: "gearshape")
            }
            .padding(.bottom, 14)

            Spacer(minLength: 0)

            // footer
            HStack(spacing: 10) {
                Text("E")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x1a1208))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Csb.avatar))
                VStack(alignment: .leading, spacing: 1) {
                    Text("emanuele").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hex: 0xe0ddd4))
                    Text("UNVRS Labs").font(.system(size: 11)).foregroundStyle(Csb.tagFg)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 6, bottom: 0, trailing: 6))
            .overlay(alignment: .top) { Rectangle().fill(Csb.footBorder).frame(height: 1) }
            .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 19, y: 14)
    }

    private func tabButton(_ id: ProjectTab, _ label: String, icon: String) -> some View {
        let on = curTab == id
        return Button { goTab(id) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(on ? Csb.itemFgOn : Color(hex: 0x9b988f))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(on ? Csb.tabOn : .clear)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Csb.tabOnBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func navItem(_ route: Route, _ label: String, icon: String) -> some View {
        let on = state.route == route
        return Button { state.route = route } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).opacity(0.85)
                    .frame(width: 16, alignment: .center)
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 6.5, leading: 10, bottom: 6.5, trailing: 10))
            .foregroundStyle(on ? Csb.itemFgOn : Csb.itemFg)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Csb.itemOn : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
