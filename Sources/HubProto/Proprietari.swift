import SwiftUI

// ── Catena dei proprietari ────────────────────────────────────────────────────
//
// Chi ha posseduto l'immobile e quando. Serve nella due diligence (a chi
// chiedere, da quanto è nelle stesse mani, quante volte è passato di mano) e
// in trattativa: un immobile rivenduto tre volte in cinque anni racconta
// qualcosa che il prezzo da solo non dice.

struct Proprietario: Decodable, Identifiable, Equatable {
    let id: String
    var nome: String
    var tipo: String            // persona | societa
    var anno_da: Int?
    var anno_a: Int?            // nil = proprietario attuale
    var quota: Int?             // percentuale, se in comproprietà
    var prezzo_acquisto: Int?
    var documento: String?      // NIE / NIF / CIF
    var contatto: String?
    var note: String?

    var attuale: Bool { anno_a == nil }
    var societa: Bool { tipo == "societa" }

    /// "2019 – 2024", "dal 2019", "fino al 2024", "—".
    var periodo: String {
        switch (anno_da, anno_a) {
        case let (d?, a?): return "\(d) – \(a)"
        case let (d?, nil): return "dal \(d)"
        case let (nil, a?): return "fino al \(a)"
        default: return "—"
        }
    }

    /// Da quanti anni lo possiede (o per quanti lo ha posseduto).
    var durata: String? {
        guard let d = anno_da else { return nil }
        let fine = anno_a ?? Calendar.current.component(.year, from: Date())
        let anni = fine - d
        guard anni >= 1 else { return nil }
        return anni == 1 ? "1 anno" : "\(anni) anni"
    }
}

extension HubAPI {
    /// Ordinati dal più recente: il proprietario attuale è il primo della lista.
    static func listProprietari(proprietaId: String) async throws -> [Proprietario] {
        try await sb.fetch(
            "proprieta_proprietari?select=*&proprieta_id=eq.\(proprietaId)&order=anno_da.desc.nullslast")
    }
    static func addProprietario(_ fields: [String: Any?]) async throws {
        try await sb.mutate("proprieta_proprietari", method: "POST", body: fields)
    }
    static func deleteProprietario(id: String) async throws {
        try await sb.mutate("proprieta_proprietari?id=eq.\(id)", method: "DELETE")
    }
}

// ── Riga della catena ─────────────────────────────────────────────────────────
struct RigaProprietario: View {
    let p: Proprietario
    /// Vero per l'ultimo elemento: la linea verticale non prosegue.
    let ultimo: Bool
    let onDelete: () -> Void

    private var tinta: Double { p.attuale ? 145 : 210 }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Filo della timeline: pallino + linea verso il proprietario prima.
            VStack(spacing: 0) {
                Image(systemName: p.societa ? "building.2.fill" : "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Holo.hsl(tinta, 85, 72))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Holo.hsl(tinta, 70, 45).opacity(p.attuale ? 0.22 : 0.12)))
                    .overlay(Circle().strokeBorder(Holo.hsl(tinta, 70, 55).opacity(p.attuale ? 0.6 : 0.3), lineWidth: 1))
                if !ultimo {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(p.nome).font(.system(size: 13.5, weight: .bold)).foregroundStyle(Holo.titleText)
                    if p.attuale {
                        Text("ATTUALE").font(.system(size: 8.5, weight: .heavy)).tracking(1)
                            .foregroundStyle(Holo.hsl(145, 80, 74))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Holo.hsl(145, 60, 45).opacity(0.2)))
                    }
                    if let q = p.quota, q < 100 {
                        Text("\(q)%").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Csb.secFg)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }

                HStack(spacing: 8) {
                    Text(p.periodo).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Holo.hsl(tinta, 60, 70))
                    if let d = p.durata {
                        Text("·").foregroundStyle(Csb.secFg)
                        Text(d).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                    }
                }

                if p.documento != nil || p.contatto != nil {
                    Text([p.documento, p.contatto].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Holo.subDim).textSelection(.enabled)
                }
                if let n = p.note, !n.isEmpty {
                    Text(n).font(.system(size: 11)).foregroundStyle(Holo.labelDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if let pr = p.prezzo_acquisto {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(LeadFmt.euro(pr)).font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Holo.titleText).monospacedDigit()
                        Text("acquisto").font(.system(size: 9)).foregroundStyle(Csb.secFg)
                    }
                }
                IconButton(icon: "trash", help: "Elimina", danger: true, action: onDelete)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

