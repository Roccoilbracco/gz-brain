import SwiftUI
import SwiftTerm
import AppKit

// ─── Tab Code: terminale nativo nella cartella del progetto, claude pronto ───
struct ProgettoCodeView: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { AppState.shared.route = .progetti } label: {
                    Text("← PROGETTI")
                        .font(.system(size: 11)).tracking(1.5)
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
                }
                .buttonStyle(.plain)
                Text(project.name.uppercased())
                    .font(.system(size: 17, weight: .heavy)).tracking(4)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                StatusBadge(status: project.status)
                Text("CODE")
                    .font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Csb.avatar)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Csb.avatar.opacity(0.45), lineWidth: 1))
                Spacer()
            }

            if let path = project.local_path {
                ClaudeTerminal(workingDirectory: path)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.32), lineWidth: 1))
                    .id(project.id) // terminale nuovo per progetto
            } else {
                GlassCard {
                    Text("Questo progetto non ha un repo locale collegato — manca local_path. Chiedi al Direttore di collegarlo.")
                        .font(.system(size: 12.5)).lineSpacing(5)
                        .foregroundStyle(Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.7))
                        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                }
                Spacer()
            }
        }
        .padding(EdgeInsets(top: 40, leading: 30, bottom: 30, trailing: 30))
    }
}

/// Terminale SwiftTerm: shell di login che lancia subito claude nella cartella del progetto.
struct ClaudeTerminal: NSViewRepresentable {
    let workingDirectory: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        // palette scura coerente con holo
        term.nativeBackgroundColor = NSColor(red: 8/255, green: 11/255, blue: 22/255, alpha: 1)
        term.nativeForegroundColor = NSColor(red: 0xd7/255, green: 0xe7/255, blue: 1, alpha: 1)
        term.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        // zsh -l -c "claude": PATH completo dell'utente (claude vive in ~/.local/bin),
        // exec così chiudendo claude si chiude la shell
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("HOME=\(home)")
        env.append("LANG=it_IT.UTF-8")
        term.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", "cd \(shellQuote(workingDirectory)) && exec claude"],
            environment: env
        )
        return term
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
