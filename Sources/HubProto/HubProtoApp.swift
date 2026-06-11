import SwiftUI
import AppKit

@main
struct HubProtoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Stato condiviso tra SwiftUI e il pallino nella titlebar AppKit
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var navClosed = false
    @Published var lightsHover = false
}

struct ContentView: View {
    @StateObject private var model = PanoramicaModel()
    @ObservedObject private var state = AppState.shared
    private var navClosed: Bool { state.navClosed }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // sfondo holo: radial + griglia + vignette
            RadialGradient(colors: [Color(hex: 0x0b142e), Color(hex: 0x060a18), Color(hex: 0x02040a)],
                           center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 900)
                .ignoresSafeArea()
            GridLines().ignoresSafeArea()
            RadialGradient(colors: [.clear, .black.opacity(0.5)],
                           center: .center, startRadius: 420, endRadius: 980)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if !navClosed {
                    SidebarView(projects: model.projects)
                        .frame(width: 304 - 18)
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 14, trailing: 6))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PanoramicaView(model: model)
                    .padding(.top, navClosed ? 38 : 0)
            }
            .animation(.easeInOut(duration: 0.32), value: navClosed)

            // quarto semaforo azzurro: in fila coi tre nativi (centri a passo 23, x=102 y=34)
            BlueDot(navClosed: $navClosed)
                .padding(.leading, 95)
                .padding(.top, 27)
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .task { await model.load() }
    }
}

struct BlueDot: View {
    @Binding var navClosed: Bool
    @State private var hover = false

    var body: some View {
        Button { navClosed.toggle() } label: {
            ZStack {
                Circle().fill(Color(red: 77/255, green: 163/255, blue: 1))
                Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                Image(systemName: navClosed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.62))
                    .opacity(hover ? 1 : 0)
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(navClosed ? "Apri pannello" : "Chiudi pannello")
    }
}

/// Eseguibile SPM (niente bundle .app): serve activation policy regular
/// per avere finestra normale, focus e semafori nativi.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // titlebar trasparente che si fonde con lo sfondo holo
        for w in NSApp.windows {
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
        }
    }
}
