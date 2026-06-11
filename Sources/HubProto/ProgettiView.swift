import SwiftUI

// Creazione ed eliminazione progetti avvengono via IL DIRETTORE (chat/MCP),
// non dalla UI — stessa decisione della versione Tauri (2026-06-10).
struct ProgettiView: View {
    @ObservedObject var model: PanoramicaModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("PROGETTI")
                    .font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)

                if let err = model.error {
                    GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad)).padding(20) }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                          alignment: .leading, spacing: 14) {
                    ForEach(model.projects) { p in
                        ProjectCardView(project: p, events: model.events)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
    }
}

// ─── Modal modifica progetto (port di ProjectModal.tsx, come sheet) ───
struct ProjectModalView: View {
    let project: Project
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var slug: String
    @State private var desc: String
    @State private var status: String
    @State private var hue: Double
    @State private var notes: String
    @State private var errors: [String] = []
    @State private var saving = false

    init(project: Project, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _slug = State(initialValue: project.slug)
        _desc = State(initialValue: project.description ?? "")
        _status = State(initialValue: project.status)
        _hue = State(initialValue: project.hue)
        _notes = State(initialValue: project.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MODIFICA \(project.name.uppercased())")
                .font(.system(size: 14, weight: .heavy)).tracking(2.5)
                .foregroundStyle(Holo.hsl(217, 90, 70))
                .padding(.bottom, 4)

            HStack(spacing: 12) {
                field("Nome", text: $name)
                field("Slug", text: $slug)
            }
            field("Descrizione", text: $desc)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Stato")
                    Picker("", selection: $status) {
                        ForEach(PROJECT_STATUSES, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Colore (hue 0-360)")
                    HStack {
                        TextField("", value: $hue, format: .number)
                            .textFieldStyle(.roundedBorder)
                        Circle().fill(Holo.hsl(hue, 85, 60)).frame(width: 16, height: 16)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Note")
                TextEditor(text: $notes)
                    .font(.system(size: 13))
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
            }

            ForEach(errors, id: \.self) { e in
                Text("● \(e)").font(.system(size: 12)).foregroundStyle(Color(hex: 0xffb3ad))
            }

            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button(saving ? "Salvataggio…" : "Salva") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 480)
        .background(LinearGradient(
            colors: [Color(red: 18/255, green: 28/255, blue: 58/255),
                     Color(red: 10/255, green: 16/255, blue: 34/255)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 9.5, weight: .heavy)).tracking(2)
            .foregroundStyle(Holo.labelDim)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() async {
        let errs = validateProject(name: name, slug: slug, status: status, hue: hue)
        if !errs.isEmpty { errors = errs; return }
        saving = true
        do {
            try await HubAPI.updateProject(id: project.id, fields: [
                "name": name, "slug": slug, "status": status, "hue": hue,
                "description": desc.isEmpty ? nil : desc,
                "notes": notes.isEmpty ? nil : notes,
            ], name: name)
            onSaved()
            dismiss()
        } catch {
            errors = [error.localizedDescription]
            saving = false
        }
    }
}
