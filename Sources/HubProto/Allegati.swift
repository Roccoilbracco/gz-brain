import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ============================================================================
// Allegati della contabilità — la prova di carta attaccata alla riga
//
// Un movimento dice «−120 € il 24/7»; la fattura dice di che cosa. Qui la si
// attacca alla riga, e quando serve controllare qualcosa si apre da lì invece
// di cercarla tra i download o nella mail.
//
// Sorgente: public.allegati (polimorfa: entita + entita_id) e il bucket privato
// `allegati`. Vale per i movimenti e per le bollette delle utenze; domani per
// qualsiasi altra riga, senza toccare il database.
// ============================================================================

struct Allegato: Identifiable, Decodable, Equatable {
    let id: String
    var entita: String          // movimento | bolletta
    var entita_id: String
    var titolo: String?
    var file_path: String
    var file_name: String?
    var mime: String?
    var size_bytes: Int?
    var note: String?
    var created_at: String?
}

/// Le entità che oggi possono avere un allegato. Enum e non stringhe sparse:
/// un refuso in un `eq.` non darebbe errore, restituirebbe zero righe.
enum AllegatoEntita: String {
    case movimento, bolletta
    var etichetta: String { self == .movimento ? "Fattura o ricevuta" : "Bolletta in PDF" }
}

private func aq(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
}

extension HubAPI {
    static func listAllegati(_ e: AllegatoEntita, id: String) async throws -> [Allegato] {
        try await sb.fetch("allegati?select=*&entita=eq.\(e.rawValue)&entita_id=eq.\(aq(id))&order=created_at.asc")
    }
    /// Quanti allegati per riga, per l'intera entità: serve alle tabelle, che
    /// devono mostrare la graffetta senza una query per riga.
    static func contaAllegati(_ e: AllegatoEntita) async throws -> [String: Int] {
        struct Riga: Decodable { let entita_id: String }
        let righe: [Riga] = try await sb.fetch("allegati?select=entita_id&entita=eq.\(e.rawValue)&limit=5000")
        return righe.reduce(into: [:]) { $0[$1.entita_id, default: 0] += 1 }
    }
    @discardableResult
    static func createAllegato(_ f: [String: Any?]) async throws -> Allegato {
        try await sb.insertReturning("allegati", body: f)
    }
    /// Prima la riga, poi il file: un file orfano nel bucket è un peccato
    /// veniale, una riga che punta al vuoto no.
    static func deleteAllegato(_ a: Allegato) async throws {
        try await sb.mutate("allegati?id=eq.\(aq(a.id))", method: "DELETE")
        try? await sb.deleteFile(bucket: "allegati", path: a.file_path)
    }
    /// Toglie tutti gli allegati di una riga — da chiamare quando si cancella
    /// la riga stessa, altrimenti restano appesi a un id che non esiste più.
    static func deleteAllegatiDi(_ e: AllegatoEntita, id: String) async {
        let elenco = (try? await listAllegati(e, id: id)) ?? []
        for a in elenco { try? await deleteAllegato(a) }
    }
}

// ── Store: un'istanza per riga in lavorazione ───────────────────────────────
//
// Il caso scomodo è il movimento nuovo: l'allegato si sceglie prima che la riga
// esista, quindi prima che ci sia un id a cui attaccarlo. I file scelti restano
// «in attesa» e salgono subito dopo l'INSERT, con `salvaInAttesa(su:)`.
@MainActor final class AllegatiStore: ObservableObject {
    let entita: AllegatoEntita
    @Published private(set) var entitaId: String?
    @Published private(set) var items: [Allegato] = []
    @Published private(set) var inAttesa: [URL] = []
    @Published private(set) var occupato = false
    @Published var errore: String?

    init(entita: AllegatoEntita, entitaId: String? = nil) {
        self.entita = entita
        self.entitaId = entitaId
    }

    var totale: Int { items.count + inAttesa.count }

    func load() async {
        guard let id = entitaId else { return }
        items = (try? await HubAPI.listAllegati(entita, id: id)) ?? []
    }

    /// File scelti dal pannello o trascinati dentro. Senza id restano in attesa.
    func aggiungi(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let id = entitaId else { inAttesa.append(contentsOf: urls); return }
        occupato = true; defer { occupato = false }
        var falliti = 0
        for url in urls where !(await carica(url, su: id)) { falliti += 1 }
        if falliti > 0 { errore = "\(falliti) file non caricati." }
        await load()
    }

    /// Chiamata dal form subito dopo aver creato la riga: adesso l'id c'è.
    func salvaInAttesa(su id: String) async {
        entitaId = id
        guard !inAttesa.isEmpty else { return }
        occupato = true; defer { occupato = false }
        var falliti = 0
        for url in inAttesa where !(await carica(url, su: id)) { falliti += 1 }
        inAttesa = []
        if falliti > 0 { errore = "\(falliti) file non caricati." }
        await load()
    }

    func togliInAttesa(_ url: URL) { inAttesa.removeAll { $0 == url } }

    func elimina(_ a: Allegato) async {
        occupato = true; defer { occupato = false }
        do { try await HubAPI.deleteAllegato(a); items.removeAll { $0.id == a.id } }
        catch { errore = "Non si è potuto eliminare l'allegato." }
    }

