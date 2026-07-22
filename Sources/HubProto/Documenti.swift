import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ============================================================================
// Archivio documenti — GZ Ibiza
//
// Due cose in una tabella sola, distinte da `tipo`:
//  • «modello»: la bozza in bianco che si riusa ogni volta (encargo, contratto
//    di vendita, di affitto, traspaso…). Non appartiene a nessuno.
//  • «firmato»: la copia firmata, che invece appartiene sempre a qualcuno —
//    il proprietario o l'immobile — e da lì si ritrova.
//
// I file stanno nel bucket privato `documenti`: sono contratti, non foto da
// mostrare sul sito.
// ============================================================================

struct Documento: Identifiable, Decodable, Equatable {
    let id: String
    var progetto: String
    var tipo: String            // modello | firmato
    var categoria: String
    var titolo: String
    var descrizione: String?
    var file_path: String
    var file_name: String?
    var mime: String?
    var size_bytes: Int?
    var owner_id: String?
    var proprieta_id: String?
    var lead_id: String?
    var firmato_il: String?
    var note: String?
    var created_at: String?
}

enum DocStato: String, CaseIterable, Identifiable {
    case modello, firmato
    var id: String { rawValue }
    var label: String { self == .modello ? "Modelli e bozze" : "Firmati" }
    var singolare: String { self == .modello ? "Modello" : "Firmato" }
    var icon: String { self == .modello ? "doc.text" : "checkmark.seal" }
}

/// Le categorie del lavoro immobiliare, nell'ordine in cui servono.
enum DocCategoria: String, CaseIterable, Identifiable {
    case encargo, honorarios, colaboracion, venta, alquiler, traspaso, mandato, nota, altro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .encargo:      return "Encargo"
        case .honorarios:   return "Hoja de reconocimiento de honorarios"
        case .colaboracion: return "Hoja de colaboración"
        case .venta:        return "Contratto di vendita"
        case .alquiler:     return "Contratto di affitto"
        case .traspaso:     return "Traspaso"
        case .mandato:      return "Mandato / procura"
        case .nota:         return "Nota d'incarico"
        case .altro:        return "Altro"
        }
    }
    /// Etichetta breve per le chip, dove il nome intero non ci sta.
    var labelBreve: String {
        switch self {
        case .honorarios:   return "Honorarios"
        case .colaboracion: return "Colaboración"
        default:            return label
        }
    }
    var icon: String {
        switch self {
        case .encargo:      return "signature"
        case .honorarios:   return "eurosign.circle"
        case .colaboracion: return "person.2"
        case .venta:        return "house.fill"
        case .alquiler:     return "key.fill"
        case .traspaso:     return "arrow.left.arrow.right"
        case .mandato:      return "person.text.rectangle"
        case .nota:         return "doc.plaintext"
        case .altro:        return "paperclip"
        }
    }
    static func from(_ s: String?) -> DocCategoria { DocCategoria(rawValue: s ?? "") ?? .altro }
}

/// Percent-encoding per i valori nelle query PostgREST (`enc` di SupabaseClient
/// è privato).
private func q(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
}

extension HubAPI {
    static func listDocumenti(progetto: String = "gz-ibiza") async throws -> [Documento] {
        try await sb.fetch("documenti?select=*&progetto=eq.\(q(progetto))&order=created_at.desc&limit=2000")
    }
    static func listDocumentiDi(ownerId: String? = nil, proprietaId: String? = nil) async throws -> [Documento] {
        var query = "documenti?select=*&order=created_at.desc"
        if let o = ownerId { query += "&owner_id=eq.\(q(o))" }
        if let p = proprietaId { query += "&proprieta_id=eq.\(q(p))" }
        return try await sb.fetch(query)
    }
    @discardableResult
    static func createDocumento(_ f: [String: Any?]) async throws -> Documento {
        try await sb.insertReturning("documenti", body: f)
    }
    static func updateDocumento(id: String, fields: [String: Any?]) async throws {
        var b = fields; b["updated_at"] = isoNowString()
        try await sb.mutate("documenti?id=eq.\(q(id))", method: "PATCH", body: b)
    }
    /// Cancella prima la riga e poi il file: se il file resta orfano nel bucket
    /// è un peccato veniale, una riga che punta a un file sparito no.
    static func deleteDocumento(_ d: Documento) async throws {
        try await sb.mutate("documenti?id=eq.\(q(d.id))", method: "DELETE")
        try? await sb.deleteFile(bucket: "documenti", path: d.file_path)
    }
    static func uploadDocumento(data: Data, path: String, mime: String) async throws -> String {
        try await sb.uploadFile(bucket: "documenti", path: path, data: data, contentType: mime)
    }
    static func downloadDocumento(path: String) async throws -> Data {
        try await sb.downloadFile(bucket: "documenti", path: path)
    }
}

