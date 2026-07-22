import SwiftUI

// ============================================================================
// Tema sobrio condiviso — nato con la dash Camere PSE, ora usato da tutte le
// dashboard di progetto.
//
// Regola: UN accento solo (slate blue). Il colore veicola stato, non decora.
// Niente aloni, niente gradienti, niente tinte fluo: la gerarchia si legge dal
// peso del testo, dalla spaziatura e dai bordi. Le tinte di stato sono
// desaturate e si usano su punti piccoli (pallino, bordo, pill), mai su intere
// superfici.
// ============================================================================

enum UI {
    static let ink = Color(red: 232/255, green: 242/255, blue: 255/255)  // testo forte
    static let text = Color(red: 210/255, green: 220/255, blue: 236/255)
    static let dim = Color(red: 190/255, green: 202/255, blue: 224/255).opacity(0.62)
    static let faint = Color(red: 150/255, green: 165/255, blue: 190/255).opacity(0.55)
    static let line = Color.white.opacity(0.09)
    static let surface = Color.white.opacity(0.035)
    static let surfaceHi = Color.white.opacity(0.06)
    static let accent = Color(red: 0.44, green: 0.56, blue: 0.74)        // slate blue
    static let warn = Color(hex: 0xd97757)                               // arancio del brand
    static let panel = Color(hex: 0x0f141e)

    /// Tinte di stato desaturate. Stessa famiglia per tutta l'app, così una
    /// pipeline lead e una prenotazione "si leggono" allo stesso modo.
    static func tint(_ kind: Tint) -> Color {
        switch kind {
        case .neutro:  return Color(hue: 220/360, saturation: 0.10, brightness: 0.62)
        case .attesa:  return Color(hue: 40/360,  saturation: 0.42, brightness: 0.68)
        case .corso:   return Color(hue: 210/360, saturation: 0.36, brightness: 0.70)
        case .ok:      return Color(hue: 150/360, saturation: 0.34, brightness: 0.60)
        case .stop:    return Color(hue: 5/360,   saturation: 0.42, brightness: 0.60)
        }
    }
    enum Tint { case neutro, attesa, corso, ok, stop }
}

/// Avvolge il contenuto in uno ScrollView solo quando serve davvero.
/// Una vista che scorre da sola, incorporata in una pagina che già scorre,
/// finisce con due scroll annidati: quello interno riceve altezza libera e il
/// contenuto collassa o cresce a vuoto. Con `scorre: false` la vista si limita
/// a impilare, e a scorrere ci pensa la pagina ospite.
struct ContenitoreScorrevole<Content: View>: View {
    let scorre: Bool
    @ViewBuilder var content: Content
    init(scorre: Bool, @ViewBuilder content: () -> Content) {
        self.scorre = scorre; self.content = content()
    }
    var body: some View {
        if scorre { ScrollView(showsIndicators: false) { content } }
        else { content }
    }
}

// ── Contenitore di sezione: titolo, contatore, comandi, contenuto ────────────
// È il mattone della pagina: ogni blocco è una card con la stessa intestazione,
// così lo schema resta identico ovunque.
struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UI.dim)
                }
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold)).tracking(1.4)
                    .foregroundStyle(UI.text)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.dim)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(UI.surface))
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12))

            Rectangle().fill(UI.line).frame(height: 1)

            content.padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(UI.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UI.line, lineWidth: 1))
    }
}

extension SectionCard where Trailing == EmptyView {
    init(title: String, count: Int? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, icon: icon, trailing: { EmptyView() }, content: content)
    }
}

// ── Riquadro numerico ────────────────────────────────────────────────────────
// Il numero è grande e monocromo; l'accento resta al solo dato che richiede
// un'azione (i "nuovi" non ancora lavorati).
struct StatTile: View {
    let label: String
    var value: Int? = nil
    var testo: String? = nil       // per valori non numerici: "€1.2M", "42%"
    var evidenzia = false

    /// Riquadro con un valore già formattato (importi, percentuali).
    init(label: String, testo: String) { self.label = label; self.testo = testo }
    init(label: String, value: Int, evidenzia: Bool = false) {
        self.label = label; self.value = value; self.evidenzia = evidenzia
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(testo ?? "\(value ?? 0)")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(evidenzia && (value ?? 0) > 0 ? UI.accent : UI.ink)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(1.1)
                .foregroundStyle(UI.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 10).fill(UI.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UI.line, lineWidth: 1))
    }
}

// ── Chip filtro ──────────────────────────────────────────────────────────────
struct FilterChip: View {
    let label: String
    var icon: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 9)) }
                // Come per PSESegmented: mai lasciare che una chip stretta mandi
                // l'etichetta a capo lettera per lettera.
                Text(label).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? UI.ink : UI.dim)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? UI.accent.opacity(0.85) : UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.clear : UI.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// ── Pill di stato ────────────────────────────────────────────────────────────
struct StatusPill: View {
    let label: String
    var tint: Color = UI.tint(.neutro)
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold)).tracking(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}

// ── Bottone secondario ───────────────────────────────────────────────────────
struct GhostButton: View {
    let label: String
    var icon: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hover ? UI.ink : UI.text)
            .padding(.horizontal, 11).padding(.vertical, 5.5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? UI.surfaceHi : UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// ── Iniziali per la lista conversazioni ─────────────────────────────────────
struct Avatar: View {
    let nome: String
    var size: CGFloat = 30

    private var iniziali: String {
        let parti = nome.split(separator: " ").prefix(2)
        let s = parti.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    var body: some View {
        Text(iniziali)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(UI.text)
            .frame(width: size, height: size)
            .background(Circle().fill(UI.surfaceHi))
            .overlay(Circle().strokeBorder(UI.line, lineWidth: 1))
    }
}
