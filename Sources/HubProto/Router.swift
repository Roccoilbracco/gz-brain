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
        case .proprietaHub:
            ProprietaView()
        case .calendario:
            CalendarioVisiteView()
        case .clienti:
            ClientiSectionView(model: model)
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
        case .proprieta(let id):
            // L'identità è l'immobile: senza, SwiftUI riusa la stessa istanza
            // passando da una proprietà all'altra e si porta dietro lo stato di
            // quella prima — compresa la modifica aperta con la sua bozza, che
            // salvata finirebbe sull'immobile sbagliato.
            ProprietaDetailView(proprietaId: id).id(id)
                .id(id)
        case .proprietaNuova:
            ProprietaDetailView(proprietaId: nil)
                .id("proprieta-nuova")
        case .codeGeneric:
            ProgettoCodeView(project: nil)
        }
    }
}