// ── Utilità condivise ────────────────────────────────────────────────────────

func docMime(_ ext: String) -> String {
    switch ext.lowercased() {
    case "pdf": return "application/pdf"
    case "doc": return "application/msword"
    case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    default: return "application/octet-stream"
    }
}

func docPeso(_ bytes: Int?) -> String {
    guard let b = bytes, b > 0 else { return "—" }
    if b < 1024 { return "\(b) B" }
    if b < 1024 * 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
    return String(format: "%.1f MB", Double(b) / (1024 * 1024))
}

/// Nome file al sicuro per lo storage: niente spazi, accenti o slash.
func docSlug(_ s: String) -> String {
    let base = s.folding(options: .diacriticInsensitive, locale: .init(identifier: "it_IT")).lowercased()
    let ok = base.map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return String(ok).split(separator: "-").joined(separator: "-")
}

/// Apre il pannello di sistema e restituisce i file scelti. Il pannello vive sul
/// thread principale anche se lo si chiama da un contesto asincrono.
@MainActor func scegliDocumenti(multipli: Bool = true) -> [URL] {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.pdf, .image, .data]
    p.allowsMultipleSelection = multipli
    p.canChooseDirectories = false
    return p.runModal() == .OK ? p.urls : []
}

/// Salva il file scaricato dove dice l'utente e lo apre.
@MainActor func salvaEApri(_ data: Data, nome: String) {
    let p = NSSavePanel()
    p.nameFieldStringValue = nome
    guard p.runModal() == .OK, let url = p.url else { return }
    try? data.write(to: url)
    NSWorkspace.shared.open(url)
}

// ── Caricamento condiviso: usato dall'archivio e dalle schede ────────────────
@MainActor
enum DocUploader {
    /// Carica i file scelti creando una riga per ciascuno. Torna quanti ne sono
    /// falliti, perché un caricamento parziale va detto: senza avviso sembra che
    /// siano entrati tutti.
    static func carica(_ urls: [URL], tipo: DocStato, categoria: DocCategoria,
                       ownerId: String? = nil, proprietaId: String? = nil,
                       leadId: String? = nil, progetto: String = "gz-ibiza") async -> Int {
        var falliti = 0
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                let nome = url.deletingPathExtension().lastPathComponent
                // cartella per tipo, nome irripetibile: due encargo con lo stesso
                // titolo non si sovrascrivono a vicenda
                let path = "\(tipo.rawValue)/\(categoria.rawValue)/\(UUID().uuidString)-\(docSlug(nome)).\(ext)"
                _ = try await HubAPI.uploadDocumento(data: data, path: path, mime: docMime(ext))
                try await HubAPI.createDocumento([
                    "progetto": progetto, "tipo": tipo.rawValue, "categoria": categoria.rawValue,
                    "titolo": nome, "file_path": path, "file_name": url.lastPathComponent,
                    "mime": docMime(ext), "size_bytes": data.count,
                    "owner_id": ownerId, "proprieta_id": proprietaId, "lead_id": leadId,
                    "firmato_il": tipo == .firmato ? isoOggi() : nil,
                ])
            } catch { falliti += 1 }
        }
        return falliti
    }
}

func isoOggi() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
}