// ── Form nuovo proprietario ───────────────────────────────────────────────────
struct ProprietarioFormView: View {
    let proprietaId: String
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var nome = ""
    @State private var tipo = "persona"
    @State private var annoDa = ""
    @State private var annoA = ""
    @State private var attuale = true
    @State private var quota = ""
    @State private var prezzo = ""
    @State private var documento = ""
    @State private var contatto = ""
    @State private var note = ""
    @State private var saving = false
    @State private var errore: String?

    private var valido: Bool { !nome.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Nuovo proprietario").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Holo.titleText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Csb.secFg)
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 14, trailing: 20))

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    campo("NOME / RAGIONE SOCIALE") {
                        InlineField(placeholder: "es. Juan Pérez Torres — o Inmobiliaria XYZ S.L.", text: $nome)
                    }
                    campo("TIPO") {
                        InlinePicker(opts: [("persona", "Persona fisica"), ("societa", "Società")],
                                     sel: tipo) { tipo = $0 }
                            .frame(width: 200)
                    }
                    campo("PERIODO") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                InlineField(placeholder: "Dall'anno", text: $annoDa).frame(width: 110)
                                InlineField(placeholder: "All'anno", text: $annoA)
                                    .frame(width: 110).disabled(attuale).opacity(attuale ? 0.4 : 1)
                                Spacer(minLength: 0)
                            }
                            Toggle(isOn: $attuale) {
                                Text("È il proprietario attuale").font(.system(size: 12)).foregroundStyle(Holo.text)
                            }
                            .toggleStyle(.checkbox)
                            .onChange(of: attuale) { _, on in if on { annoA = "" } }
                        }
                    }
                    campo("QUOTA E PREZZO") {
                        HStack(spacing: 8) {
                            InlineField(placeholder: "Quota %", text: $quota).frame(width: 110)
                            InlineField(placeholder: "Prezzo d'acquisto €", text: $prezzo).frame(width: 190)
                            Spacer(minLength: 0)
                        }
                    }
                    campo("DOCUMENTO") {
                        InlineField(placeholder: "NIE / NIF / CIF", text: $documento).frame(width: 220)
                    }
                    campo("CONTATTO") {
                        InlineField(placeholder: "Telefono o email", text: $contatto)
                    }
                    campo("NOTE") {
                        InlineField(placeholder: "Come è stato acquisito, eredità, note utili…",
                                    text: $note, multiline: true)
                    }
                    if let errore {
                        Text(errore).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xffb3ad))
                    }
                }
                .padding(20)
            }

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: 8) {
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Holo.subDim)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                Button { Task { await salva() } } label: {
                    Text(saving ? "Salvataggio…" : "Salva").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(Holo.hsl(217, 80, 52)))
                }
                .buttonStyle(.plain).disabled(saving || !valido).opacity(valido ? 1 : 0.5)
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: 520, height: 620)
        .background(Csb.panel)
    }

    private func campo<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2).foregroundStyle(Csb.secFg)
            content()
        }
    }

    private func salva() async {
        guard valido, !saving else { return }
        saving = true; errore = nil
        defer { saving = false }
        let t = { (v: String) -> String? in
            let x = v.trimmingCharacters(in: .whitespacesAndNewlines); return x.isEmpty ? nil : x
        }
        do {
            try await HubAPI.addProprietario([
                "proprieta_id": proprietaId,
                "nome": nome.trimmingCharacters(in: .whitespaces),
                "tipo": tipo,
                "anno_da": Int(annoDa),
                "anno_a": attuale ? nil : Int(annoA),
                "quota": Int(quota),
                "prezzo_acquisto": Int(prezzo),
                "documento": t(documento),
                "contatto": t(contatto),
                "note": t(note),
            ])
            await onSaved()
            dismiss()
        } catch let e {
            errore = "Salvataggio fallito: \(e.localizedDescription)"
        }
    }
}
