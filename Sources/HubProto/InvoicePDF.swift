import SwiftUI
import AppKit

// ─── Dati pronti per il rendering (nessuna rete dentro la view) ───
struct InvoiceData {
    struct Riga { let desc: String; let qta: String; let prezzoC: Int; let totaleC: Int }
    var azienda: AziendaSettings
    var clienteNome: String
    var clienteRiga: String          // "indirizzo - VAT Number: ..."
    var numero: String               // "2026006"
    var data: String                 // "01/06/2026"
    var righe: [Riga]
    var imponibileC: Int
    var ivaC: Int
    var totaleC: Int
    var vatNote: String
    var logo: NSImage?
}

// ─── Render SwiftUI → PDF vettoriale (A4) ───
@MainActor
enum InvoicePDF {
    static func render(_ doc: InvoiceData) -> Data? {
        let pdf = NSMutableData()
        let renderer = ImageRenderer(content: InvoiceDocumentView(doc: doc).frame(width: 595, height: 842))
        renderer.scale = 4   // rasterizza il logo (immagine) ad alta risoluzione → linee nitide
        renderer.render { size, renderInContext in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return pdf.isEmpty ? nil : (pdf as Data)
    }
}

// ─── Template fattura "Verde" (card morbide, accenti verdi, tile logo nero) ───
struct InvoiceDocumentView: View {
    let doc: InvoiceData

    // palette
    private let pageBg = Color(hex: 0xfbfbfc)
    private let dark   = Color(hex: 0x065f46)
    private let acc    = Color(hex: 0x10b981)
    private let acc2   = Color(hex: 0x059669)
    private let accBg  = Color(hex: 0xecfdf6)
    private let cardBd = Color(hex: 0xe9e9ec)
    private let ink    = Color(hex: 0x111111)
    private let gray   = Color(hex: 0x777777)
    private let grayL  = Color(hex: 0x999999)

    var body: some View {
        ZStack(alignment: .top) {
            pageBg
            // barra superiore a gradiente
            LinearGradient(colors: [acc, acc2], startPoint: .leading, endPoint: .trailing)
                .frame(height: 5)
            VStack(alignment: .leading, spacing: 14) {
                header
                cardsRow
                itemsTable
                totalsBlock
                Spacer(minLength: 0)
                footer
            }
            .padding(EdgeInsets(top: 30, leading: 34, bottom: 30, trailing: 34))
        }
        .frame(width: 595, height: 842)
        .environment(\.colorScheme, .light)
    }

