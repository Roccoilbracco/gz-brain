import AppKit
import SwiftTerm

/// Terminale che accetta il drag & drop di file/cartelle dal Finder (o da qualsiasi
/// sorgente che esponga un file URL): al drop scrive i percorsi nel prompt di claude,
/// come farebbe l'utente incollandoli a mano. Nessun invio automatico: resta all'utente
/// completare la frase e premere invio.
final class DroppableTerminalView: LocalProcessTerminalView {
    private var isDropTarget = false {
        didSet { if isDropTarget != oldValue { highlight.isHidden = !isDropTarget } }
    }

    /// Cornice di feedback: una subview trasparente ai click (`draw` di TerminalView
    /// non è overridable fuori dal modulo SwiftTerm).
    private lazy var highlight: NSView = {
        let v = NSView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 6
        v.layer?.borderColor = NSColor(red: 0x5b/255, green: 0x9d/255, blue: 1, alpha: 0.9).cgColor
        v.layer?.backgroundColor = NSColor(red: 0x5b/255, green: 0x9d/255, blue: 1, alpha: 0.15).cgColor
        v.isHidden = true
        return v
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupDrop()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDrop()
    }

    private func setupDrop() {
        registerForDraggedTypes([.fileURL, .URL, .string])
        addSubview(highlight)
    }

    /// L'overlay non deve rubare click né drag: il target di drop resta il terminale.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === highlight ? self : hit
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = operation(for: sender)
        isDropTarget = op != []
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        operation(for: sender) != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let text = payload(from: sender.draggingPasteboard)
        guard !text.isEmpty else { return false }
        window?.makeFirstResponder(self)
        send(txt: text)
        return true
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        payload(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    /// Testo da inserire nel prompt. I file diventano percorsi assoluti (quotati solo
    /// se necessario); un drag di puro testo viene inserito così com'è, ripulito dagli
    /// a-capo che il terminale interpreterebbe come invio.
    private func payload(from pb: NSPasteboard) -> String {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            return urls.map { Self.escape($0.path) }.joined(separator: " ") + " "
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return ""
    }

    /// Un percorso con spazi o metacaratteri di shell va single-quotato, altrimenti
    /// claude (e la shell, se l'utente sta usando il terminale nudo) lo spezzerebbe.
    private static func escape(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+=@,:")
        guard path.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return path
    }
}
