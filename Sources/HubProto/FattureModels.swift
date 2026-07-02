import Foundation

// ─── Modelli modulo Fatturazione (importi sempre in CENTS interi) ───

struct AziendaSettings: Decodable {
    var ragione_sociale: String?
    var indirizzo: String?
    var vat_number: String?
    var reg_number: String?
    var iban: String?
    var bic: String?
    var website: String?
    var email: String?
    var logo_path: String?
    var firmatario: String?       // nome reso in corsivo (Snell Roundhand) nel PDF
}

enum VatMode: String, CaseIterable {
    case reverse_charge, cyprus_19, out_of_scope
    var label: String {
        switch self {
        case .reverse_charge: return "Reverse charge EU (0%)"
        case .cyprus_19:      return "IVA Cipro 19%"
        case .out_of_scope:   return "Fuori campo (extra-UE)"
        }
    }
    var rate: Int { self == .cyprus_19 ? 19 : 0 }
    /// Nota in fattura.
    var note: String {
        switch self {
        case .reverse_charge:
            return "Reverse charge — VAT to be accounted for by the recipient pursuant to Article 196 of Directive 2006/112/EC."
        case .cyprus_19:
            return ""
        case .out_of_scope:
            return "Out of scope of EU VAT (supply to a customer established outside the EU)."
        }
    }
}

struct Fattura: Decodable, Identifiable {
    let id: String
    let anno: Int
    let numero: Int
    let cliente_id: String
    let data: String?
    let scadenza: String?
    let valuta: String?
    let vat_mode: String?
    let imponibile_cents: Int
    let iva_cents: Int
    let totale_cents: Int
    let stato: String
    let note: String?
    let pdf_path: String?
    var numeroCompleto: String { "\(anno)\(String(format: "%03d", numero))" }
}

struct FatturaRiga: Decodable, Identifiable {
    let id: String
    let fattura_id: String?
    let descrizione: String
    let qta: Double
    let prezzo_unitario_cents: Int
    let totale_cents: Int
    let ordine: Int?
}

struct Spesa: Decodable, Identifiable {
    let id: String
    let data: String?
    let fornitore: String?
    let descrizione: String?
    let importo_cents: Int
    let iva_cents: Int
    let categoria: String?
    let file_path: String?
}

struct Estratto: Decodable, Identifiable {
    let id: String
    let anno: Int
    let mese: Int
    let banca: String?
    let file_path: String?
}

struct MovMatch: Decodable {
    let tx_id: String
    let kind: String      // "spesa" | "fattura" | "ignora"
    let ref_id: String?
}

// ─── Denaro: unica fonte di verità (cents ↔ stringa EUR), niente Double ───
enum Money {
    /// cents → "€ 1.234,56" (formato europeo)
    static func eur(_ cents: Int) -> String {
        let neg = cents < 0
        let v = abs(cents)
        let euros = v / 100, cc = v % 100
        var s = ""
        let digits = String(euros)
        var count = 0
        for ch in digits.reversed() {
            if count > 0 && count % 3 == 0 { s = "." + s }
            s = String(ch) + s
            count += 1
        }
        return "\(neg ? "-" : "")€\(s),\(String(format: "%02d", cc))"
    }
    /// "1234,56" / "1234.56" / "1.234,56" / "1.500" / "(10,50)" → cents
    static func parse(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        var neg = false
        if t.hasPrefix("(") && t.hasSuffix(")") { neg = true; t.removeFirst(); t.removeLast() }
        for sym in ["€", "$", "£", "EUR", "USD"] { t = t.replacingOccurrences(of: sym, with: "") }
        t = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00a0}", with: "")
        if t.hasPrefix("+") { t.removeFirst() }
        if t.contains("-") { neg = true; t = t.replacingOccurrences(of: "-", with: "") }
        let hasDot = t.contains("."), hasComma = t.contains(",")
        if hasDot && hasComma {
            // vince come decimale il separatore più a destra
            if t.lastIndex(of: ",")! > t.lastIndex(of: ".")! {
                t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else { t = t.replacingOccurrences(of: ",", with: "") }
        } else if hasComma {
            t = t.replacingOccurrences(of: ",", with: ".")
        } else if hasDot {
            // solo punto: con più gruppi o esattamente 3 cifre finali è separatore migliaia ("1.500"),
            // con 1-2 cifre finali è decimale ("10.5", "1234.56")
            let parts = t.split(separator: ".")
            if parts.count > 2 || (parts.count == 2 && parts.last!.count == 3) {
                t = t.replacingOccurrences(of: ".", with: "")
            }
        }
        guard let d = Double(t) else { return nil }
        let cents = Int((d * 100).rounded())
        return neg ? -cents : cents
    }
}