    // ── Header: tile logo nero + azienda | chip INVOICE + data/vat ──
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 13) {
                logoTile.frame(width: 82, height: 82)
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.azienda.ragione_sociale ?? "").font(.system(size: 18, weight: .heavy)).foregroundStyle(ink)
                    ForEach(addressLines, id: \.self) {
                        Text($0).font(.system(size: 10)).foregroundStyle(grayL)
                    }
                    if let vat = doc.azienda.vat_number {
                        Text("VAT Number: \(vat)").font(.system(size: 10)).foregroundStyle(grayL)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 9) {
                Text("INVOICE · \(doc.numero)")
                    .font(.system(size: 11, weight: .heavy)).tracking(0.6).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [acc, acc2], startPoint: .topLeading, endPoint: .bottomTrailing)))
                Text(doc.data).font(.system(size: 10.5)).foregroundStyle(gray)
            }
        }
    }

    // ── Riga card: Fatturato a | Contatti ──
    private var cardsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            card(leftAccent: true) {
                cardLabel("FATTURATO A")
                Text(doc.clienteNome).font(.system(size: 13.5, weight: .bold)).foregroundStyle(ink).lineLimit(1)
                ForEach(clientLines, id: \.self) {
                    Text($0).font(.system(size: 10)).foregroundStyle(gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            card(leftAccent: false) {
                cardLabel("CONTATTI")
                VStack(alignment: .leading, spacing: 3) {
                    if let w = doc.azienda.website { Text(w).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x555555)) }
                    if let e = doc.azienda.email { Text(e).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x555555)) }
                }.padding(.top, 4)
            }
            .frame(width: 188, alignment: .leading)
        }
    }

    // ── Tabella righe (dentro card bianca) ──
    private var itemsTable: some View {
        let padded = doc.righe + Array(repeating: InvoiceData.Riga(desc: "", qta: "", prezzoC: -1, totaleC: -1),
                                       count: max(0, 3 - doc.righe.count))
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
                Text("QTÀ").frame(width: 70, alignment: .center)
                Text("PREZZO").frame(width: 95, alignment: .trailing)
                Text("TOTALE").frame(width: 95, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(acc)
            .padding(.top, 14).padding(.bottom, 9)
            Rectangle().fill(accBg).frame(height: 1.6)
            ForEach(Array(padded.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 0) {
                    Text(r.desc).foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.qta).foregroundStyle(ink).frame(width: 70, alignment: .center)
                    Text(r.prezzoC >= 0 ? Money.eur(r.prezzoC) : "").foregroundStyle(ink).frame(width: 95, alignment: .trailing)
                    Text(r.totaleC >= 0 ? Money.eur(r.totaleC) : "")
                        .fontWeight(.bold).foregroundStyle(dark).frame(width: 95, alignment: .trailing)
                }
                .font(.system(size: 11.5))
                .frame(height: 38)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(cardBd, lineWidth: 1))
    }

    // ── Totali (card verde tenue) + nota IVA sotto, su 2 righe ──
    private var totalsBlock: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    totRow("Subtotale", Money.eur(doc.imponibileC), big: false)
                    totRow("IVA", doc.ivaC == 0 ? "0,00" : Money.eur(doc.ivaC), big: false)
                    Rectangle().fill(acc.opacity(0.22)).frame(height: 1).padding(.vertical, 5)
                    totRow("Totale", Money.eur(doc.totaleC), big: true)
                }
                .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
                .background(RoundedRectangle(cornerRadius: 13).fill(accBg))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(acc.opacity(0.25), lineWidth: 1))
                if !doc.vatNote.isEmpty {
                    Text(doc.vatNote).font(.system(size: 8.5)).foregroundStyle(grayL)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 258)
        }
        .padding(.top, 4)
    }
    private func totRow(_ l: String, _ v: String, big: Bool) -> some View {
        HStack {
            Text(l).font(.system(size: big ? 14 : 11.5, weight: big ? .heavy : .medium))
                .foregroundStyle(big ? dark : Color(hex: 0x555555))
            Spacer()
            Text(v).font(.system(size: big ? 15 : 11.5, weight: big ? .heavy : .semibold))
                .foregroundStyle(big ? dark : ink)
        }
    }

    // ── Footer: firma in corsivo (se impostata) + dati banca su una sola riga ──
    private var footer: some View {
        VStack(spacing: 8) {
            if let firma = doc.azienda.firmatario, !firma.isEmpty {
                Text(firma).font(.custom("Snell Roundhand", size: 21)).foregroundStyle(ink)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6).padding(.bottom, 2)
            }
            Rectangle().fill(cardBd).frame(height: 1)
            (Text("Bank account ").font(.system(size: 9.5)).foregroundStyle(gray)
             + Text(doc.azienda.ragione_sociale ?? "").font(.system(size: 9.5, weight: .bold)).foregroundStyle(dark)
             + Text("   ·   IBAN ").font(.system(size: 9.5)).foregroundStyle(gray)
             + Text(doc.azienda.iban ?? "").font(.system(size: 9.5, weight: .bold)).foregroundStyle(dark)
             + Text("   ·   BIC ").font(.system(size: 9.5)).foregroundStyle(gray)
             + Text(doc.azienda.bic ?? "—").font(.system(size: 9.5, weight: .bold)).foregroundStyle(dark))
                .lineLimit(1).minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // ── helper ──
    private func card<C: View>(leftAccent: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { content() }
            .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cardBd, lineWidth: 1))
            .overlay(leftAccent ? AnyView(HStack { RoundedRectangle(cornerRadius: 2).fill(acc).frame(width: 3); Spacer() }) : AnyView(EmptyView()))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func cardLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(1.3).foregroundStyle(acc)
    }

    // riga cliente spezzata: indirizzo/località su una riga, "VAT Number:" sotto
    private var clientLines: [String] {
        let s = doc.clienteRiga
        guard let r = s.range(of: "VAT Number:") else { return [s] }
        let before = String(s[..<r.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–·"))
        let vat = String(s[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        return [before, vat].filter { !$0.isEmpty }
    }

    private var addressLines: [String] {
        // schiaccio sempre a 2 righe: via+civico | città, paese CAP — qualunque sia
        // il formato salvato (a-capo o virgole)
        let toks = (doc.azienda.indirizzo ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard toks.count > 2 else { return toks }     // 1–2 token: già ok
        let l1 = toks.prefix(2).joined(separator: " ")              // via + civico
        let rest = Array(toks.dropFirst(2))
        let cap = rest.filter { $0.count >= 4 && $0.allSatisfy(\.isNumber) }   // CAP in fondo
        let city = rest.filter { !($0.count >= 4 && $0.allSatisfy(\.isNumber)) }
        let l2 = (city.joined(separator: ", ") + (cap.isEmpty ? "" : " " + cap.joined(separator: " ")))
            .trimmingCharacters(in: .whitespaces)
        return [l1, l2]
    }
    // Logo "dark": bianco su sfondo nero già incorporato → mostrato così com'è,
    // clippato ad angoli arrotondati (è il tile stesso).
    @ViewBuilder private var logoTile: some View {
        if let logo = doc.logo {
            Image(nsImage: logo).resizable().scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0x0a0a0a))
                Text("UNVRS").font(.system(size: 13, weight: .black)).foregroundStyle(.white)
            }
        }
    }
}

// ─── Invio via Mail (composer con allegato PDF) ───
enum InvoiceMailer {
    @discardableResult @MainActor
    static func compose(to: String?, subject: String, body: String, attachment: URL) -> Bool {
        guard let svc = NSSharingService(named: .composeEmail) else { return false }
        if let to { svc.recipients = [to] }
        svc.subject = subject
        let items: [Any] = [body, attachment]
        guard svc.canPerform(withItems: items) else {
            NSWorkspace.shared.activateFileViewerSelecting([attachment])
            return false
        }
        svc.perform(withItems: items)
        return true
    }
}
