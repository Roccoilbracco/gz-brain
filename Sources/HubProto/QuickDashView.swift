import SwiftUI
import AppKit

// ─── Status item nella barra menu: icona cervello → mostra/nasconde l'app ───
@MainActor
final class QuickDashController {
    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🧠"
        item.button?.toolTip = "Mostra/nascondi GZ Brain"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item
    }

    // riferimento stabile alla finestra principale: una volta agganciato resta
    // valido anche quando è nascosta (orderOut), così il toggle la ritrova sempre.
    private weak var tracked: NSWindow?
    private func appWindow() -> NSWindow? {
        if let t = tracked { return t }
        tracked = NSApp.windows.first { $0.styleMask.contains(.titled) && $0.canBecomeMain }
        return tracked
    }

    @objc private func toggle() {
        guard let w = appWindow() else {
            // nessuna finestra (chiusa col tasto rosso): prova a riaprire via SwiftUI
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            return
        }
        if w.isVisible {
            w.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }
}
