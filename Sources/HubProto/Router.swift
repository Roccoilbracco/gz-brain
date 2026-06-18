import SwiftUI

/// Switch della vista principale in base alla route (equivalente di react-router in App.tsx)
struct MainRouter: View {
    @ObservedObject var model: PanoramicaModel
    @ObservedObject private var state = AppState.shared

    var body: some View {
        switch state.route {
        case .panoramica:
            PanoramicaView(model: model)
        case .progetti:
            ProgettiView(model: model)
        case .clienti:
            ClientiView(model: model)
        case .impostazioni:
            ImpostazioniView()
        case .progetto(let slug, let tab):
            if let p = model.projects.first(where: { $0.slug == slug }) {
                ProgettoDettaglioView(project: p, tab: tab)
                    .id(slug + tab.rawValue)
            } else {
                PanoramicaView(model: model)
            }
        case .lead(let slug, let leadId):
            LeadPageView(slug: slug, leadId: leadId)
                .id(leadId)
        case .cliente(let id):
            ClienteDetailView(clienteId: id)
                .id(id)
        }
    }
}
