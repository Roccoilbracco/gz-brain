import SwiftUI
import SwiftTerm
import WebKit
import AppKit

private enum CodeMode { case code, preview }

// ─── Vista Code: terminale Claude persistente (CODE) o anteprima locale (PREVIEW).
//     project == nil ⇒ terminale GENERICO (cartella home), non legato a progetti. ───
struct ProgettoCodeView: View {
    let project: Project?
    @State private var mode: CodeMode = .code
    @State private var bump = 0   // forza il refresh del terminale persistente

    private var isGeneric: Bool { project == nil }
    private var title: String { project?.name.uppercased() ?? "TERMINALE" }
    private var termKey: String { project?.id ?? "__generic__" }
    private var termDir: String { project?.local_path ?? FileManager.default.homeDirectoryForCurrentUser.path }
    private var showTerminal: Bool { isGeneric || (mode == .code && project?.local_path != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 17, weight: .heavy)).tracking(4)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)
                if let p = project { StatusBadge(status: p.status) }
                Spacer()
                if showTerminal {
                    Button {
                        TerminalStore.shared.reset(key: termKey, dir: termDir); bump += 1
                    } label: {
                        Image(systemName: "arrow.clockwise.circle").font(.system(size: 15))
                            .foregroundStyle(Holo.subDim)
                    }.buttonStyle(.plain).help("Nuova sessione (chiude e riapre il terminale)")
                }
                if isGeneric {
                    badgeLabel("CODE", color: Csb.avatar)
                } else {
                    modeBadge("CODE", color: Csb.avatar, on: mode == .code) { mode = .code }
                    modeBadge("PREVIEW", color: Holo.hsl(200, 85, 62), on: mode == .preview) { mode = .preview }
                }
            }

            if let project, project.local_path == nil, !isGeneric {
                GlassCard {
                    Text("Questo progetto non ha un repo locale collegato — manca local_path. Chiedi al Direttore di collegarlo.")
                        .font(.system(size: 12.5)).lineSpacing(5)
                        .foregroundStyle(Color(red: 200/255, green: 222/255, blue: 255/255).opacity(0.7))
                        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                }
                Spacer()
            } else if showTerminal {
                PersistentTerminal(key: termKey, dir: termDir, bump: bump)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.32), lineWidth: 1))
            } else if let project {
                PreviewPane(project: project)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Holo.hsl(200, 80, 60).opacity(0.32), lineWidth: 1))
                    .id("preview-\(project.id)")
            }
        }
        // bottom 14 = stesso margine inferiore del pannello menu (allineati)
        .padding(EdgeInsets(top: 40, leading: 30, bottom: 14, trailing: 30))
    }

    private func badgeLabel(_ label: String, color: SwiftUI.Color) -> some View {
        Text(label).font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
            .foregroundStyle(color)
            .padding(.horizontal, 11).padding(.vertical, 3.5)
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
    }

    private func modeBadge(_ label: String, color: SwiftUI.Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(on ? Color(hex: 0x0b0f16) : color)
                .padding(.horizontal, 11).padding(.vertical, 3.5)
                .background(Capsule().fill(on ? color : Color.clear))
                .overlay(Capsule().strokeBorder(color.opacity(on ? 0 : 0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// ─── Anteprima locale: avvia dev server + proxy (stile UNVRS Code) ed embedda il sito ───
struct PreviewPane: View {
    let project: Project
    @State private var loadURL: URL?
    @State private var status = "Avvio anteprima locale…"
    @State private var failed = false
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 11))
                    .foregroundStyle(Holo.hsl(200, 80, 70))
                Text(loadURL?.absoluteString ?? status)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Holo.subDim)
                    .lineLimit(1)
                Spacer()
                Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Holo.subDim).help("Ricarica")
                Button { if let u = loadURL { NSWorkspace.shared.open(u) } } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(Holo.subDim).disabled(loadURL == nil).help("Apri nel browser")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.85))

            ZStack {
                Color(red: 8/255, green: 11/255, blue: 22/255)
                if let loadURL {
                    WebView(url: loadURL, reloadToken: reloadToken)
                } else {
                    VStack(spacing: 10) {
                        if !failed { ProgressView().controlSize(.small) }
                        Text(status).font(.system(size: 12)).multilineTextAlignment(.center).lineSpacing(4)
                            .foregroundStyle(failed ? Color(hex: 0xffb3ad) : Holo.subDim)
                        if failed {
                            Button("Riprova") { Task { await launch() } }
                                .buttonStyle(.plain).font(.system(size: 12))
                                .foregroundStyle(Holo.hsl(200, 80, 70)).padding(.top, 2)
                        }
                    }
                    .padding(30)
                }
            }
        }
        .task(id: project.id) { await launch() }
    }

    private func launch() async {
        // easyact: il dev è un monorepo pnpm; mostriamo direttamente il sito live
        if project.slug == "easyact" {
            failed = false; status = "https://www.easyact.eu"
            loadURL = URL(string: "https://www.easyact.eu")
            return
        }
        guard let dir = project.local_path else { return }
        failed = false; status = "Avvio anteprima locale…"; loadURL = nil
        do {
            let url = try await PreviewServer.start(projectId: project.id, dir: dir) { s in
                Task { @MainActor in status = s }
            }
            loadURL = url
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }
}

