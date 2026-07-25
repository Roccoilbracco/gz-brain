import AVKit
import AppKit
import SwiftUI

// ============================================================================
// Video dell'immobile.
//
// Le foto raccontano le stanze, il video racconta il giro: entrare, girarsi,
// vedere quanto è profondo un locale. Stanno nello stesso bucket pubblico
// delle foto, sotto <id>/video/, e in `proprieta.videos` nello stesso formato
// di `photos` — un array di path, l'ordine è quello di presentazione.
//
// Differenza che conta rispetto alle foto: un video non si scarica per
// guardarlo. La scheda mostra un fotogramma come anteprima e la riproduzione
// parte in streaming dall'URL pubblico solo quando si apre il player.
// ============================================================================

/// Il path del video che il player sta mostrando. Involucro minimo perché
/// `.sheet(item:)` vuole un Identifiable e una String non lo è.
struct VideoDaGuardare: Identifiable {
    let id: String
}

// ── Preparazione del file prima del caricamento ─────────────────────────────
//
// Supabase (piano free) rifiuta i file oltre i 50 MB e di spazio ce n'è 1 GB in
// tutto: un girato da telefono, che parte da 150-300 MB al minuto, non entra
// mai. Prima di caricare si ricomprime in mp4 720p — qualità più che
// sufficiente per far vedere un locale — e si scende a 540p se ancora troppo.
enum VideoDaCaricare {
    static let limiteByte = 45 * 1_048_576

    struct Pronto {
        let dati: Data
        let ext: String
        let originale: Int
    }

    static func prepara(_ url: URL) async -> Pronto? {
        let originale = (try? Data(contentsOf: url).count) ?? 0
        // Un file già leggero si carica com'è: ricomprimerlo costerebbe solo
        // qualità e minuti d'attesa.
        if originale > 0, originale <= limiteByte, url.pathExtension.lowercased() == "mp4",
           let d = try? Data(contentsOf: url) {
            return Pronto(dati: d, ext: "mp4", originale: originale)
        }
        for preset in [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPreset640x480] {
            guard let d = await esporta(url, preset: preset) else { continue }
            if d.count <= limiteByte { return Pronto(dati: d, ext: "mp4", originale: originale) }
        }
        // Nessun preset è bastato: si restituisce l'originale e sarà il server
        // a dire di no, con il peso in chiaro nel messaggio d'errore.
        guard let d = try? Data(contentsOf: url) else { return nil }
        return Pronto(dati: d, ext: url.pathExtension.lowercased(), originale: originale)
    }

    private static func esporta(_ url: URL, preset: String) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        // Header all'inizio del file: senza, il player deve scaricare tutto
        // prima di partire invece di leggerlo in streaming.
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        defer { try? FileManager.default.removeItem(at: out) }
        guard export.status == .completed else { return nil }
        return try? Data(contentsOf: out)
    }
}

/// Primo fotogramma utile di ogni video, tenuto in memoria: rigenerarlo a ogni
/// ridisegno significherebbe riaprire il file remoto ogni volta.
@MainActor
final class VideoPosterCache {
    static let shared = VideoPosterCache()
    private let memoria = NSCache<NSString, NSImage>()

    private init() { memoria.countLimit = 60 }

    func poster(_ path: String) async -> NSImage? {
        if let img = memoria.object(forKey: path as NSString) { return img }
        guard let url = HubAPI.urlVideoProprieta(path: path),
              let cg = await Self.fotogramma(url) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        memoria.setObject(img, forKey: path as NSString)
        return img
    }

    func dimentica(_ path: String) {
        memoria.removeObject(forKey: path as NSString)
    }

    /// Un secondo dentro, non il fotogramma zero: molti video iniziano su un
    /// nero o su una panoramica mossa e l'anteprima sarebbe illeggibile.
    private static func fotogramma(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let t = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await gen.image(at: t).image
    }
}

// ── Scheda di un video nella griglia ────────────────────────────────────────
struct VideoProprietaCard: View {
    let path: String
    let onApri: () -> Void
    let onDelete: () -> Void
    @State private var poster: NSImage?
    @State private var caricato = false
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0c1220))
                if let poster {
                    Image(nsImage: poster).resizable().scaledToFill()
                } else if !caricato {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "film").font(.system(size: 22))
                        .foregroundStyle(Csb.secFg.opacity(0.5))
                }
                // Il triangolo dice che è un video anche quando l'anteprima
                // somiglia in tutto a una foto della galleria.
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.black.opacity(hover ? 0.72 : 0.5)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    .scaleEffect(hover ? 1.06 : 1)
            }
            .frame(height: 132)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))

            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(.black.opacity(0.6)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain).padding(5).help("Rimuovi video")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onApri)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("Clic per guardare il video")
        .task(id: path) {
            poster = await VideoPosterCache.shared.poster(path)
            caricato = true
        }
    }
}

// ── Player a tutta finestra ─────────────────────────────────────────────────
struct VideoProprietaSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("VIDEO").font(.system(size: 12, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.titleText)
                Spacer()
                Button { chiudi() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Csb.itemFg)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Csb.tabsBg))
                        .overlay(Circle().strokeBorder(Csb.tabOnBorder, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minWidth: 760, minHeight: 460)
        }
        .background(LinearGradient(colors: [Color(red: 16/255, green: 24/255, blue: 48/255),
                                            Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .onAppear {
            guard let url = HubAPI.urlVideoProprieta(path: path) else { return }
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        // Senza pausa esplicita l'audio continua a suonare dopo la chiusura:
        // il player sopravvive finché SwiftUI non butta via la vista.
        .onDisappear { player?.pause(); player = nil }
    }

    private func chiudi() {
        player?.pause(); player = nil
        dismiss()
    }
}
