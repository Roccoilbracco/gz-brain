import SwiftUI

// ─── Editor nuova fattura (layout a card, ben spaziato) ───
struct FatturaEditorView: View {
    @ObservedObject var model: FattureModel
    let clienteId: String?
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    struct RigaInput: Identifiable { let id = UUID(); var desc = ""; var qta = "1"; var prezzo = "" }

    @State private var selCliente: String?
    @State private var data = Date()
    @State private var vatMode: VatMode = .reverse_charge
    @State private var righe: [RigaInput] = [RigaInput()]
    @State private var saving = false
    @State private var err: String?
    @State private var numeroText = ""

    private var anno: Int { Calendar.current.component(.year, from: data) }
    private var numeroInt: Int { Int(numeroText) ?? 0 }
    private var numeroStr: String { numeroText.isEmpty ? "…" : "\(anno)\(String(format: "%03d", numeroInt))" }
    private func loadNumero() async {
        if numeroText.isEmpty, let n = try? await HubAPI.nextNumero(anno: anno) { numeroText = String(n) }
    }

    // ── totali (cents) ──
    private func rigaTot(_ r: RigaInput) -> Int {
        let p = Money.parse(r.prezzo) ?? 0
        let q = Double(r.qta.replacingOccurrences(of: ",", with: ".")) ?? 1
        return Int((Double(p) * q).rounded())
    }
    private var imponibile: Int { righe.map(rigaTot).reduce(0, +) }
    private var iva: Int { Int((Double(imponibile) * Double(vatMode.rate) / 100).rounded()) }
    private var totale: Int { imponibile + iva }

