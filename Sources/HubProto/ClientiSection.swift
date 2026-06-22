import SwiftUI

// ─── Pannello laterale secondario (appare in area Clienti) ───
struct ClientiSubnavView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 10)
            item("Clienti", "person.2", .clienti)
            item("Fatture", "doc.text", .fatture)
            item("Spese", "tray.and.arrow.down", .spese)
            item("Export", "square.and.arrow.up", .export)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 14).fill(Csb.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Csb.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 19, y: 14)
    }

    private func item(_ label: String, _ icon: String, _ tab: ClientiTab) -> some View {
        let on = state.clientiTab == tab
        return Button {
            state.clientiTab = tab
            state.route = .clienti
        } label: {
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

// ─── Switch della sotto-sezione Clienti ───
struct ClientiSectionView: View {
    @ObservedObject var model: PanoramicaModel
    @ObservedObject private var state = AppState.shared

    var body: some View {
        switch state.clientiTab {
        case .clienti: ClientiView(model: model)
        case .fatture: FattureView()
        case .spese:   SpeseView()
        case .export:  ExportView()
        }
    }
}

// ─── Placeholder Spese / Export (in arrivo) ───
struct SpeseView: View {
    var body: some View {
        sectionPlaceholder(icon: "tray.and.arrow.down", title: "Spese",
                           sub: "Carica qui le fatture di spesa (PDF/immagini) da girare al commercialista. In arrivo.")
    }
}
struct ExportView: View {
    var body: some View {
        sectionPlaceholder(icon: "square.and.arrow.up", title: "Export commercialista",
                           sub: "Esporta tutto (fatture PDF + registro CSV + spese) in un unico ZIP. In arrivo.")
    }
}

private func sectionPlaceholder(icon: String, title: String, sub: String) -> some View {
    ScrollView {
        VStack {
            GlassCard {
                VStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 38))
                        .foregroundStyle(Holo.hsl(217, 75, 65).opacity(0.85))
                        .shadow(color: Holo.hsl(217, 85, 60).opacity(0.5), radius: 10)
                    Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Holo.titleText)
                    Text(sub).font(.system(size: 12.5)).foregroundStyle(Holo.subDim)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, minHeight: 340).padding(40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
    }
}
