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
    var numeroCompleto: String { "\(anno)/\(String(format: "%03d", numero))" }
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
    /// "1234,56" / "1234.56" / "1.234,56" → cents
    static func parse(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "€", with: "").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        // se ha sia '.' che ',' → '.' è separatore migliaia
        if t.contains(",") && t.contains(".") { t = t.replacingOccurrences(of: ".", with: "") }
        t = t.replacingOccurrences(of: ",", with: ".")
        guard let d = Double(t) else { return nil }
        return Int((d * 100).rounded())
    }
}
