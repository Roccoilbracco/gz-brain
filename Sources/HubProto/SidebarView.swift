import SwiftUI

// ─── Sidebar stile Claude desktop (replica Sidebar.tsx + classi .csb di holo.css) ───
enum Csb {
    static let panel = Color(hex: 0x262522)
    static let panelBorder = Color(hex: 0x3a3935)
    static let tabsBg = Color(hex: 0x1d1c19)
    static let tabOn = Color(hex: 0x3a3934)
    static let tabOnBorder = Color(hex: 0x4a4943)
    static let itemFg = Color(hex: 0xd6d3ca)
    static let itemFgOn = Color(hex: 0xf4f2ec)
    static let itemOn = Color(hex: 0x34332e)
    static let secFg = Color(hex: 0x807d74)
    static let tagFg = Color(hex: 0x8a877d)
    static let tagBorder = Color(hex: 0x3a3930)
    static let footBorder = Color(hex: 0x2b2a25)
    static let avatar = Color(hex: 0xd97757)
}

struct SidebarView: View {
    let projects: [Project]
    @State private var tab = "dash"
    @State private var nav = "panoramica"
    @State private var curProject: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // riga di testa: spazio per semafori + quarto pallino (gestiti fuori)
            Color.clear.frame(height: 28).padding(.bottom, 10)

            // tab segmentate Dash · Code · Altro
            HStack(spacing: 3) {
                tabButton("dash", "Dash", icon: "square.grid.2x2")
                tabButton("code", "Code", icon: "chevron.left.forwardslash.chevron.right")
                tabButton("altro", "Altro", icon: "ellipsis")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11).fill(Csb.tabsBg))
            .padding(.bottom, 12)

            // azioni
            VStack(spacing: 1) {
                navItem("panoramica", "Panoramica", icon: "clock")
                navItem("progetti", "Progetti", icon: "square.grid.2x2")
                navItem("impostazioni", "Impostazioni", icon: "gearshape")
            }
            .padding(.bottom, 14)

            Text("Progetti")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Csb.secFg)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 5, trailing: 10))

            ScrollView(showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(projects) { p in
                        projectRow(p)
                    }
                }
            }

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

    private func tabButton(_ id: String, _ label: String, icon: String) -> some View {
        Button { tab = id } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(tab == id ? Csb.itemFgOn : Color(hex: 0x9b988f))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tab == id ? Csb.tabOn : .clear)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tab == id ? Csb.tabOnBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func navItem(_ id: String, _ label: String, icon: String) -> some View {
        Button { nav = id; curProject = nil } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).opacity(0.85)
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 6.5, leading: 10, bottom: 6.5, trailing: 10))
            .foregroundStyle(nav == id && curProject == nil ? Csb.itemFgOn : Csb.itemFg)
            .background(RoundedRectangle(cornerRadius: 8).fill(nav == id && curProject == nil ? Csb.itemOn : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func projectRow(_ p: Project) -> some View {
        Button { curProject = p.slug } label: {
            HStack(spacing: 9) {
                Circle().fill(Holo.hsl(p.hue, 75, 60)).frame(width: 7, height: 7)
                Text(p.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text("CODE")
                    .font(.system(size: 9, weight: .bold)).tracking(0.4)
                    .foregroundStyle(curProject == p.slug ? Csb.avatar : Csb.tagFg)
                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                    .overlay(Capsule().strokeBorder(
                        curProject == p.slug ? Csb.avatar.opacity(0.45) : Csb.tagBorder, lineWidth: 1))
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .foregroundStyle(curProject == p.slug ? Color(hex: 0xf7f5ef) : Csb.itemFg)
            .background(RoundedRectangle(cornerRadius: 8).fill(curProject == p.slug ? Csb.itemOn : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
