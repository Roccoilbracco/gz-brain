import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// ============================================================================
// I borradores — il testo dei contratti tipo, con i segnaposto.
//
// Un PDF caricato non si può riempire: per generare un contratto serve il
// testo. Il borrador è quel testo, scritto una volta con i {{segnaposto}} al
// posto dei nomi e delle cifre, e riusato ogni volta.
//
// Si può partire da zero o importare un file già esistente (PDF, DOCX, RTF,
// TXT): il testo viene estratto e resta modificabile — l'impaginazione del
// file di partenza si perde, i segnaposto si mettono a mano dove servono.
// ============================================================================

struct Borrador: Identifiable, Decodable, Equatable {
    let id: String
    var progetto: String
    var categoria: String
    var nome: String
    var lingua: String
    var corpo: String
    var note: String?
    var archiviato: Bool?
    var created_at: String?

    var cat: DocCategoria { DocCategoria.from(categoria) }
    /// Quanti segnaposto contiene: serve a capire a colpo d'occhio se è un
    /// borrador vero o un testo incollato che non si riempirà mai.
    var segnaposti: Int { DocSegnaposto.trovati(in: corpo).count }
}

extension HubAPI {
    static func listBorradores(progetto: String = "gz-ibiza") async throws -> [Borrador] {
        try await sb.fetch("doc_borradores?select=*&progetto=eq.\(qenc(progetto))&archiviato=is.false&order=categoria.asc,nome.asc")
    }
    @discardableResult
    static func createBorrador(_ f: [String: Any?]) async throws -> Borrador {
        try await sb.insertReturning("doc_borradores", body: f)
    }
    static func updateBorrador(id: String, fields: [String: Any?]) async throws {
        var b = fields; b["updated_at"] = isoNowString()
        try await sb.mutate("doc_borradores?id=eq.\(qenc(id))", method: "PATCH", body: b)
    }
    static func deleteBorrador(id: String) async throws {
        try await sb.mutate("doc_borradores?id=eq.\(qenc(id))", method: "DELETE")
    }
    /// Aggancia l'immobile al proprietario. Si chiama dal generatore: la prima
    /// volta che scegli l'immobile di un proprietario il legame resta scritto,
    /// e la volta dopo non te lo chiede più.
    static func setProprietaOwner(proprietaId: String, ownerId: String?) async throws {
        try await sb.mutate("proprieta?id=eq.\(qenc(proprietaId))", method: "PATCH",
                            body: ["owner_id": ownerId, "updated_at": isoNowString()])
    }
}

/// Percent-encoding per i valori nelle query PostgREST.
func qenc(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
}

// ── I segnaposto disponibili ─────────────────────────────────────────────────
//
// Elenco chiuso e documentato: un segnaposto inventato non si riempie, e un
// contratto che va in firma con «{{propietario.nif}}» stampato dentro è un
// problema serio. Il generatore segnala prima quelli che non riconosce.
struct DocSegnaposto: Identifiable {
    let chiave: String
    let spiega: String
    var id: String { chiave }

