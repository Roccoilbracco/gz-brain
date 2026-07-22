import SwiftUI
import UserNotifications

// ============================================================================
// NCREATIVE — Personal: la vita fuori dall'agenzia.
// Tre colonne (Family · Giorgio · Niko) per tre orizzonti (Today · Week · Month).
// "This month" è trasversale: finanze e obiettivi riguardano tutti e tre.
// ============================================================================

enum NCPerson: String, CaseIterable, Identifiable {
    case famiglia, giorgio, niko
    var id: String { rawValue }
    var label: String {
        switch self {
        case .famiglia: return "Family"
        case .giorgio: return "Giorgio"
        case .niko: return "Niko"
        }
    }
    var icon: String {
        switch self {
        case .famiglia: return "house"
        case .giorgio: return "person"
        case .niko: return "person.fill"
        }
    }
    /// Tinta per distinguere le persone nel calendario settimanale.
    var color: Color {
        switch self {
        case .famiglia: return UI.tint(.ok)
        case .giorgio: return UI.accent
        case .niko: return UI.tint(.attesa)
        }
    }
    /// Sezioni della colonna: la famiglia ha spesa e pasti, le persone no.
    var sections: [NCItemKind] {
        switch self {
        case .famiglia: return [.appuntamento, .todo, .spesa, .pasto]
        case .giorgio, .niko: return [.appuntamento, .todo, .importante]
        }
    }
    static func from(_ raw: String?) -> NCPerson { NCPerson(rawValue: raw ?? "") ?? .famiglia }
}

enum NCItemKind: String, CaseIterable, Identifiable {
    case appuntamento, todo, importante, spesa, pasto, obiettivo, finanza
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appuntamento: return "Appointments"
        case .todo: return "To do"
        case .importante: return "Important"
        case .spesa: return "Shopping"
        case .pasto: return "Meals"
        case .obiettivo: return "Goals"
        case .finanza: return "Finances"
        }
    }
    var singular: String {
        switch self {
        case .appuntamento: return "appointment"
        case .todo: return "task"
        case .importante: return "important thing"
        case .spesa: return "item"
        case .pasto: return "meal"
        case .obiettivo: return "goal"
        case .finanza: return "finance note"
        }
    }
    var icon: String {
        switch self {
        case .appuntamento: return "calendar"
        case .todo: return "checklist"
        case .importante: return "exclamationmark.circle"
        case .spesa: return "cart"
        case .pasto: return "fork.knife"
        case .obiettivo: return "target"
        case .finanza: return "eurosign.circle"
        }
    }
    /// Si spunta? Gli appuntamenti no: passano e basta.
    var checkable: Bool { self != .appuntamento && self != .pasto }
    var isMonthly: Bool { self == .obiettivo || self == .finanza }
    static func from(_ raw: String?) -> NCItemKind { NCItemKind(rawValue: raw ?? "") ?? .todo }
}

let NC_MEAL_SLOTS = ["pranzo", "cena"]

enum NCHorizon: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        }
    }
}

// ── Vista principale ─────────────────────────────────────────────────────────

struct NCPersonalView: View {
    @ObservedObject var model: NCModel
    @State private var horizon: NCHorizon = .today
    @State private var mostraForm = false
    @State private var inModifica: NCPersonalItem?
    @State private var nuovoPerson = NCPerson.famiglia
    @State private var nuovoKind = NCItemKind.todo
    @State private var nuovoGiorno: Date?

    private var oggi: Date { Calendar.current.startOfDay(for: Date()) }
    private var meseKey: String { ncMonthKey(Date()) }

    /// Lunedì → domenica della settimana corrente.
    private var settimana: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        guard let start = cal.date(from: comps) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func apri(_ person: NCPerson, _ kind: NCItemKind, _ day: Date?) {
        inModifica = nil; nuovoPerson = person; nuovoKind = kind; nuovoGiorno = day
        mostraForm = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(NCHorizon.allCases) { h in
                    FilterChip(label: h.label, selected: horizon == h) { horizon = h }
                }
                Spacer()
                Text(ncLongDate(ncDayString(Date())))
                    .font(.system(size: 11.5)).foregroundStyle(UI.faint)
            }