    /// Scarica in una temp riservata all'app e apre col programma di sistema:
    /// per un controllo al volo il pannello «salva con nome» è di troppo.
    func apri(_ a: Allegato) async {
        occupato = true; defer { occupato = false }
        do {
            let data = try await HubAPI.sb.downloadFile(bucket: "allegati", path: a.file_path)
            let url = appTempDir().appendingPathComponent(a.file_name ?? "allegato.pdf")
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch { errore = "Non si è potuto aprire il file." }
    }

    private func carica(_ url: URL, su id: String) async -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let nome = url.deletingPathExtension().lastPathComponent
            // un UUID nel nome perché due «fattura.pdf» non si sovrascrivano
            let path = "\(entita.rawValue)/\(id)/\(UUID().uuidString)-\(docSlug(nome)).\(ext)"
            _ = try await HubAPI.sb.uploadFile(bucket: "allegati", path: path,
                                               data: data, contentType: docMime(ext))
            try await HubAPI.createAllegato([
                "entita": entita.rawValue, "entita_id": id, "titolo": nome,
                "file_path": path, "file_name": url.lastPathComponent,
                "mime": docMime(ext), "size_bytes": data.count,
            ])
            return true
        } catch { return false }
    }
}

// ── Riquadro allegati, da mettere in un form o in una scheda ────────────────
struct AllegatiBox: View {
    @ObservedObject var store: AllegatiStore
    var titolo: String = "ALLEGATI — FATTURE E RICEVUTE"
    @State private var sopra = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(titolo).font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(Holo.labelDim)
                if store.totale > 0 {
                    Text("\(store.totale)").font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(PSE.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(PSE.accent.opacity(0.16)))
                }
                Spacer()
                if store.occupato { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Button { scegli() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 9.5, weight: .bold))
                        Text("Aggiungi").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(PSE.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(PSE.accent.opacity(0.14)))
                    .contentShape(Capsule())
                }.buttonStyle(.plain).disabled(store.occupato)
            }

            VStack(spacing: 0) {
                if store.items.isEmpty && store.inAttesa.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 11))
                        Text("Trascina qui la fattura, o premi Aggiungi — PDF, foto, scontrini.")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(PSE.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 14)
                } else {
                    ForEach(store.items) { a in rigaSalvata(a) }
                    ForEach(store.inAttesa, id: \.self) { u in rigaInAttesa(u) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(PSE.surface))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(sopra ? PSE.accent.opacity(0.8) : PSE.line,
                              style: StrokeStyle(lineWidth: 1, dash: store.totale == 0 ? [4, 3] : [])))
            .onDrop(of: [.fileURL], isTargeted: $sopra) { providers in
                Task { await store.aggiungi(await urlsDa(providers)) }
                return true
            }

            if let e = store.errore {
                Text(e).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xffb3ad))
            }
            if store.entitaId == nil && !store.inAttesa.isEmpty {
                Text("I file salgono quando salvi il movimento.")
                    .font(.system(size: 10)).foregroundStyle(PSE.faint)
            }
        }
        .task { await store.load() }
    }

    private func rigaSalvata(_ a: Allegato) -> some View {
        HStack(spacing: 9) {
            Image(systemName: iconaPer(a.mime)).font(.system(size: 12)).foregroundStyle(PSE.accent)
                .frame(width: 16)
            Text(a.file_name ?? a.titolo ?? "Allegato")
                .font(.system(size: 11.5)).foregroundStyle(PSE.text).lineLimit(1)
            Spacer(minLength: 6)
            Text(docPeso(a.size_bytes)).font(.system(size: 10)).foregroundStyle(PSE.faint).monospacedDigit()
            Button { Task { await store.apri(a) } } label: {
                Text("Apri").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PSE.accent)
            }.buttonStyle(.plain)
            Button { Task { await store.elimina(a) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PSE.faint).frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func rigaInAttesa(_ u: URL) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(PSE.warn).frame(width: 16)
            Text(u.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(PSE.dim).lineLimit(1)
            Spacer(minLength: 6)
            Text("in attesa").font(.system(size: 10)).foregroundStyle(PSE.warn)
            Button { store.togliInAttesa(u) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PSE.faint).frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func iconaPer(_ mime: String?) -> String {
        (mime ?? "").hasPrefix("image") ? "photo" : "doc.text.fill"
    }

    private func scegli() {
        let urls = scegliDocumenti(multipli: true)
        guard !urls.isEmpty else { return }
        Task { await store.aggiungi(urls) }
    }

    /// I provider del drag&drop consegnano l'URL in modo asincrono, uno a uno.
    private func urlsDa(_ providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for p in providers {
            let url: URL? = await withCheckedContinuation { cont in
                _ = p.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
            }
            if let url, url.isFileURL { out.append(url) }
        }
        return out
    }
}

/// Graffetta da mettere in fondo alla riga di una tabella: dice a colpo d'occhio
/// se quella riga ha la sua prova di carta.
struct AllegatiPin: View {
    let n: Int
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "paperclip").font(.system(size: 9.5, weight: .semibold))
            if n > 1 { Text("\(n)").font(.system(size: 9, weight: .heavy)) }
        }
        .foregroundStyle(n > 0 ? PSE.accent : PSE.faint.opacity(0.35))
    }
}
