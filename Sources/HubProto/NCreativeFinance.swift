import SwiftUI

// ============================================================================
// NCREATIVE — Finance: fatture emesse, spese e conto del mese.
// Il mese scelto in alto comanda i riquadri e i filtri delle due tabelle.
// ============================================================================

struct NCFinanceView: View {
    @ObservedObject var model: NCModel
    @State private var mese = Date()
    @State private var filtroFattura: NCInvoiceStatus?
    @State private var filtroSpesa: NCExpenseCategory?
    @State private var soloMese = true
    @State private var mostraFattura = false
    @State private var fatturaInModifica: NCInvoice?
    @State private var mostraSpesa = false
    @State private var spesaInModifica: NCExpense?
    @State private var avviso: String?

    private var meseKey: String { ncMonthKey(mese) }

    private var fatture: [NCInvoice] {
        model.invoices.filter { f in
            if soloMese && !f.issue_date.hasPrefix(meseKey) { return false }
            if let s = filtroFattura, f.status != s.rawValue { return false }
            return true
        }
    }
    private var spese: [NCExpense] {
        model.expenses.filter { e in
            if soloMese && !e.date.hasPrefix(meseKey) { return false }
            if let c = filtroSpesa, e.category != c.rawValue { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                navBtn("chevron.left") { shift(-1) }
                Text(ncMonthLabel(mese))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.ink)
                    .frame(width: 150, alignment: .center)
                navBtn("chevron.right") { shift(1) }
                GhostButton(label: "This month") { mese = Date() }
                Spacer()
                FilterChip(label: soloMese ? "Month only" : "All time", selected: soloMese) {
                    soloMese.toggle()
                }
            }

            HStack(spacing: 10) {
                StatTile(label: "Billed", testo: ncEuro(model.billedCents(month: meseKey)))
                StatTile(label: "Collected", testo: ncEuro(model.collectedCents(month: meseKey)))
                StatTile(label: "Expenses", testo: ncEuro(model.spentCents(month: meseKey)))
                StatTile(label: "Profit", testo: ncEuro(model.profitCents(month: meseKey)))
                StatTile(label: "Outstanding", testo: ncEuro(model.outstandingCents))
            }

            if let avviso {
                Text(avviso).font(.system(size: 11)).foregroundStyle(UI.tint(.ok))
            }

            SectionCard(title: "Invoices", count: fatture.count, icon: "doc.text") {
                HStack(spacing: 6) {
                    FilterChip(label: "All", selected: filtroFattura == nil) { filtroFattura = nil }
                    ForEach(NCInvoiceStatus.allCases) { s in
                        FilterChip(label: s.label, selected: filtroFattura == s) {
                            filtroFattura = filtroFattura == s ? nil : s
                        }
                    }
                    GhostButton(label: "Bill retainers", icon: "arrow.triangle.2.circlepath") {
                        Task { await fatturaRetainer() }
                    }
                    GhostButton(label: "New invoice", icon: "plus") {
                        fatturaInModifica = nil; mostraFattura = true
                    }
                }
            } content: {
                if fatture.isEmpty {
                    NCEmpty(text: "No invoices for this period.")
                } else {
                    VStack(spacing: 5) {
                        NCHeaderRow(cols: [("Number", 90), ("Client", nil), ("Issued", 80), ("Due", 80),
                                           ("Net", 90), ("Total", 90), ("Status", 96)])
                        ForEach(fatture) { f in
                            NCInvoiceRow(
                                invoice: f,
                                client: model.clientName(f.client_id),
                                onOpen: { fatturaInModifica = f; mostraFattura = true },
                                onStatus: { st in Task { await model.setInvoiceStatus(f.id, st) } }
                            )
                        }
                    }
                }
            }

            SectionCard(title: "Expenses", count: spese.count, icon: "creditcard") {
                HStack(spacing: 6) {
                    FilterChip(label: "All", selected: filtroSpesa == nil) { filtroSpesa = nil }
                    ForEach(NCExpenseCategory.allCases) { c in
                        FilterChip(label: c.label, selected: filtroSpesa == c) {
                            filtroSpesa = filtroSpesa == c ? nil : c
                        }
                    }
                    GhostButton(label: "New expense", icon: "plus") {
                        spesaInModifica = nil; mostraSpesa = true
                    }
                }
            } content: {
                if spese.isEmpty {
                    NCEmpty(text: "No expenses for this period.")
                } else {
                    VStack(spacing: 5) {
                        NCHeaderRow(cols: [("Date", 80), ("Category", 110), ("Description", nil),
                                           ("Client", 140), ("Amount", 100)])
                        ForEach(spese) { e in
                            NCRow(action: { spesaInModifica = e; mostraSpesa = true }) {
                                Text(ncShortDate(e.date)).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(UI.dim).frame(width: 80, alignment: .leading)

                                let cat = NCExpenseCategory.from(e.category)
                                Label(cat.label, systemImage: cat.icon)
                                    .font(.system(size: 11)).foregroundStyle(UI.text)
                                    .frame(width: 110, alignment: .leading).lineLimit(1)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ncClean(e.description) ?? ncClean(e.vendor) ?? "—")
                                        .font(.system(size: 12)).foregroundStyle(UI.ink).lineLimit(1)
                                    if let v = ncClean(e.vendor), ncClean(e.description) != nil {
                                        Text(v).font(.system(size: 10)).foregroundStyle(UI.faint).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(model.clientName(e.client_id)).font(.system(size: 11))
                                    .foregroundStyle(UI.dim).frame(width: 140, alignment: .leading).lineLimit(1)

                                HStack(spacing: 5) {
                                    if e.recurring {
                                        Image(systemName: "repeat").font(.system(size: 9))
                                            .foregroundStyle(UI.faint)
                                    }
                                    Text(ncEuro(e.amount_cents, decimals: true))
                                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(UI.ink)
                                }
                                .frame(width: 100, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $mostraFattura, onDismiss: { fatturaInModifica = nil }) {
            NCInvoiceForm(existing: fatturaInModifica, month: meseKey, model: model)
        }
        .sheet(isPresented: $mostraSpesa, onDismiss: { spesaInModifica = nil }) {
            NCExpenseForm(existing: spesaInModifica, month: mese, model: model)
        }
    }

    /// Genera le bozze di fattura del mese per i clienti attivi con retainer,
    /// saltando chi ha già una fattura per lo stesso periodo.
    private func fatturaRetainer() async {
        let periodo = meseKey
        var creati = 0
        for c in model.activeClients where c.retainer_cents > 0 {
            let esiste = model.invoices.contains { $0.client_id == c.id && $0.period == periodo }
            if esiste { continue }
            let issue = Date()
            let due = Calendar.current.date(byAdding: .day, value: 15, to: issue) ?? issue
            let fields: [String: Any?] = [
                "client_id": c.id, "number": model.nextInvoiceNumber(offset: creati),
                "issue_date": ncDayString(issue), "due_date": ncDayString(due),
                "period": periodo, "description": "Monthly retainer — \(periodo)",
                "amount_cents": c.retainer_cents, "status": "draft",
            ]
            try? await HubAPI.ncInsert("nc_invoices", fields)
            creati += 1
        }
        await model.load()
        avviso = creati == 0
            ? "All active clients already have an invoice for \(periodo)."
            : "\(creati) draft invoice\(creati == 1 ? "" : "s") created for \(periodo)."
    }

    private func navBtn(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(UI.text)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UI.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    private func shift(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: n, to: mese) { mese = d }
    }
}

// ── Riga fattura: apre il form, ma lo stato si cambia dal menu senza aprirlo ──

private struct NCInvoiceRow: View {
    let invoice: NCInvoice
    let client: String
    let onOpen: () -> Void
    let onStatus: (NCInvoiceStatus) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Text(ncClean(invoice.number) ?? "—")
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(UI.text).frame(width: 90, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(client).font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.ink).lineLimit(1)
                        if let d = ncClean(invoice.description) {
                            Text(d).font(.system(size: 10)).foregroundStyle(UI.faint).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(ncShortDate(invoice.issue_date)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(UI.dim).frame(width: 80, alignment: .leading)
                    Text(ncShortDate(invoice.due_date)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(invoice.isOverdue ? UI.tint(.stop) : UI.dim)
                        .frame(width: 80, alignment: .leading)
                    Text(ncEuro(invoice.amount_cents)).font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(UI.text).frame(width: 90, alignment: .trailing)
                    Text(ncEuro(invoice.totalCents)).font(.system(size: 12, weight: .semibold))
                        .monospacedDigit().foregroundStyle(UI.ink)
                        .frame(width: 90, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(NCInvoiceStatus.allCases) { s in
                    Button(s.label) { onStatus(s) }
                }
            } label: {
                let st = NCInvoiceStatus.from(invoice.status)
                let overdue = invoice.isOverdue
                Text(overdue ? "Overdue" : st.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(overdue ? UI.tint(.stop) : st.color)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill((overdue ? UI.tint(.stop) : st.color).opacity(0.13)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 96, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? UI.surfaceHi : UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
        .onHover { hover = $0 }
    }
}

// ── Form fattura ─────────────────────────────────────────────────────────────

struct NCInvoiceForm: View {
    let existing: NCInvoice?
    let month: String
    @ObservedObject var model: NCModel

    @State private var clientId: String?
    @State private var number = ""
    @State private var descrizione = ""
    @State private var amount = ""
    @State private var vat = "21"
    @State private var status = NCInvoiceStatus.draft.rawValue
    @State private var period = ""
    @State private var notes = ""
    @State private var issue = Date()
    @State private var due = Date()
    @State private var hasDue = true

    private var eliminazione: (() async -> Void)? {
        guard let f = existing else { return nil }
        return { await model.delete("nc_invoices", id: f.id); await model.load() }
    }
    private var totale: Int {
        let net = ncCents(amount)
        return net + Int((Double(net) * (Double(vat) ?? 0) / 100).rounded())
    }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New invoice" : "Invoice \(ncClean(existing?.number) ?? "")",
            canSave: ncCents(amount) > 0,
            onDelete: eliminazione,
            onSave: salva
        ) {
            NCClientPicker(label: "Client", clients: model.clients, clientId: $clientId)
            HStack(spacing: 12) {
                NCField(label: "Number", text: $number, hint: "2026-001")
                NCField(label: "Period", text: $period, hint: "yyyy-MM")
            }
            NCField(label: "Description", text: $descrizione, hint: "Monthly retainer, campaign…")
            HStack(spacing: 12) {
                NCMoneyField(label: "Net amount", text: $amount)
                NCField(label: "VAT %", text: $vat, hint: "21")
            }
            Text("Total with VAT: \(ncEuro(totale, decimals: true))")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UI.dim)
            NCChips(label: "Status", options: NCInvoiceStatus.allCases.map { ($0.rawValue, $0.label) },
                    selection: $status)
            NCLabeled(label: "Issue date") {
                DatePicker("", selection: $issue, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field)
            }
            NCDateField(label: "Due date", date: $due, enabled: $hasDue)
            NCTextArea(label: "Notes", text: $notes)
        }
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let f = existing else {
            number = model.nextInvoiceNumber()
            period = month
            due = Calendar.current.date(byAdding: .day, value: 15, to: Date()) ?? Date()
            return
        }
        clientId = f.client_id; number = f.number ?? ""; descrizione = f.description ?? ""
        vat = String(format: "%g", f.vat_pct); status = f.status
        period = f.period ?? ""; notes = f.notes ?? ""
        amount = String(format: "%.2f", Double(f.amount_cents) / 100)
        if let d = ncParseDate(f.issue_date) { issue = d }
        if let d = ncParseDate(f.due_date) { due = d; hasDue = true } else { hasDue = false }
    }

    private func salva() async throws {
        var fields: [String: Any?] = [
            "client_id": clientId, "number": ncBlank(number),
            "issue_date": ncDayString(issue), "due_date": hasDue ? ncDayString(due) : nil,
            "period": ncBlank(period), "description": ncBlank(descrizione),
            "amount_cents": ncCents(amount), "vat_pct": Double(vat) ?? 0,
            "status": status, "notes": ncBlank(notes), "updated_at": isoNowString(),
        ]
        // la data di pagamento segue lo stato: se non è pagata, non c'è
        if status == "paid" {
            fields["paid_date"] = ncClean(existing?.paid_date) ?? ncDayString(Date())
        } else {
            fields["paid_date"] = nil
        }
        if let f = existing { try await HubAPI.ncUpdate("nc_invoices", id: f.id, fields) }
        else { try await HubAPI.ncInsert("nc_invoices", fields) }
        await model.load()
    }
}

// ── Form spesa ───────────────────────────────────────────────────────────────

struct NCExpenseForm: View {
    let existing: NCExpense?
    let month: Date
    @ObservedObject var model: NCModel

    @State private var clientId: String?
    @State private var category = NCExpenseCategory.tools.rawValue
    @State private var vendor = ""
    @State private var descrizione = ""
    @State private var amount = ""
    @State private var recurring = false
    @State private var notes = ""
    @State private var data = Date()

    private var eliminazione: (() async -> Void)? {
        guard let e = existing else { return nil }
        return { await model.delete("nc_expenses", id: e.id); await model.load() }
    }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New expense" : "Edit expense",
            canSave: ncCents(amount) > 0,
            onDelete: eliminazione,
            onSave: salva
        ) {
            NCChips(label: "Category", options: NCExpenseCategory.allCases.map { ($0.rawValue, $0.label) },
                    selection: $category)
            HStack(spacing: 12) {
                NCField(label: "Vendor", text: $vendor, hint: "Meta, Canva, freelancer…")
                NCMoneyField(label: "Amount", text: $amount)
            }
            NCField(label: "Description", text: $descrizione, hint: "What it was for")
            NCClientPicker(label: "Billable to client", clients: model.clients, clientId: $clientId)
            NCLabeled(label: "Date") {
                DatePicker("", selection: $data, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field)
            }
            NCLabeled(label: "Recurring") {
                HStack(spacing: 6) {
                    FilterChip(label: "One-off", selected: !recurring) { recurring = false }
                    FilterChip(label: "Every month", selected: recurring) { recurring = true }
                    Spacer(minLength: 0)
                }
            }
            NCTextArea(label: "Notes", text: $notes)
        }
        .onAppear(perform: precompila)
    }

    private func precompila() {
        guard let e = existing else {
            // nuova spesa nel mese che si sta guardando, non necessariamente oggi
            data = Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) ? Date() : month
            return
        }
        clientId = e.client_id; category = e.category; vendor = e.vendor ?? ""
        descrizione = e.description ?? ""; recurring = e.recurring; notes = e.notes ?? ""
        amount = String(format: "%.2f", Double(e.amount_cents) / 100)
        if let d = ncParseDate(e.date) { data = d }
    }

    private func salva() async throws {
        let fields: [String: Any?] = [
            "client_id": clientId, "date": ncDayString(data), "category": category,
            "vendor": ncBlank(vendor), "description": ncBlank(descrizione),
            "amount_cents": ncCents(amount), "recurring": recurring, "notes": ncBlank(notes),
        ]
        if let e = existing { try await HubAPI.ncUpdate("nc_expenses", id: e.id, fields) }
        else { try await HubAPI.ncInsert("nc_expenses", fields) }
        await model.load()
    }
}
