import SwiftUI
import AppKit

// Creazione ed eliminazione progetti avvengono via IL DIRETTORE (chat/MCP),
// non dalla UI — stessa decisione della versione Tauri (2026-06-10).
struct ProgettiView: View {
    @ObservedObject var model: PanoramicaModel

    var body: some View {
        ScrollView(showsIndicators: false) {
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
// ─── Form: nuovo progetto (nome, repo, cartella locale) ───
struct ProjectCreateModalView: View {
    let sortOrder: Int
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var slug = ""
    @State private var repo = ""
    @State private var localPath = ""
    @State private var status = "dev"
    @State private var hue: Double = 205
    @State private var slugEdited = false
    @State private var errors: [String] = []
    @State private var saving = false

    // slug auto dal nome finché l'utente non lo modifica a mano
    private func slugify(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let joined = String(mapped)
        let parts = joined.split(separator: "-").map(String.init)
        return parts.joined(separator: "-")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NUOVO PROGETTO")
                .font(.system(size: 14, weight: .heavy)).tracking(2.5)
                .foregroundStyle(Holo.hsl(217, 90, 70)).padding(.bottom, 4)

            HStack(spacing: 12) {
                field("Nome", text: $name)
                    .onChange(of: name) { _, v in if !slugEdited { slug = slugify(v) } }
                field("Slug", text: $slug).onChange(of: slug) { _, _ in slugEdited = true }
            }
            field("Repo GitHub", text: $repo, placeholder: "https://github.com/utente/repo")
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Cartella locale sul Mac")
                HStack(spacing: 8) {
                    Text(localPath.isEmpty ? "Nessuna cartella scelta" : localPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(localPath.isEmpty ? Holo.labelDim : Holo.text)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.8)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.35), lineWidth: 1))
                    Button {
                        pickFolder()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder").font(.system(size: 11))
                            Text("Scegli…").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    if !localPath.isEmpty {
                        Button { localPath = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Holo.labelDim)
                    }
                }
            }
            Text("Serve per il tab Code (terminale Claude) e la Preview: la cartella dove hai clonato il repo.")
                .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Stato")
                    Picker("", selection: $status) {
                        ForEach(PROJECT_STATUSES, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Colore (hue 0-360)")
                    HStack {
                        TextField("", value: $hue, format: .number).textFieldStyle(.roundedBorder)
                        Circle().fill(Holo.hsl(hue, 85, 60)).frame(width: 16, height: 16)
                    }
                }
            }

            ForEach(errors, id: \.self) { e in
                Text("● \(e)").font(.system(size: 12)).foregroundStyle(Color(hex: 0xffb3ad))
            }
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button(saving ? "Creazione…" : "Crea progetto") { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(saving)
            }
            .padding(.top, 4)
        }
        .padding(22).frame(width: 480)
        .background(LinearGradient(
            colors: [Color(red: 18/255, green: 28/255, blue: 58/255), Color(red: 10/255, green: 16/255, blue: 34/255)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(2).foregroundStyle(Holo.labelDim)
    }
    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Scegli"
        p.message = "Scegli la cartella locale dove hai clonato il repo"
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        if p.runModal() == .OK, let url = p.url { localPath = url.path }
    }

    private func save() async {
        let errs = validateProject(name: name, slug: slug, status: status, hue: hue)
        if !errs.isEmpty { errors = errs; return }
        saving = true
        func nz(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        do {
            try await HubAPI.createProject([
                "name": name.trimmingCharacters(in: .whitespaces), "slug": slug, "status": status, "hue": hue,
                "local_path": nz(localPath),
                "notes": nz(repo).map { "Repo: \($0)" },
                "description": nz(repo),
                "sort_order": sortOrder,
            ])
            await onSaved()
            dismiss()
        } catch {
            errors = [error.localizedDescription]; saving = false
        }
    }
}

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
