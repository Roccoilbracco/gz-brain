import AppKit
import CoreText

// ============================================================================
// Il contratto riempito diventa un PDF A4 di più pagine.
//
// La fattura si disegna con ImageRenderer perché sta in una pagina sola e ha
// una forma fissa. Un contratto no: è testo lungo, che deve andare a capo da
// solo e traboccare nella pagina dopo. Quello lo sa fare CoreText, che
// impagina finché il testo finisce.
//
// Il testo arriva con una formattazione minima — «# titolo», «## sezione»,
// «**grassetto**», «- elenco» — perché il borrador si scrive in una casella di
// testo, non in un editor di documenti.
// ============================================================================

enum ContrattoPDF {
    private static let pagina = CGSize(width: 595, height: 842)   // A4 a 72 dpi
    private static let margine: CGFloat = 64
    private static let alto: CGFloat = 62
    private static let basso: CGFloat = 66

    static func render(titolo: String, testo: String, piede: String) -> Data? {
        let attr = attributed(testo)
        guard attr.length > 0 else { return nil }

        let setter = CTFramesetterCreateWithAttributedString(attr)
        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: pagina)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        let colonna = CGRect(x: margine, y: basso,
                             width: pagina.width - margine * 2,
                             height: pagina.height - alto - basso)
        let percorso = CGPath(rect: colonna, transform: nil)

        var inizio = 0
        var numero = 0
        // Il tetto è una rete di sicurezza: se per un errore di misura il frame
        // smettesse di consumare testo, meglio un PDF tronco che un ciclo che
        // non finisce mai.
        while inizio < attr.length && numero < 200 {
            numero += 1
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(box)

            let frame = CTFramesetterCreateFrame(setter, CFRangeMake(inizio, 0), percorso, nil)
            CTFrameDraw(frame, ctx)
            let visibile = CTFrameGetVisibleStringRange(frame)
            if visibile.length <= 0 { ctx.endPDFPage(); break }
            inizio += visibile.length

            disegnaPiede(ctx, testo: piede, titolo: titolo, numero: numero)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out.isEmpty ? nil : (out as Data)
    }

    // ── Piede di pagina: chi lo ha prodotto e a che pagina siamo ─────────────
    private static func disegnaPiede(_ ctx: CGContext, testo: String, titolo: String, numero: Int) {
        ctx.setStrokeColor(CGColor(gray: 0.78, alpha: 1))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margine, y: basso - 22))
        ctx.addLine(to: CGPoint(x: pagina.width - margine, y: basso - 22))
        ctx.strokePath()

        let stile = NSMutableParagraphStyle()
        stile.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: serif(7.5),
            .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
            .paragraphStyle: stile,
        ]
        disegnaRiga(ctx, NSAttributedString(string: testo, attributes: attrs),
                    x: margine, y: basso - 36)

        let dx = NSMutableParagraphStyle(); dx.alignment = .right
        var a2 = attrs; a2[.paragraphStyle] = dx
        let pag = NSAttributedString(string: "\(numero)", attributes: a2)
        let larghezza = pag.size().width
        disegnaRiga(ctx, pag, x: pagina.width - margine - larghezza, y: basso - 36)
        _ = titolo
    }

    private static func disegnaRiga(_ ctx: CGContext, _ s: NSAttributedString, x: CGFloat, y: CGFloat) {
        let linea = CTLineCreateWithAttributedString(s)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(linea, ctx)
    }

    // ── Dal testo semplice alla stringa formattata ───────────────────────────
    static func attributed(_ testo: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for riga in testo.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            out.append(paragrafo(riga))
        }
        return out
    }

    private static func paragrafo(_ riga: String) -> NSAttributedString {
        let t = riga.trimmingCharacters(in: .whitespaces)

        if t.hasPrefix("# ") {
            return blocco(String(t.dropFirst(2)), size: 15, bold: true,
                          allinea: .center, sopra: 6, sotto: 14, tracking: 0.6)
        }
        if t.hasPrefix("## ") {
            return blocco(String(t.dropFirst(3)), size: 11, bold: true,
                          allinea: .left, sopra: 14, sotto: 6, tracking: 1.1)
        }
        if t.hasPrefix("- ") || t.hasPrefix("• ") {
            return blocco("•  " + String(t.dropFirst(2)), size: 10.5, bold: false,
                          allinea: .left, sopra: 0, sotto: 3, rientro: 16)
        }
        if t.isEmpty {
            // Riga vuota vera: senza un corpo suo, l'elenco puntato e il
            // paragrafo che lo segue si appiccicavano.
            return NSAttributedString(string: "\n", attributes: [.font: serif(8)])
        }
        return blocco(t, size: 10.5, bold: false, allinea: .justified, sopra: 0, sotto: 7)
    }

    private static func blocco(_ testo: String, size: CGFloat, bold: Bool,
                               allinea: NSTextAlignment, sopra: CGFloat, sotto: CGFloat,
                               rientro: CGFloat = 0, tracking: CGFloat = 0) -> NSAttributedString {
        let stile = NSMutableParagraphStyle()
        stile.alignment = allinea
        stile.lineSpacing = 2.2
        stile.paragraphSpacingBefore = sopra
        stile.paragraphSpacing = sotto
        stile.firstLineHeadIndent = rientro > 0 ? 0 : 0
        stile.headIndent = rientro
        stile.lineBreakMode = .byWordWrapping

        let base: [NSAttributedString.Key: Any] = [
            .font: bold ? serifBold(size) : serif(size),
            .foregroundColor: NSColor.black,
            .paragraphStyle: stile,
            .kern: tracking,
        ]
        let out = NSMutableAttributedString()
        // **grassetto** dentro la riga: si alterna a ogni doppio asterisco.
        var grassetto = bold
        for (i, pezzo) in testo.components(separatedBy: "**").enumerated() {
            if i > 0 { grassetto.toggle() }
            guard !pezzo.isEmpty else { continue }
            var a = base
            a[.font] = grassetto ? serifBold(size) : serif(size)
            out.append(NSAttributedString(string: pezzo, attributes: a))
        }
        out.append(NSAttributedString(string: "\n", attributes: base))
        return out
    }

    private static func serif(_ s: CGFloat) -> NSFont {
        NSFont(name: "Times New Roman", size: s) ?? NSFont.systemFont(ofSize: s)
    }
    private static func serifBold(_ s: CGFloat) -> NSFont {
        NSFont(name: "Times New Roman Bold", size: s)
            ?? NSFont(name: "TimesNewRomanPS-BoldMT", size: s)
            ?? NSFont.boldSystemFont(ofSize: s)
    }
}
