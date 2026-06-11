import SwiftUI
import AppKit

// ─── QuickDash: popover dalla barra menu (port di QuickDash.tsx) ───
@MainActor
final class QuickDashModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var events: [HubEvent] = []
    @Published var error: String?
    private var timer: Timer?

    func start() {
        Task { await load() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await self.load() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func load() async {
        do {
            async let p = HubAPI.listProjects()
            async let e = HubAPI.listRecentEvents()
            (projects, events) = try await (p, e)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct QuickDashView: View {
    @ObservedObject var model: QuickDashModel
    @State private var blink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("UNVRS HUB")
                    .font(.system(size: 13, weight: .heavy)).tracking(4)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.8), radius: 7)
                Spacer()
                Circle().fill(Color(hex: 0x34d399))
                    .frame(width: 7, height: 7)
                    .shadow(color: Color(hex: 0x34d399), radius: 4)
                    .opacity(blink ? 0.35 : 1)
                    .animation(.easeInOut(duration: 1.8).repeatForever(), value: blink)
            }
            if let err = model.error {
                Text("Errore: \(err)").font(.system(size: 11)).foregroundStyle(Color(hex: 0xffb3ad))
            }
            HStack(spacing: 10) {
                kpi("\(model.projects.count)", "PROGETTI", Holo.hsl(217, 90, 70))
                kpi("\(model.projects.filter { $0.status == "live" }.count)", "LIVE", Holo.hsl(152, 80, 60))
            }
            LinearGradient(colors: [Color(hex: 0x4f46e5), Color(hex: 0x818cf8), Color(hex: 0x4f46e5)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 4)
                .clipShape(Capsule())
                .shadow(color: Color(red: 99/255, green: 102/255, blue: 241/255).opacity(0.9), radius: 7)
            Text("ULTIME ATTIVITÀ")
                .font(.system(size: 10, weight: .heavy)).tracking(2)
                .foregroundStyle(Color(hex: 0xffb46b))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.events.prefix(20)) { e in
                        (Text(formatDateIT(e.created_at, time: false) + " ")
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                         + Text(e.message ?? "")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(red: 220/255, green: 235/255, blue: 1).opacity(0.85)))
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.events.isEmpty && model.error == nil {
                        Text("NESSUNA ATTIVITÀ")
                            .font(.system(size: 10)).tracking(1.5)
                            .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.4))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380, height: 520)
        .background(LinearGradient(
            colors: [Color(red: 18/255, green: 28/255, blue: 58/255),
                     Color(red: 10/255, green: 16/255, blue: 34/255)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
        .onAppear { blink = true; model.start() }
        .onDisappear { model.stop() }
    }

    private func kpi(_ v: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 24, weight: .black)).foregroundStyle(color)
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1.5)
                .foregroundStyle(Holo.labelDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ─── Status item nella barra menu ───
@MainActor
final class QuickDashController {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = QuickDashModel()

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hexagon.fill", accessibilityDescription: "UNVRS Hub")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item

        popover.contentViewController = NSHostingController(rootView: QuickDashView(model: model))
        popover.behavior = .transient
    }

    @objc private func toggle() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
