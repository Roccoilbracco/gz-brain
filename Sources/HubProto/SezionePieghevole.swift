import SwiftUI

// ============================================================================
// Sezione che si apre e si chiude cliccando il titolo.
// Le pagine della Tesoreria erano lunghissime: ottanta movimenti, le tabelle
// per casa, i servizi, tutto sempre aperto. Per arrivare al numero che serviva
// bisognava scorrere per mezzo minuto. Adesso ogni elenco sta dietro al suo
// titolo, col totale già visibile: si apre quello che si vuole guardare.
// ============================================================================

struct PSEPieghevole<C: View>: View {
    let titolo: String
    /// Numero mostrato accanto al titolo anche a sezione chiusa: è quello che
    /// si va a cercare nove volte su dieci, e così spesso non serve aprire.
    var valore: String? = nil
    var colore: Color = PSE.faint
    var coloreValore: Color = PSE.ink
    /// Sottotitolo breve a destra del titolo (es. «12 righe»).
    var nota: String? = nil
    @ViewBuilder var contenuto: () -> C

    @State private var aperta: Bool

    init(_ titolo: String, valore: String? = nil, colore: Color = PSE.faint,
         coloreValore: Color = PSE.ink, nota: String? = nil, aperta: Bool = false,
         @ViewBuilder contenuto: @escaping () -> C) {
        self.titolo = titolo
        self.valore = valore
        self.colore = colore
        self.coloreValore = coloreValore
        self.nota = nota
        self.contenuto = contenuto
        _aperta = State(initialValue: aperta)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { aperta.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: aperta ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .black)).foregroundStyle(colore.opacity(0.9))
                        .frame(width: 10)
                    Text(titolo).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(colore)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let nota {
                        Text(nota).font(.system(size: 10)).foregroundStyle(PSE.faint).lineLimit(1)
                    }
                    Spacer(minLength: 10)
                    if let valore {
                        Text(valore).font(.system(size: 12, weight: .bold)).foregroundStyle(coloreValore).monospacedDigit()
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(aperta ? "Clicca per chiudere" : "Clicca per vedere il dettaglio")
            if aperta {
                contenuto()
                Color.clear.frame(height: 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(PSE.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSE.line, lineWidth: 1))
        // Senza identità propria SwiftUI riusa lo stato per posizione: aprivi
        // «Non attribuito» e, cambiando conto, si ritrovava aperta la sezione
        // che aveva preso il suo posto.
        .id(titolo)
    }
}