            switch horizon {
            case .today: oggiView
            case .week: settimanaView
            case .month: meseView
            }
        }
        .sheet(isPresented: $mostraForm, onDismiss: { inModifica = nil; nuovoGiorno = nil }) {
            NCPersonalForm(existing: inModifica, person: nuovoPerson, kind: nuovoKind,
                           day: nuovoGiorno, model: model)
        }
        .task(id: model.personal.count) { programmaPromemoria(model.personal) }
        .onAppear { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    // ── Oggi: tre colonne affiancate ──
    private var oggiView: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(NCPerson.allCases) { p in
                NCPersonColumn(
                    person: p,
                    sections: p.sections,
                    items: { kind in voci(p, kind, day: oggi) },
                    onAdd: { kind in apri(p, kind, Date()) },
                    onOpen: { item in inModifica = item; mostraForm = true },
                    onToggle: { id in Task { await model.togglePersonalDone(id) } }
                )
            }
        }
    }

    // ── Settimana: striscia calendario + colonne senza spesa ──
    private var settimanaView: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCard(title: "Week at a glance", icon: "calendar") {
                NCWeekStrip(days: settimana, items: model.personal,
                            onOpen: { item in inModifica = item; mostraForm = true },
                            onAdd: { day in apri(.famiglia, .appuntamento, day) })
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(NCPerson.allCases) { p in
                    let sezioni: [NCItemKind] = p == .famiglia
                        ? [.appuntamento, .todo, .pasto] : [.appuntamento, .todo]
                    NCPersonColumn(
                        person: p,
                        sections: sezioni,
                        items: { kind in vociSettimana(p, kind) },
                        onAdd: { kind in apri(p, kind, Date()) },
                        onOpen: { item in inModifica = item; mostraForm = true },
                        onToggle: { id in Task { await model.togglePersonalDone(id) } },
                        mostraData: true
                    )
                }
            }
        }
    }

    // ── Mese: trasversale (finanze + obiettivi) + promemoria ricorrenti ──
    private var meseView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ForEach([NCItemKind.finanza, NCItemKind.obiettivo], id: \.self) { kind in
                    let items = model.personal.filter { $0.kind == kind.rawValue && $0.month == meseKey }
                    SectionCard(title: kind.label, count: items.count, icon: kind.icon) {
                        GhostButton(label: "Add", icon: "plus") { apri(.famiglia, kind, nil) }
                    } content: {
                        if items.isEmpty {
                            NCEmpty(text: "Nothing for \(ncMonthLabel(Date())) yet.")
                        } else {
                            VStack(spacing: 6) {
                                ForEach(items) { i in
                                    NCItemRow(item: i, mostraData: false,
                                              onOpen: { inModifica = i; mostraForm = true },
                                              onToggle: { Task { await model.togglePersonalDone(i.id) } })
                                }
                            }
                        }
                    }
                }
            }

            SectionCard(title: "Recurring reminders", count: promemoria.count, icon: "bell") {
                GhostButton(label: "Add", icon: "plus") { apri(.famiglia, .todo, nil) }
            } content: {
                if promemoria.isEmpty {
                    NCEmpty(text: "No reminders — set a time on a task to be nudged (e.g. «prepare invoices»).")
                } else {
                    VStack(spacing: 6) {
                        ForEach(promemoria) { i in
                            HStack(spacing: 8) {
                                Image(systemName: "bell.fill").font(.system(size: 10))
                                    .foregroundStyle(UI.accent)
                                Text(i.title).font(.system(size: 12.5)).foregroundStyle(UI.ink)
                                Text(NCPerson.from(i.person).label)
                                    .font(.system(size: 10)).foregroundStyle(UI.faint)
                                Spacer(minLength: 6)
                                Text(descriviRicorrenza(i)).font(.system(size: 11))
                                    .monospacedDigit().foregroundStyle(UI.dim)
                                Button("Edit") { inModifica = i; mostraForm = true }
                                    .buttonStyle(.plain).font(.system(size: 10.5))
                                    .foregroundStyle(UI.accent)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UI.line, lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    private var promemoria: [NCPersonalItem] {
        model.personal.filter { ncClean($0.notify_at) != nil }
    }

    private func descriviRicorrenza(_ i: NCPersonalItem) -> String {
        let ora = ncClean(i.notify_at) ?? ""
        switch i.repeat_rule {
        case "daily": return "every day · \(ora)"
        case "weekly": return "every week · \(ora)"
        case "monthly": return "monthly · \(ora)"
        default: return ora
        }
    }

    private func voci(_ p: NCPerson, _ kind: NCItemKind, day: Date) -> [NCPersonalItem] {
        let key = ncDayString(day)
        return model.personal.filter { i in
            guard i.person == p.rawValue, i.kind == kind.rawValue else { return false }
            // le cose da fare senza data restano sempre in vista finché non si spuntano
            if i.day == nil { return kind.checkable && !i.done }
            return i.day == key
        }
        .sorted { ($0.time_at ?? "99") < ($1.time_at ?? "99") }
    }

    private func vociSettimana(_ p: NCPerson, _ kind: NCItemKind) -> [NCPersonalItem] {
        let giorni = Set(settimana.map { ncDayString($0) })
        return model.personal.filter { i in
            guard i.person == p.rawValue, i.kind == kind.rawValue else { return false }
            if let d = i.day { return giorni.contains(d) }
            return kind.checkable && !i.done
        }
        .sorted { ("\($0.day ?? "")\($0.time_at ?? "")") < ("\($1.day ?? "")\($1.time_at ?? "")") }
    }

    // ── Promemoria di sistema ──
    // Ripianificati a ogni caricamento: la lista in Supabase è la verità,
    // le notifiche macOS sono solo il suo riflesso.
    private func programmaPromemoria(_ items: [NCPersonalItem]) {
        let center = UNUserNotificationCenter.current()
        let ids = items.compactMap { ncClean($0.notify_at) != nil ? "nc-personal-\($0.id)" : nil }
        center.getPendingNotificationRequests { pending in
            let obsolete = pending.map(\.identifier)
                .filter { $0.hasPrefix("nc-personal-") && !ids.contains($0) }
            if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: obsolete) }
        }
        for i in items {
            guard let ora = ncClean(i.notify_at) else { continue }
            let parti = ora.split(separator: ":")
            guard let h = Int(parti.first ?? ""), parti.count > 1, let m = Int(parti[1]) else { continue }

            var comp = DateComponents(hour: h, minute: m)
            switch i.repeat_rule {
            case "weekly":
                if let d = ncParseDate(i.day) {
                    comp.weekday = Calendar.current.component(.weekday, from: d)
                }
            case "monthly":
                if let d = ncParseDate(i.day) {
                    comp.day = Calendar.current.component(.day, from: d)
                }
            default: break   // daily o singolo: solo ora e minuto
            }

            let content = UNMutableNotificationContent()
            content.title = i.title
            content.body = ncClean(i.notes) ?? "\(NCPerson.from(i.person).label) — \(NCItemKind.from(i.kind).label)"
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "nc-personal-\(i.id)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comp, repeats: i.repeat_rule != nil)))
        }
    }
}

// ── Colonna di una persona ───────────────────────────────────────────────────

private struct NCPersonColumn: View {
    let person: NCPerson
    let sections: [NCItemKind]
    let items: (NCItemKind) -> [NCPersonalItem]
    let onAdd: (NCItemKind) -> Void
    let onOpen: (NCPersonalItem) -> Void
    let onToggle: (String) -> Void
    var mostraData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: person.icon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(person.color)
                Text(person.label.uppercased())
                    .font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(UI.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            ForEach(sections) { kind in
                let list = items(kind)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: kind.icon).font(.system(size: 9)).foregroundStyle(UI.faint)
                        Text(kind.label.uppercased())
                            .font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundStyle(UI.faint)
                        if !list.isEmpty {
                            Text("\(list.count)").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(UI.dim)
                        }
                        Spacer(minLength: 0)
                        Button { onAdd(kind) } label: {
                            Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(UI.faint)
                        }
                        .buttonStyle(.plain)
                    }
                    if list.isEmpty {
                        Text("—").font(.system(size: 11)).foregroundStyle(UI.faint.opacity(0.7))
                            .padding(.leading, 2)
                    } else if kind == .pasto {
                        // i pasti si leggono meglio raggruppati per momento della giornata
                        ForEach(NC_MEAL_SLOTS, id: \.self) { slot in
                            let pasti = list.filter { ($0.slot ?? "pranzo") == slot }
                            if !pasti.isEmpty {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(slot == "pranzo" ? "L" : "D")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(UI.faint)
                                        .frame(width: 12, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(pasti) { i in
                                            NCItemRow(item: i, mostraData: mostraData,
                                                      onOpen: { onOpen(i) }, onToggle: { onToggle(i.id) })
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(list) { i in
                            NCItemRow(item: i, mostraData: mostraData,
                                      onOpen: { onOpen(i) }, onToggle: { onToggle(i.id) })
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(UI.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UI.line, lineWidth: 1))
    }
}

// ── Riga voce ────────────────────────────────────────────────────────────────

private struct NCItemRow: View {
    let item: NCPersonalItem
    var mostraData = false
    let onOpen: () -> Void
    let onToggle: () -> Void
    @State private var hover = false

    private var kind: NCItemKind { .from(item.kind) }

    var body: some View {
        HStack(spacing: 7) {
            if kind.checkable {
                Button(action: onToggle) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(item.done ? UI.tint(.ok) : UI.faint)
                }
                .buttonStyle(.plain)
            } else {
                Circle().fill(NCPerson.from(item.person).color.opacity(0.8))
                    .frame(width: 5, height: 5).padding(.horizontal, 3.5)
            }

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if let t = ncClean(item.time_at) {
                        Text(t).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(UI.dim)
                    }
                    if mostraData, let d = ncClean(item.day) {
                        Text(ncShortDate(d)).font(.system(size: 10)).foregroundStyle(UI.faint)
                    }
                    Text(item.title)
                        .font(.system(size: 12)).foregroundStyle(item.done ? UI.faint : UI.text)
                        .strikethrough(item.done, color: UI.faint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if ncClean(item.notify_at) != nil {
                        Image(systemName: "bell.fill").font(.system(size: 8)).foregroundStyle(UI.accent)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? UI.surfaceHi : Color.clear))
        .onHover { hover = $0 }
    }
}

// ── Striscia settimanale ─────────────────────────────────────────────────────

private struct NCWeekStrip: View {
    let days: [Date]
    let items: [NCPersonalItem]
    let onOpen: (NCPersonalItem) -> Void
    let onAdd: (Date) -> Void

    private func appuntamenti(_ d: Date) -> [NCPersonalItem] {
        let key = ncDayString(d)
        return items.filter { $0.kind == "appuntamento" && $0.day == key }
            .sorted { ($0.time_at ?? "99") < ($1.time_at ?? "99") }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(days, id: \.self) { d in
                let oggi = Calendar.current.isDateInToday(d)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(giornoBreve(d).uppercased())
                            .font(.system(size: 8.5, weight: .bold)).tracking(0.8)
                            .foregroundStyle(oggi ? UI.accent : UI.faint)
                        Text("\(Calendar.current.component(.day, from: d))")
                            .font(.system(size: 10.5, weight: oggi ? .bold : .medium)).monospacedDigit()
                            .foregroundStyle(oggi ? UI.accent : UI.dim)
                        Spacer(minLength: 0)
                        Button { onAdd(d) } label: {
                            Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(UI.faint)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(appuntamenti(d)) { i in
                        Button { onOpen(i) } label: {
                            HStack(spacing: 4) {
                                Rectangle().fill(NCPerson.from(i.person).color)
                                    .frame(width: 2).cornerRadius(1)
                                VStack(alignment: .leading, spacing: 1) {
                                    if let t = ncClean(i.time_at) {
                                        Text(t).font(.system(size: 8.5, weight: .semibold))
                                            .monospacedDigit().foregroundStyle(UI.dim)
                                    }
                                    Text(i.title).font(.system(size: 9.5)).foregroundStyle(UI.text)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }
                            .padding(.horizontal, 4).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(UI.surfaceHi))
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(UI.surface))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(oggi ? UI.accent.opacity(0.5) : UI.line, lineWidth: 1))
            }
        }
    }

    private func giornoBreve(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEE"
        return f.string(from: d)
    }
}

// ── Form voce personale ──────────────────────────────────────────────────────

struct NCPersonalForm: View {
    let existing: NCPersonalItem?
    let person: NCPerson
    let kind: NCItemKind
    let day: Date?
    @ObservedObject var model: NCModel

    @State private var title = ""
    @State private var notes = ""
    @State private var chi = NCPerson.famiglia.rawValue
    @State private var tipo = NCItemKind.todo.rawValue
    @State private var slot = "pranzo"
    @State private var ora = ""
    @State private var promemoria = ""
    @State private var ricorrenza = "none"
    @State private var giorno = Date()
    @State private var haGiorno = true
    @State private var fatto = false

    private var eliminazione: (() async -> Void)? {
        guard let i = existing else { return nil }
        return { await model.delete("nc_personal_items", id: i.id); await model.load() }
    }
    private var tipoCorrente: NCItemKind { .from(tipo) }

    var body: some View {
        NCSheet(
            title: existing == nil ? "New \(tipoCorrente.singular)" : "Edit",
            canSave: !title.trimmingCharacters(in: .whitespaces).isEmpty,
            onDelete: eliminazione,
            onSave: salva
        ) {
            NCField(label: "What", text: $title, hint: hintPerTipo)
            HStack(spacing: 12) {
                NCChips(label: "Who", options: NCPerson.allCases.map { ($0.rawValue, $0.label) },
                        selection: $chi)
                NCChips(label: "Type", options: NCItemKind.allCases.map { ($0.rawValue, $0.label) },
                        selection: $tipo)
            }
            if tipoCorrente == .pasto {
                NCChips(label: "When", options: [("pranzo", "Lunch"), ("cena", "Dinner")], selection: $slot)
            }
            if !tipoCorrente.isMonthly {
                NCDateField(label: "Day", date: $giorno, enabled: $haGiorno)
                HStack(spacing: 12) {
                    NCField(label: "Time", text: $ora, hint: "18:30")
                    NCField(label: "Remind me at", text: $promemoria, hint: "09:00")
                }
                NCChips(label: "Repeat reminder",
                        options: [("none", "Once"), ("daily", "Daily"), ("weekly", "Weekly"), ("monthly", "Monthly")],
                        selection: $ricorrenza)
            } else {
                Text("Goals and finances belong to the month — no day needed.")
                    .font(.system(size: 11)).foregroundStyle(UI.faint)
            }
            if tipoCorrente.checkable {
                NCLabeled(label: "Status") {
                    HStack(spacing: 6) {
                        FilterChip(label: "To do", selected: !fatto) { fatto = false }
                        FilterChip(label: "Done", selected: fatto) { fatto = true }
                        Spacer(minLength: 0)
                    }
                }
            }
            NCTextArea(label: "Notes", text: $notes)
        }
        .onAppear(perform: precompila)
    }

    private var hintPerTipo: String {
        switch tipoCorrente {
        case .appuntamento: return "Dentist, school meeting…"
        case .todo: return "Book the vet, pay gymnastics…"
        case .importante: return "The one thing that matters today"
        case .spesa: return "Milk, eggs…"
        case .pasto: return "Pasta al pesto"
        case .obiettivo: return "Goal for this month"
        case .finanza: return "Rent, savings target…"
        }
    }

    private func precompila() {
        guard let i = existing else {
            chi = person.rawValue; tipo = kind.rawValue
            if let d = day { giorno = d; haGiorno = true } else { haGiorno = !kind.isMonthly }
            return
        }
        title = i.title; notes = i.notes ?? ""; chi = i.person; tipo = i.kind
        slot = i.slot ?? "pranzo"; ora = i.time_at ?? ""; promemoria = i.notify_at ?? ""
        ricorrenza = i.repeat_rule ?? "none"; fatto = i.done
        if let d = ncParseDate(i.day) { giorno = d; haGiorno = true } else { haGiorno = false }
    }

    private func salva() async throws {
        let mensile = tipoCorrente.isMonthly
        let fields: [String: Any?] = [
            "person": chi, "kind": tipo,
            "title": title.trimmingCharacters(in: .whitespaces),
            "notes": ncBlank(notes),
            "day": mensile ? nil : (haGiorno ? ncDayString(giorno) : nil),
            "time_at": mensile ? nil : ncBlank(ora),
            "slot": tipoCorrente == .pasto ? slot : nil,
            "done": fatto,
            "repeat_rule": ricorrenza == "none" ? nil : ricorrenza,
            "notify_at": mensile ? nil : ncBlank(promemoria),
            // le voci mensili si agganciano al mese corrente (o a quello del giorno scelto)
            "month": mensile ? ncMonthKey(haGiorno ? giorno : Date()) : nil,
            "updated_at": isoNowString(),
        ]
        if let i = existing { try await HubAPI.ncUpdate("nc_personal_items", id: i.id, fields) }
        else { try await HubAPI.ncInsert("nc_personal_items", fields) }
        await model.load()
    }
}
