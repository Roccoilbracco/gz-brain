import SwiftUI
import AppKit

// ============================================================================
// Camere PSE — Storico contabile · REPORT PDF
// Il riepilogo di un periodo (o di una casa sola) su carta, da mandare al
// socio. Fondo chiaro e non il tema scuro dell'app: questo si stampa e si
// legge, non si guarda su uno schermo al buio.
// Due pagine: la prima racconta, la seconda dettaglia.
// ============================================================================

struct RigaReport: Identifiable {
    let voce: String
    let viaPo: Int
    let viaRomagna: Int
    let comune: Int
    var totale: Int { viaPo + viaRomagna + comune }
    var id: String { voce }
}

struct StoricoReport {
    var titolo: String            // «Tutte le case» oppure «Via Po»
    var periodo: String
    var intervallo: String
    var generatoIl: String

    // affitto
    var lordo = 0, commissioni = 0, netto = 0, speseAlloggio = 0
    var soggiorni = 0, notti = 0
    var lordoViaPo = 0, lordoViaRomagna = 0
    var risultato: Int { netto - speseAlloggio }
    var mediaNotte: Int { notti > 0 ? lordo / notti : 0 }

    // l'affitto copre mutuo e utenze?
    var mutuo = 0, utenze = 0
    var restaCorrente: Int { netto - mutuo - utenze }

    // dove sono andati i soldi
    var investimento: [RigaReport] = []
    var gestione: [RigaReport] = []
    var restituzioni = 0
    var totInvestimento: Int { investimento.reduce(0) { $0 + $1.totale } }
    var totGestione: Int { gestione.reduce(0) { $0 + $1.totale } }
    var totSpeso: Int { totInvestimento + totGestione }

    // soci
    var giorgio = 0, giacomo = 0, conguaglio = 0
    var mostraSoci = true

    // a chi
    var fornitori: [(String, Int)] = []

    // come l'abbiamo pagato
    var mutui = 0, prestiti = 0, affittiReinvestiti = 0, messoDaiSoci = 0, restituito = 0
    var daBanche: Int { mutui + prestiti }

    // casa per casa (solo nel report generale)
    var case_: [(String, Int, Int, Int)] = []   // nome, affitti, mutuo, utenze
}

@MainActor
enum StoricoPDF {
    static func render(_ r: StoricoReport) -> Data? {
        let pdf = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for pagina in [AnyView(ReportPagina1(r: r)), AnyView(ReportPagina2(r: r))] {
            let renderer = ImageRenderer(content: pagina.frame(width: 595, height: 842))
            renderer.scale = 3
            renderer.render { _, disegna in
                ctx.beginPDFPage(nil)
                disegna(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return pdf.isEmpty ? nil : (pdf as Data)
    }

    /// Chiede dove salvare e scrive il file.
    static func salva(_ r: StoricoReport) {
        guard let dati = render(r) else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "Camere PSE — \(r.titolo) \(r.periodo).pdf"
        p.allowedContentTypes = [.pdf]
        if p.runModal() == .OK, let url = p.url { try? dati.write(to: url) }
    }
}

// ── Palette da carta ────────────────────────────────────────────────────────
private enum Carta {
    static let sfondo = Color(hex: 0xffffff)
    static let inchiostro = Color(hex: 0x14181f)
    static let tenue = Color(hex: 0x6b7280)
    static let riga = Color(hex: 0xe5e7eb)
    static let cassa = Color(hex: 0xf7f8fa)
    static let blu = Color(hex: 0x3b5a80)
    static let verde = Color(hex: 0x2f7d5d)
    static let rosso = Color(hex: 0xb2543f)
    static let ambra = Color(hex: 0xb07c3a)
}

private func e(_ c: Int) -> String { eurc(c) }

// ── Pezzi comuni ────────────────────────────────────────────────────────────
private struct Testata: View {
    let r: StoricoReport
    let pagina: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("CAMERE PSE").font(.system(size: 15, weight: .black)).tracking(2).foregroundStyle(Carta.inchiostro)
                Text("Via Po & Via Romagna · Porto Sant'Elpidio")
                    .font(.system(size: 9)).foregroundStyle(Carta.tenue)
                Spacer()
                Text(pagina).font(.system(size: 8, weight: .bold)).foregroundStyle(Carta.tenue)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.titolo).font(.system(size: 20, weight: .heavy)).foregroundStyle(Carta.blu)
                Text(r.periodo).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Carta.blu))
                Text(r.intervallo).font(.system(size: 9.5)).foregroundStyle(Carta.tenue)
                Spacer()
                Text("generato il \(r.generatoIl)").font(.system(size: 8)).foregroundStyle(Carta.tenue)
            }
            Rectangle().fill(Carta.blu).frame(height: 2).padding(.top, 2)
        }
    }
}