/// WKWebView wrapper: carica l'URL quando cambia o quando si forza il reload.
struct WebView: NSViewRepresentable {
    let url: URL?
    var reloadToken: Int

    final class Coordinator { var lastURL: URL?; var lastToken = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground") // sfondo trasparente
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard let url else { return }
        let c = context.coordinator
        if c.lastURL != url || c.lastToken != reloadToken {
            c.lastURL = url; c.lastToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }
}

/// Store di terminali persistenti: tenuti vivi fuori dal ciclo di vita SwiftUI,
/// così cambiando progetto e tornando la sessione claude resta quella (multi-progetto).
@MainActor
final class TerminalStore {
    static let shared = TerminalStore()
    private var terms: [String: LocalProcessTerminalView] = [:]

    func terminal(key: String, dir: String) -> LocalProcessTerminalView {
        if let t = terms[key] { return t }
        let t = Self.makeClaude(dir: dir)
        terms[key] = t
        return t
    }

    /// Chiude la sessione e ne riapre una fresca (solo su richiesta esplicita dell'utente).
    func reset(key: String, dir: String) {
        terms[key]?.terminate()
        terms[key]?.removeFromSuperview()
        terms[key] = nil
        _ = terminal(key: key, dir: dir)
    }

    private static func makeClaude(dir: String) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.nativeBackgroundColor = NSColor(red: 8/255, green: 11/255, blue: 22/255, alpha: 1)
        term.nativeForegroundColor = NSColor(red: 0xd7/255, green: 0xe7/255, blue: 1, alpha: 1)
        term.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let claude = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("HOME=\(home)"); env.append("LANG=it_IT.UTF-8")
        env.append("PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "cd \(q(dir)) && exec \(claude.map(q) ?? "zsh -i")"
        term.startProcess(executable: "/bin/zsh", args: ["-l", "-c", cmd], environment: env)
        return term
    }
}

/// Ospita il terminale persistente dello store: la view può essere ricreata,
/// il processo resta vivo. `bump` forza il re-aggancio dopo un reset.
struct PersistentTerminal: NSViewRepresentable {
    let key: String
    let dir: String
    var bump: Int = 0

    func makeNSView(context: Context) -> NSView {
        let c = NSView(); c.autoresizingMask = [.width, .height]; return c
    }

    func updateNSView(_ container: NSView, context: Context) {
        MainActor.assumeIsolated {
            let term = TerminalStore.shared.terminal(key: key, dir: dir)
            if term.superview !== container {
                term.removeFromSuperview()
                container.subviews.forEach { $0.removeFromSuperview() }
                term.frame = container.bounds
                term.autoresizingMask = [.width, .height]
                container.addSubview(term)
            }
        }
    }
}
