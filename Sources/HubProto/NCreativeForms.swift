import SwiftUI

// ============================================================================
// NCREATIVE — mattoni condivisi dei form (sheet, campi, picker).
// Stessa grammatica visiva di UITheme: bordo sottile, superficie appena
// staccata, un solo accento.
// ============================================================================

/// Guscio di una sheet: titolo, contenuto scrollabile, barra azioni con salva.
struct NCSheet<Content: View>: View {
    let title: String
    var canSave: Bool = true
    var onDelete: (() async -> Void)? = nil
    let onSave: () async throws -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errore: String?
    @State private var confermaElimina = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.ink)
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 13) {
                    content
                    if let e = errore {
                        Text(e).font(.system(size: 11)).foregroundStyle(UI.tint(.stop))
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }

            HStack(spacing: 10) {
                if let onDelete {
                    Button {
                        if confermaElimina {
                            Task { await onDelete(); dismiss() }
                        } else { confermaElimina = true }
                    } label: {
                        Text(confermaElimina ? "Sure? Delete" : "Delete")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(UI.tint(.stop))
                            .padding(.horizontal, 11).padding(.vertical, 5.5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(UI.tint(.stop).opacity(confermaElimina ? 0.2 : 0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.tint(.stop).opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                GhostButton(label: "Cancel") { dismiss() }
                Button { salva() } label: {
                    Text(saving ? "Saving…" : "Save")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.ink)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(UI.accent.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .disabled(saving || !canSave)
                .opacity(canSave ? 1 : 0.45)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 20, trailing: 24))
        }
        .frame(width: 580, height: 640)
        .background(UI.panel)
    }

    private func salva() {
        saving = true; errore = nil
        Task {
            do { try await onSave(); dismiss() }
            catch { errore = error.localizedDescription; saving = false }
        }
    }
}

/// Etichetta + contenuto: tutti i campi hanno lo stesso passo verticale.
struct NCLabeled<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.faint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NCField: View {
    let label: String
    @Binding var text: String
    var hint: String = ""

    var body: some View {
        NCLabeled(label: label) {
            TextField(hint, text: $text)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UI.text)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }
}

struct NCTextArea: View {
    let label: String
    @Binding var text: String
    var height: CGFloat = 70

    var body: some View {
        NCLabeled(label: label) {
            TextEditor(text: $text)
                .font(.system(size: 12.5)).foregroundStyle(UI.text)
                .scrollContentBackground(.hidden).background(Color.clear)
                .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }
}

/// Importo: si digita in euro, si salva in centesimi.
struct NCMoneyField: View {
    let label: String
    @Binding var text: String
    var body: some View {
        NCLabeled(label: label) {
            HStack(spacing: 6) {
                Text("€").font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.faint)
                TextField("0", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UI.text)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }
}

/// Data opzionale: l'interruttore decide se il campo vale nil.
struct NCDateField: View {
    let label: String
    @Binding var date: Date
    @Binding var enabled: Bool

    var body: some View {
        NCLabeled(label: label) {
            HStack(spacing: 8) {
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                if enabled {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field)
                        .font(.system(size: 12.5))
                } else {
                    Text("Not set").font(.system(size: 12)).foregroundStyle(UI.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
    }
}

/// Scelta singola a chip, per liste corte (stato, piattaforma, categoria).
struct NCChips: View {
    let label: String
    let options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        NCLabeled(label: label) {
            FlowChips(options: options, isOn: { $0 == selection }) { selection = $0 }
        }
    }
}

/// Scelta multipla a chip (servizi attivi di un cliente).
struct NCMultiChips: View {
    let label: String
    let options: [String]
    @Binding var selection: [String]

    var body: some View {
        NCLabeled(label: label) {
            FlowChips(options: options.map { ($0, $0.capitalized) }, isOn: { selection.contains($0) }) { v in
                if let i = selection.firstIndex(of: v) { selection.remove(at: i) } else { selection.append(v) }
            }
        }
    }
}

/// Chip che vanno a capo da sole: le liste di opzioni non sfondano la sheet.
struct FlowChips: View {
    let options: [(value: String, label: String)]
    let isOn: (String) -> Bool
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 5)], alignment: .leading, spacing: 5) {
            ForEach(options, id: \.value) { o in
                FilterChip(label: o.label, selected: isOn(o.value)) { onTap(o.value) }
            }
        }
    }
}

/// Selettore cliente: menu a tendina con opzione "nessuno".
struct NCClientPicker: View {
    let label: String
    let clients: [NCClient]
    @Binding var clientId: String?
    var allowNone = true

    private var currentName: String {
        clients.first { $0.id == clientId }?.name ?? "No client"
    }

    var body: some View {
        NCLabeled(label: label) {
            Menu {
                if allowNone { Button("No client") { clientId = nil } }
                ForEach(clients) { c in Button(c.name) { clientId = c.id } }
            } label: {
                HStack(spacing: 6) {
                    Text(currentName).font(.system(size: 12.5))
                        .foregroundStyle(clientId == nil ? UI.faint : UI.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(UI.faint)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Riga di testata di una tabella.
struct NCHeaderRow: View {
    let cols: [(String, CGFloat?)]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                Text(c.0.uppercased())
                    .font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundStyle(UI.faint)
                    .frame(width: c.1, alignment: .leading)
                    .frame(maxWidth: c.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}

/// Riga cliccabile di una tabella, con hover.
struct NCRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? UI.surfaceHi : UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Messaggio di lista vuota.
struct NCEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(UI.faint)
            .frame(maxWidth: .infinity).padding(.vertical, 26)
    }
}