    static let gruppi: [(String, [DocSegnaposto])] = [
        ("Documento", [
            .init(chiave: "fecha",     spiega: "Data del documento, per esteso"),
            .init(chiave: "lugar",     spiega: "Luogo della firma (Ibiza)"),
            .init(chiave: "agencia",   spiega: "Nome dell'agenzia"),
        ]),
        ("Proprietario", [
            .init(chiave: "propietario.nombre",    spiega: "Nome e cognome"),
            .init(chiave: "propietario.nif",       spiega: "NIF / NIE / CIF"),
            .init(chiave: "propietario.direccion", spiega: "Domicilio"),
            .init(chiave: "propietario.email",     spiega: "Email"),
            .init(chiave: "propietario.telefono",  spiega: "Telefono"),
        ]),
        ("Immobile", [
            .init(chiave: "inmueble.direccion",   spiega: "Indirizzo"),
            .init(chiave: "inmueble.zona_frase",  spiega: "«, zona X» — vuoto se non c'è zona"),
            .init(chiave: "inmueble.titulo",      spiega: "Titolo dell'annuncio"),
            .init(chiave: "inmueble.referencia",  spiega: "Riferimento interno"),
            .init(chiave: "inmueble.zona",        spiega: "Zona"),
            .init(chiave: "inmueble.ciudad",      spiega: "Città"),
            .init(chiave: "inmueble.m2",          spiega: "Superficie in m²"),
            .init(chiave: "inmueble.habitaciones", spiega: "Numero di camere"),
            .init(chiave: "inmueble.banos",       spiega: "Numero di bagni"),
            .init(chiave: "inmueble.catastro",    spiega: "Riferimento catastale"),
        ]),
        ("Cliente", [
            .init(chiave: "cliente.nombre",    spiega: "Nome e cognome"),
            .init(chiave: "cliente.nif",       spiega: "NIF / NIE / passaporto"),
            .init(chiave: "cliente.direccion", spiega: "Domicilio"),
            .init(chiave: "cliente.email",     spiega: "Email"),
            .init(chiave: "cliente.telefono",  spiega: "Telefono"),
        ]),
        ("Condizioni", [
            .init(chiave: "renta.mensual",     spiega: "Canone mensile del primo anno"),
            .init(chiave: "renta.anual",       spiega: "Canone annuo del primo anno"),
            .init(chiave: "renta.tabla",       spiega: "Tabella dei canoni anno per anno (vuota se il canone non cambia)"),
            .init(chiave: "contrato.inicio",   spiega: "Data di inizio"),
            .init(chiave: "contrato.fin",      spiega: "Data di scadenza"),
            .init(chiave: "contrato.duracion", spiega: "Durata scritta («3 anni»)"),
            .init(chiave: "contrato.meses",    spiega: "Durata in mesi"),
            .init(chiave: "fianza",            spiega: "Fianza: importo e mensilità"),
            .init(chiave: "fianza.importe",    spiega: "Solo l'importo della fianza"),
            .init(chiave: "garantia",          spiega: "Frase sulla garanzia aggiuntiva (vuota se non c'è)"),
            .init(chiave: "garantia.importe",  spiega: "Solo l'importo della garanzia"),
            .init(chiave: "aval",              spiega: "Frase sull'aval bancario (vuota se non c'è)"),
            .init(chiave: "ipc",               spiega: "Frase sull'aggiornamento IPC"),
            .init(chiave: "gastos.tabla",      spiega: "Elenco delle spese e di chi le paga"),
            .init(chiave: "extras.tabla",      spiega: "Le clausole personalizzate aggiunte"),
        ]),
    ]

    static let tutti: [String] = gruppi.flatMap { $0.1.map(\.chiave) }

    /// I segnaposto scritti nel testo, nell'ordine in cui compaiono.
    static func trovati(in corpo: String) -> [String] {
        var out: [String] = []
        var resto = Substring(corpo)
        while let apre = resto.range(of: "{{"), let chiude = resto[apre.upperBound...].range(of: "}}") {
            let chiave = resto[apre.upperBound..<chiude.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if !chiave.isEmpty { out.append(chiave) }
            resto = resto[chiude.upperBound...]
        }
        return out
    }

    /// Quelli che il generatore non saprebbe riempire.
    static func sconosciuti(in corpo: String) -> [String] {
        Array(Set(trovati(in: corpo)).subtracting(tutti)).sorted()
    }
}

// ── Estrazione del testo da un file già esistente ────────────────────────────
//
// Il PDF e il DOCX si leggono, ma quello che ne esce è testo semplice:
// l'impaginazione originale non sopravvive, e va bene — l'impaginazione la
// rifà il generatore.
enum BorradorImport {
    static func testo(da url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string }
        if let s = try? String(contentsOf: url, encoding: .utf8), ext == "txt" || ext == "md" { return s }
        // DOCX, RTF, DOC: NSAttributedString li legge tutti su macOS.
        if let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return a.string
        }
        return nil
    }

    @MainActor static func scegliFile() -> URL? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .rtf, .plainText, UTType(filenameExtension: "docx") ?? .data]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.message = "Scegli il contratto da cui partire: ne prendo il testo, l'impaginazione la rifà GZ Brain."
        return p.runModal() == .OK ? p.urls.first : nil
    }
}

// ── Editor del borrador ──────────────────────────────────────────────────────
struct BorradorEditor: View {
    let progetto: String
    /// nil = nuovo borrador.
    var esistente: Borrador?
    var onSalvato: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var nome = ""
    @State private var categoria: DocCategoria = .alquiler
    @State private var lingua = "es"
    @State private var corpo = ""
    @State private var salvando = false
    @State private var errore: String?

