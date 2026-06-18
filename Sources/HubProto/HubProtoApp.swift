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
    @Published var route: Route = .panoramica
}

enum Route: Equatable {
    case panoramica
    case progetti
    case clienti
    case impostazioni
    case progetto(slug: String, tab: ProjectTab)
    case lead(slug: String, leadId: String)
    case cliente(id: String)
}

enum ProjectTab: String { case dash, code, altro }

struct ContentView: View {
    @StateObject private var model = PanoramicaModel()
    @ObservedObject private var state = AppState.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            // sfondo holo: radial + griglia + vignette
            // grafite freddo desaturato, stessa famiglia del menu (#10141d): il blu
            // resta solo su card/barre/accenti, i due lati diventano un unico ambiente
            RadialGradient(colors: [Color(hex: 0x151b27), Color(hex: 0x0d111b), Color(hex: 0x070910)],
                           center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 900)
                .ignoresSafeArea()
            GridLines().ignoresSafeArea()
            RadialGradient(colors: [.clear, .black.opacity(0.5)],
                           center: .center, startRadius: 420, endRadius: 980)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if !state.navClosed {
                    SidebarView(projects: model.projects)
                        .frame(width: 304 - 18)
                        // il pannello parte SOTTO i semafori (44px liberi in alto)
                        .padding(EdgeInsets(top: 44, leading: 12, bottom: 14, trailing: 6))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                MainRouter(model: model)
                    .padding(.top, state.navClosed ? 38 : 0)
            }
            .animation(.easeInOut(duration: 0.32), value: state.navClosed)
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .task { await model.load() }
    }
}

// ─── Pallino blu nella titlebar nativa ───
// Vive nel titlebar container accanto ai semafori: posizione e dimensione
// sono lette a runtime dai bottoni standard, quindi passo/allineamento/quota
// sono identici ai nativi su qualsiasi versione di macOS.

struct TitlebarBlueDot: View {
    @ObservedObject private var state = AppState.shared
    @Environment(\.controlActiveState) private var active
    @State private var hover = false

    var body: some View {
        let dimmed = active != .key && !hover && !state.lightsHover
        Button { state.navClosed.toggle() } label: {
            ZStack {
                Circle().fill(dimmed ? Color(hex: 0x494845) : Color(red: 77/255, green: 163/255, blue: 1))
                Circle().strokeBorder(.black.opacity(dimmed ? 0.15 : 0.25), lineWidth: 0.5)
                Image(systemName: state.navClosed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 7.5, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.62))
                    .opacity(hover || state.lightsHover ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(state.navClosed ? "Apri pannello" : "Chiudi pannello")
    }
}

/// Zona hover sopra i 4 pallini: replica il comportamento nativo (glifi su
/// hover dell'area, anche a finestra non focalizzata grazie a .activeAlways).
final class LightsHoverTracker: NSView {
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { AppState.shared.lightsHover = true }
    override func mouseExited(with event: NSEvent) { AppState.shared.lightsHover = false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // trasparente ai click
}

/// Eseguibile SPM (niente bundle .app): serve activation policy regular
/// per avere finestra normale, focus e semafori nativi.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var installedWindows = Set<Int>()
    private let quickDash = QuickDashController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        quickDash.install()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] n in
            if let w = n.object as? NSWindow { self?.setup(w) }
        }
        NSApp.windows.forEach(setup)
    }

    private func setup(_ w: NSWindow) {
        guard w.styleMask.contains(.titled), !installedWindows.contains(w.windowNumber) else { return }
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        guard let close = w.standardWindowButton(.closeButton),
              let mini = w.standardWindowButton(.miniaturizeButton),
              let zoom = w.standardWindowButton(.zoomButton),
              let container = zoom.superview else { return }
        installedWindows.insert(w.windowNumber)

        // quarto pallino: stesso frame dei nativi, spostato di un passo dopo il verde
        let pitch = mini.frame.minX - close.frame.minX
        let dot = NSHostingView(rootView: TitlebarBlueDot())
        dot.frame = zoom.frame.offsetBy(dx: pitch, dy: 0)
        dot.autoresizingMask = [.maxXMargin, .minYMargin]
        container.addSubview(dot)

        // zona hover che copre i 4 pallini
        let zone = LightsHoverTracker(frame: NSRect(
            x: close.frame.minX, y: 0,
            width: dot.frame.maxX - close.frame.minX, height: container.bounds.height))
        zone.autoresizingMask = [.maxXMargin, .height]
        container.addSubview(zone, positioned: .below, relativeTo: dot)
    }
}