private struct Titolo: View {
    let t: String
    var nota: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.system(size: 9, weight: .black)).tracking(1.1).foregroundStyle(Carta.blu)
            if !nota.isEmpty { Text(nota).font(.system(size: 8)).foregroundStyle(Carta.tenue) }
        }
    }
}

private struct Cifra: View {
    let t: String, v: String, c: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 6.5, weight: .black)).tracking(0.5).foregroundStyle(Carta.tenue)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(v).font(.system(size: 13, weight: .heavy)).foregroundStyle(c)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Carta.cassa))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Carta.riga, lineWidth: 0.8))
    }
}

private struct Barra: View {
    let titolo: String, v: Int, scala: Int, c: Color
    var body: some View {
        HStack(spacing: 8) {
            Text(titolo).font(.system(size: 8.5)).foregroundStyle(Carta.tenue)
                .frame(width: 110, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Carta.riga)
                    RoundedRectangle(cornerRadius: 2).fill(c)
                        .frame(width: max(2, g.size.width * CGFloat(v) / CGFloat(max(scala, 1))))
                }
            }
            .frame(height: 9)
            Text(e(v)).font(.system(size: 9, weight: .bold)).foregroundStyle(c)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

private struct Tabella: View {
    let righe: [RigaReport]
    let colore: Color
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("VOCE").font(.system(size: 6.5, weight: .black)).tracking(0.5).foregroundStyle(Carta.tenue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(["VIA PO", "VIA ROMAGNA", "COMUNE", "TOTALE"], id: \.self) { t in
                    Text(t).font(.system(size: 6.5, weight: .black)).tracking(0.5).foregroundStyle(Carta.tenue)
                        .frame(width: 74, alignment: .trailing)
                }
            }
            .padding(.vertical, 4)
            Rectangle().fill(Carta.riga).frame(height: 0.8)
            ForEach(righe) { r in
                HStack(spacing: 6) {
                    Text(r.voce).font(.system(size: 9)).foregroundStyle(Carta.inchiostro)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    cella(r.viaPo); cella(r.viaRomagna); cella(r.comune)
                    Text(e(r.totale)).font(.system(size: 9, weight: .bold)).foregroundStyle(colore)
                        .frame(width: 74, alignment: .trailing)
                }
                .padding(.vertical, 3.5)
                Rectangle().fill(Carta.riga.opacity(0.6)).frame(height: 0.5)
            }
            HStack(spacing: 6) {
                Text("TOTALE").font(.system(size: 8.5, weight: .black)).foregroundStyle(Carta.inchiostro)
                    .frame(maxWidth: .infinity, alignment: .leading)
                cella(righe.reduce(0) { $0 + $1.viaPo }, forte: true)
                cella(righe.reduce(0) { $0 + $1.viaRomagna }, forte: true)
                cella(righe.reduce(0) { $0 + $1.comune }, forte: true)
                Text(e(righe.reduce(0) { $0 + $1.totale })).font(.system(size: 10, weight: .black))
                    .foregroundStyle(colore).frame(width: 74, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .background(Carta.cassa)
        }
    }
    private func cella(_ v: Int, forte: Bool = false) -> some View {
        Text(v == 0 ? "—" : e(v))
            .font(.system(size: 9, weight: forte ? .bold : .regular))
            .foregroundStyle(v == 0 ? Carta.tenue.opacity(0.5) : Carta.inchiostro)
            .frame(width: 74, alignment: .trailing)
    }
}

// ── Pagina 1: il racconto ───────────────────────────────────────────────────
private struct ReportPagina1: View {
    let r: StoricoReport
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Testata(r: r, pagina: "1 / 2")
            affitto
            copertura
            dove
            if !r.case_.isEmpty { perCasa } else { dettaglioCasa }
            Spacer(minLength: 0)
            piede
        }
        .padding(34)
        .frame(width: 595, height: 842, alignment: .topLeading)
        .background(Carta.sfondo)
        .environment(\.colorScheme, .light)
    }

    private var affitto: some View {
        VStack(alignment: .leading, spacing: 6) {
            Titolo(t: "ATTIVITÀ DI AFFITTO", nota: "\(r.soggiorni) soggiorni · \(r.notti) notti · media \(e(r.mediaNotte)) a notte")
            HStack(spacing: 6) {
                Cifra(t: "INCASSI LORDI", v: e(r.lordo), c: Carta.verde)
                Cifra(t: "COMMISSIONI", v: r.commissioni > 0 ? "−" + e(r.commissioni) : e(0), c: Carta.rosso)
                Cifra(t: "INCASSI NETTI", v: e(r.netto), c: Carta.inchiostro)
                Cifra(t: "SPESE DI ALLOGGIO", v: r.speseAlloggio > 0 ? "−" + e(r.speseAlloggio) : e(0), c: Carta.rosso)
                Cifra(t: "RISULTATO", v: e(r.risultato), c: r.risultato >= 0 ? Carta.verde : Carta.rosso)
            }
        }
    }

    private var copertura: some View {
        VStack(alignment: .leading, spacing: 6) {
            Titolo(t: "L'AFFITTO È BASTATO A PAGARE MUTUO E UTENZE?",
                   nota: r.restaCorrente >= 0 ? "Sì: dopo mutuo e utenze restano \(e(r.restaCorrente))."
                                              : "No: mancano \(e(abs(r.restaCorrente))).")
            VStack(spacing: 5) {
                Barra(titolo: "Affitti incassati", v: r.netto, scala: max(r.netto, r.mutuo + r.utenze), c: Carta.verde)
                Barra(titolo: "Mutuo + utenze", v: r.mutuo + r.utenze, scala: max(r.netto, r.mutuo + r.utenze), c: Carta.rosso)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Carta.cassa))
        }
    }

    private var dove: some View {
        VStack(alignment: .leading, spacing: 6) {
            Titolo(t: "DOVE SONO ANDATI I SOLDI",
                   nota: "Investimento = quello che resta dentro l'immobile. Gestione = quello che se ne va ogni mese.")
            HStack(spacing: 6) {
                Cifra(t: "INVESTIMENTO", v: e(r.totInvestimento), c: Carta.blu)
                Cifra(t: "GESTIONE", v: e(r.totGestione), c: Carta.ambra)
                Cifra(t: "TOTALE SPESO", v: e(r.totSpeso), c: Carta.inchiostro)
                Cifra(t: "QUOTA INVESTIMENTO",
                      v: r.totSpeso > 0 ? "\(Int((Double(r.totInvestimento) / Double(r.totSpeso) * 100).rounded()))%" : "—",
                      c: Carta.blu)
            }
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    Rectangle().fill(Carta.blu)
                        .frame(width: max(2, g.size.width * CGFloat(r.totInvestimento) / CGFloat(max(r.totSpeso, 1))))
                    Rectangle().fill(Carta.ambra)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 11)
            if r.restituzioni > 0 {
                Text("Restituzioni: \(e(r.restituzioni)) tornati ai soci e a chi aveva prestato. Non sono una spesa e restano fuori dal totale.")
                    .font(.system(size: 7.5)).foregroundStyle(Carta.tenue)
            }
        }
    }

    private var perCasa: some View {
        VStack(alignment: .leading, spacing: 6) {
            Titolo(t: "CASA PER CASA", nota: "Affitti incassati contro mutuo e utenze di ciascuna.")
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("CASA").font(.system(size: 6.5, weight: .black)).tracking(0.5).foregroundStyle(Carta.tenue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(["AFFITTI", "MUTUO", "UTENZE", "RESTA"], id: \.self) { t in
                        Text(t).font(.system(size: 6.5, weight: .black)).tracking(0.5).foregroundStyle(Carta.tenue)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
                Rectangle().fill(Carta.riga).frame(height: 0.8)
                ForEach(r.case_.indices, id: \.self) { i in
                    let c = r.case_[i]
                    let resta = c.1 - c.2 - c.3
                    HStack(spacing: 6) {
                        Text(c.0).font(.system(size: 9, weight: .semibold)).foregroundStyle(Carta.inchiostro)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(e(c.1)).font(.system(size: 9)).foregroundStyle(Carta.verde).frame(width: 74, alignment: .trailing)
                        Text(e(c.2)).font(.system(size: 9)).foregroundStyle(Carta.inchiostro).frame(width: 74, alignment: .trailing)
                        Text(c.3 == 0 ? "—" : e(c.3)).font(.system(size: 9)).foregroundStyle(Carta.inchiostro).frame(width: 74, alignment: .trailing)
                        Text((resta >= 0 ? "" : "−") + e(abs(resta))).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(resta >= 0 ? Carta.verde : Carta.rosso).frame(width: 74, alignment: .trailing)
                    }
                    .padding(.vertical, 3.5)
                    Rectangle().fill(Carta.riga.opacity(0.6)).frame(height: 0.5)
                }
            }
        }
    }

    /// Nel report di una casa sola non c'è la tabella «casa per casa»: al suo
    /// posto va il dettaglio delle due colonne, se no la pagina resta vuota.
    private var dettaglioCasa: some View {
        HStack(alignment: .top, spacing: 16) {
            colonna("QUANTO COSTA TENERLA APERTA", r.gestione, r.totGestione, Carta.ambra)
            colonna("QUANTO CI ABBIAMO MESSO DENTRO", r.investimento, r.totInvestimento, Carta.blu)
        }
    }

    private func colonna(_ titolo: String, _ righe: [RigaReport], _ totale: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(titolo).font(.system(size: 8, weight: .black)).tracking(0.8).foregroundStyle(Carta.blu)
                Spacer()
                Text(e(totale)).font(.system(size: 9, weight: .bold)).foregroundStyle(c)
            }
            ForEach(righe) { v in
                HStack(spacing: 6) {
                    Text(v.voce).font(.system(size: 8.5)).foregroundStyle(Carta.inchiostro)
                        .frame(width: 96, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Carta.riga)
                            RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.75))
                                .frame(width: max(2, g.size.width * CGFloat(v.totale) / CGFloat(max(totale, 1))))
                        }
                    }
                    .frame(height: 7)
                    Text(e(v.totale)).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Carta.inchiostro)
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var piede: some View {
        Text("Contabilità chiusa del periodo, tenuta a parte dalla gestione corrente di Camere PSE. I dati da ottobre 2025 a giugno 2026 provengono in buona parte da chat e note: ogni riga porta la sua fonte nell'archivio.")
            .font(.system(size: 7)).foregroundStyle(Carta.tenue)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// ── Pagina 2: il dettaglio ──────────────────────────────────────────────────
private struct ReportPagina2: View {
    let r: StoricoReport
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Testata(r: r, pagina: "2 / 2")
            if !r.investimento.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Titolo(t: "INVESTIMENTO — COMPRARE E SISTEMARE LE CASE")
                    Tabella(righe: r.investimento, colore: Carta.blu)
                }
            }
            if !r.gestione.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Titolo(t: "GESTIONE — FAR GIRARE LE CASE")
                    Tabella(righe: r.gestione, colore: Carta.ambra)
                }
            }
            if !r.fornitori.isEmpty { aChi }
            if r.mostraSoci { comePagato }
            if r.mostraSoci { soci }
            Spacer(minLength: 0)
        }
        .padding(34)
        .frame(width: 595, height: 842, alignment: .topLeading)
        .background(Carta.sfondo)
        .environment(\.colorScheme, .light)
    }

    private var aChi: some View {
        VStack(alignment: .leading, spacing: 6) {
            Titolo(t: "A CHI ABBIAMO PAGATO", nota: "I primi per importo, sull'investimento nelle case.")
            VStack(spacing: 0) {
                ForEach(r.fornitori.prefix(12).indices, id: \.self) { i in
                    let f = r.fornitori[i]
                    let q = r.totInvestimento > 0 ? Double(f.1) / Double(r.totInvestimento) : 0
                    HStack(spacing: 8) {
                        Text(f.0).font(.system(size: 9)).foregroundStyle(Carta.inchiostro)
                            .frame(width: 140, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Carta.riga)
                                RoundedRectangle(cornerRadius: 2).fill(Carta.blu.opacity(0.75))
                                    .frame(width: max(2, g.size.width * q))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int((q * 100).rounded()))%").font(.system(size: 8)).foregroundStyle(Carta.tenue)
                            .frame(width: 26, alignment: .trailing)
                        Text(e(f.1)).font(.system(size: 9, weight: .bold)).foregroundStyle(Carta.inchiostro)
                            .frame(width: 76, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    /// Chi ha messo i soldi: senza questo, l'investimento sembra tutto uscito
    /// dalle tasche dei due soci.
    private var comePagato: some View {
        VStack(alignment: .leading, spacing: 6) {
            Titolo(t: "COME L'ABBIAMO PAGATO",
                   nota: "Di \(e(r.totInvestimento)) investiti, \(e(r.daBanche)) sono arrivati da banca e prestiti: soldi da restituire, non nostri.")
            HStack(spacing: 6) {
                Cifra(t: "MUTUI EROGATI", v: e(r.mutui), c: Carta.blu)
                Cifra(t: "PRESTITI RICEVUTI", v: e(r.prestiti), c: Carta.blu)
                Cifra(t: "REINVESTITO DAGLI AFFITTI", v: e(r.affittiReinvestiti), c: Carta.verde)
                Cifra(t: "MESSO DAI SOCI", v: e(r.messoDaiSoci), c: Carta.inchiostro)
                Cifra(t: "GIÀ RESTITUITO", v: e(r.restituito), c: Carta.tenue)
            }
            Text("Le cifre non tornano al centesimo: una parte di questi soldi ha pagato anche la gestione, non solo l'investimento. «Messo dai soci» è già al netto delle restituzioni ricevute.")
                .font(.system(size: 7.5)).foregroundStyle(Carta.tenue)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var soci: some View {
        VStack(alignment: .leading, spacing: 6) {
            Titolo(t: "SOCI E CONGUAGLIO", nota: "Su tutto lo storico, non solo su questo periodo: il conguaglio è uno solo.")
            HStack(spacing: 6) {
                Cifra(t: "MESSO DA GIORGIO", v: e(r.giorgio), c: Carta.inchiostro)
                Cifra(t: "MESSO DA GIACOMO", v: e(r.giacomo), c: Carta.inchiostro)
                Cifra(t: "DIFFERENZA", v: e(abs(r.giorgio - r.giacomo)), c: Carta.tenue)
                Cifra(t: r.giorgio >= r.giacomo ? "GIACOMO DEVE A GIORGIO" : "GIORGIO DEVE A GIACOMO",
                      v: e(abs(r.conguaglio)), c: Carta.blu)
            }
            Text("Ognuno dovrebbe metterci la metà: si sommano gli apporti, si fa la differenza e si divide per due. Le restituzioni stanno dentro col segno meno. Restano fuori dal conto le rate pagate con l'incasso degli affitti, i rimborsi già risolti e il lavoro dei genitori di Giacomo.")
                .font(.system(size: 7.5)).foregroundStyle(Carta.tenue)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