    var body: some View {
        HStack(spacing: 0) {
            testo
            Divider().overlay(UI.line)
            elenco.frame(width: 260)
        }
        .frame(width: 980, height: 660)
        .background(UI.panel)
        .preferredColorScheme(.dark)
        .onAppear(perform: precarica)
    }

    private var testo: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(esistente == nil ? "NUOVO BORRADOR" : "MODIFICA BORRADOR")
                    .font(.system(size: 12, weight: .heavy)).tracking(1.6).foregroundStyle(UI.ink)
                Spacer()
                GhostButton(label: "Importa da file", icon: "square.and.arrow.down") { importa() }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    etichetta("Nome")
                    TextField("es. Contrato de arrendamiento de vivienda", text: $nome)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(UI.ink)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 5) {
                    etichetta("Tipo")
                    Menu {
                        ForEach(DocCategoria.allCases) { c in Button(c.label) { categoria = c } }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: categoria.icon).font(.system(size: 10))
                            Text(categoria.labelBreve).font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        }.foregroundStyle(UI.text).lineLimit(1)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
                    .frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 5) {
                    etichetta("Lingua")
                    Menu {
                        ForEach(["es", "it", "en"], id: \.self) { l in Button(l.uppercased()) { lingua = l } }
                    } label: {
                        Text(lingua.uppercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
                    .frame(width: 80)
                }
            }

            TextEditor(text: $corpo)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UI.line, lineWidth: 1))

            if let e = errore {
                Text(e).font(.system(size: 11)).foregroundStyle(UI.tint(.stop))
            }
            let ignoti = DocSegnaposto.sconosciuti(in: corpo)
            if !ignoti.isEmpty {
                Text("Segnaposto che non so riempire: \(ignoti.map { "{{\($0)}}" }.joined(separator: ", ")). Resterebbero stampati nel contratto.")
                    .font(.system(size: 10.5)).foregroundStyle(UI.tint(.attesa))
            }

            HStack(spacing: 10) {
                Text("**grassetto**, «# Titolo» e «## Sottotitolo» diventano formattazione nel PDF.")
                    .font(.system(size: 10.5)).foregroundStyle(UI.faint)
                Spacer()
                GhostButton(label: "Annulla") { dismiss() }
                Button { salva() } label: {
                    Text(salvando ? "Salvo…" : "Salva borrador")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.ink)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(UI.accent.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .disabled(salvando || nome.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(nome.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
    }

    private var elenco: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SEGNAPOSTO").font(.system(size: 9.5, weight: .heavy)).tracking(1.5)
                .foregroundStyle(UI.dim).padding(EdgeInsets(top: 18, leading: 16, bottom: 10, trailing: 16))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(DocSegnaposto.gruppi, id: \.0) { gruppo, voci in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(gruppo.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.1)
                                .foregroundStyle(UI.faint)
                            ForEach(voci) { v in
                                Button { corpo += "{{\(v.chiave)}}" } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("{{\(v.chiave)}}")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(UI.accent)
                                        Text(v.spiega).font(.system(size: 9.5)).foregroundStyle(UI.faint)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Aggiungi in fondo al testo")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 18)
            }
        }
        .background(Color.black.opacity(0.15))
    }

    private func etichetta(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.2).foregroundStyle(UI.faint)
    }

    private func precarica() {
        guard let b = esistente else { return }
        nome = b.nome; categoria = b.cat; lingua = b.lingua; corpo = b.corpo
    }

    private func importa() {
        guard let url = BorradorImport.scegliFile() else { return }
        guard let t = BorradorImport.testo(da: url) else {
            errore = "Da questo file non riesco a estrarre testo (se è un PDF scansionato non c'è testo da prendere)."
            return
        }
        errore = nil
        corpo = t
        if nome.trimmingCharacters(in: .whitespaces).isEmpty {
            nome = url.deletingPathExtension().lastPathComponent
        }
    }

    private func salva() {
        salvando = true; errore = nil
        let campi: [String: Any?] = [
            "progetto": progetto, "categoria": categoria.rawValue,
            "nome": nome.trimmingCharacters(in: .whitespaces),
            "lingua": lingua, "corpo": corpo,
        ]
        Task {
            do {
                if let b = esistente { try await HubAPI.updateBorrador(id: b.id, fields: campi) }
                else { _ = try await HubAPI.createBorrador(campi) }
                await MainActor.run { salvando = false; onSalvato(); dismiss() }
            } catch {
                await MainActor.run { salvando = false; errore = error.localizedDescription }
            }
        }
    }
}