    var body: some View {
        VStack(spacing: 0) {
            // header fisso
            HStack(spacing: 12) {
                Text("Nuova fattura").font(.system(size: 18, weight: .heavy)).foregroundStyle(Holo.titleText)
                Text("Nº \(numeroStr)").font(.system(size: 12, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(Holo.hsl(217, 85, 74))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Holo.hsl(217, 70, 50).opacity(0.25)))
                    .overlay(Capsule().strokeBorder(Holo.hsl(217, 80, 62).opacity(0.5), lineWidth: 1))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Holo.subDim)
                }.buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
            Divider().overlay(Color.white.opacity(0.08))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    detailsCard
                    righeCard
                    totaliCard
                    if let err { Text(err).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xffb3ad)) }
                }
                .padding(22)
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(.plain).font(.system(size: 13))
                    .foregroundStyle(Holo.subDim).padding(.horizontal, 16).padding(.vertical, 9)
                Button { save() } label: {
                    Text(saving ? "Genero PDF…" : "Emetti fattura")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Capsule().fill(LinearGradient(
                            colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                            startPoint: .leading, endPoint: .trailing)))
                }.buttonStyle(.plain).disabled(saving || selCliente == nil)
                    .opacity(selCliente == nil ? 0.5 : 1)
            }
            .padding(EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 24))
        }
        .frame(width: 720, height: 720)
        .background(LinearGradient(colors: [Color(red: 15/255, green: 22/255, blue: 44/255), Color(red: 8/255, green: 12/255, blue: 26/255)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .onAppear { if selCliente == nil { selCliente = clienteId }; Task { await loadNumero() } }
        .onChange(of: anno) { _, _ in numeroText = ""; Task { await loadNumero() } }
    }

    // ── Card: dettagli ──
    private var detailsCard: some View {
        card {
            sectionLabel("DETTAGLI")
            field("Cliente") {
                Menu {
                    ForEach(model.clienti) { c in Button(c.ragione_sociale) { selCliente = c.id } }
                } label: {
                    dropdownLabel(model.clienti.first { $0.id == selCliente }?.ragione_sociale ?? "Seleziona cliente…",
                                  placeholder: selCliente == nil)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
            }
            HStack(alignment: .top, spacing: 16) {
                field("Numero") {
                    HStack(spacing: 4) {
                        Text("\(anno) /").font(.system(size: 13)).foregroundStyle(Holo.subDim)
                        TextField("7", text: $numeroText).textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xe8f2ff))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 16/255, green: 24/255, blue: 46/255)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.4), lineWidth: 1))
                }
                field("Data") {
                    DatePicker("", selection: $data, displayedComponents: .date).labelsHidden()
                        .datePickerStyle(.field)
                }
            }
            field("Regime IVA") {
                Menu {
                    ForEach(VatMode.allCases, id: \.self) { m in Button(m.label) { vatMode = m } }
                } label: { dropdownLabel(vatMode.label, placeholder: false) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
            }
        }
    }

    // ── Card: righe ──
    private var righeCard: some View {
        card {
            sectionLabel("RIGHE")
            HStack(spacing: 10) {
                Text("DESCRIZIONE").frame(maxWidth: .infinity, alignment: .leading)
                Text("QTÀ").frame(width: 50)
                Text("PREZZO").frame(width: 96)
                Text("TOTALE").frame(width: 80, alignment: .trailing)
                Color.clear.frame(width: 18)
            }
            .font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(Holo.labelDim)
            ForEach($righe) { $r in
                HStack(spacing: 10) {
                    inputField("Descrizione", text: $r.desc)
                    inputField("1", text: $r.qta).frame(width: 50)
                    inputField("0,00", text: $r.prezzo).frame(width: 96)
                    Text(Money.eur(rigaTot(r))).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Holo.text).frame(width: 80, alignment: .trailing)
                    Button { righe.removeAll { $0.id == r.id }; if righe.isEmpty { righe = [RigaInput()] } } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 14)).foregroundStyle(Holo.labelDim)
                    }.buttonStyle(.plain).frame(width: 18)
                }
            }
            Button { righe.append(RigaInput()) } label: {
                HStack(spacing: 5) { Image(systemName: "plus.circle"); Text("Aggiungi riga") }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(righe.count >= 8 ? Holo.labelDim : Holo.hsl(217, 80, 72))
            }.buttonStyle(.plain).padding(.top, 2).disabled(righe.count >= 8)
            if righe.count >= 8 {
                Text("Massimo 8 righe: il template PDF è una pagina A4 singola.")
                    .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
            }
        }
    }

    // ── Card: totali ──
    private var totaliCard: some View {
        HStack {
            Spacer()
            card {
                totRow("Subtotale", Money.eur(imponibile), big: false)
                totRow("IVA (\(vatMode.rate)%)", Money.eur(iva), big: false)
                Divider().overlay(Color.white.opacity(0.12))
                totRow("Totale", Money.eur(totale), big: true)
            }
            .frame(width: 280)
        }
    }
    private func totRow(_ l: String, _ v: String, big: Bool) -> some View {
        HStack {
            Text(l).font(.system(size: big ? 13.5 : 12, weight: big ? .heavy : .medium))
                .foregroundStyle(big ? Holo.titleText : Holo.subDim)
            Spacer()
            Text(v).font(.system(size: big ? 15 : 12.5, weight: big ? .heavy : .semibold))
                .foregroundStyle(big ? Holo.titleText : Holo.text)
        }
    }

    // ── helper di stile ──
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 13/255, green: 20/255, blue: 40/255).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(red: 130/255, green: 180/255, blue: 255/255).opacity(0.18), lineWidth: 1))
    }
    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1.8).foregroundStyle(Holo.hsl(217, 85, 70))
    }
    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Holo.labelDim)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inputField(_ ph: String, text: Binding<String>) -> some View {
        TextField(ph, text: text).textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Holo.text)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 8/255, green: 13/255, blue: 28/255)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.28), lineWidth: 1))
            .frame(maxWidth: .infinity)
    }
    private func dropdownLabel(_ text: String, placeholder: Bool) -> some View {
        HStack {
            Text(text).font(.system(size: 13)).foregroundStyle(placeholder ? Holo.labelDim : Color(hex: 0xe8f2ff))
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Holo.subDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 16/255, green: 24/255, blue: 46/255)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 130/255, green: 180/255, blue: 1).opacity(0.4), lineWidth: 1))
    }

    private func save() {
        guard let cid = selCliente, let cliente = model.clienti.first(where: { $0.id == cid }),
              let azienda = model.azienda else { err = "Cliente o dati aziendali mancanti."; return }
        let valid = righe.filter { !$0.desc.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !valid.isEmpty else { err = "Aggiungi almeno una riga."; return }
        saving = true; err = nil
        let anno = Calendar.current.component(.year, from: data)
        Task {
            do {
                let numero = numeroInt > 0 ? numeroInt : (try await HubAPI.nextNumero(anno: anno))
                guard try await HubAPI.fatturaExists(anno: anno, numero: numero) == false else {
                    await MainActor.run { saving = false; err = "Esiste già la fattura \(anno)\(String(format: "%03d", numero)): cambia numero." }
                    return
                }
                // totali dalle sole righe valide (quelle che finiscono in fattura)
                let imp = valid.map(rigaTot).reduce(0, +)
                let ivaC = Int((Double(imp) * Double(vatMode.rate) / 100).rounded())
                let tot = imp + ivaC
                let righeBodies: [[String: Any?]] = valid.enumerated().map { idx, r in
                    let p = Money.parse(r.prezzo) ?? 0
                    let q = Double(r.qta.replacingOccurrences(of: ",", with: ".")) ?? 1
                    return ["descrizione": r.desc, "qta": q, "prezzo_unitario_cents": p,
                            "totale_cents": Int((Double(p) * q).rounded()), "ordine": idx]
                }
                let f = try await HubAPI.createFattura([
                    "anno": anno, "numero": numero, "cliente_id": cid,
                    "data": eaDate(data, "yyyy-MM-dd"), "valuta": "EUR", "vat_mode": vatMode.rawValue,
                    "imponibile_cents": imp, "iva_cents": ivaC, "totale_cents": tot, "stato": "emessa",
                ], righe: righeBodies)

                let invRighe = valid.map { r -> InvoiceData.Riga in
                    let p = Money.parse(r.prezzo) ?? 0
                    let q = Double(r.qta.replacingOccurrences(of: ",", with: ".")) ?? 1
                    let qStr = q == q.rounded() ? String(Int(q)) : String(q)
                    return InvoiceData.Riga(desc: r.desc, qta: qStr, prezzoC: p, totaleC: Int((Double(p) * q).rounded()))
                }
                let inv = InvoiceData(
                    azienda: azienda, clienteNome: cliente.ragione_sociale, clienteRiga: fatturaClienteRiga(cliente),
                    numero: "\(anno)\(String(format: "%03d", numero))", data: eaDate(data, "dd/MM/yyyy"),
                    righe: invRighe, imponibileC: imp, ivaC: ivaC, totaleC: tot,
                    vatNote: vatMode.note, logo: model.logo)
                if let pdf = InvoicePDF.render(inv) {
                    let path = try await HubAPI.uploadFatturaPDF(pdf, anno: anno, numero: numero)
                    try await HubAPI.setFatturaPdfPath(id: f.id, path: path)
                    await MainActor.run { saving = false; onSaved(); dismiss() }
                } else {
                    await MainActor.run { saving = false; onSaved(); err = "Fattura salvata ma PDF non generato: modificala e risalva per rigenerarlo." }
                }
            } catch {
                await MainActor.run { saving = false; err = error.localizedDescription }
            }
        }
    }
}
