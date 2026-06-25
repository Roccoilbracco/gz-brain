import SwiftUI

// ─── Modelli EasyAct (Supabase dedicato del progetto) ───
struct EAOrg: Decodable, Identifiable {
    let id: String
    let name: String?
    let vat_id: String?
    let country: String?
    let plan: String?
    let created_at: String?
    let referred_by_partner_id: String?
}
struct EAPartner: Decodable, Identifiable {
    let id: String
    let name: String?
    let slug: String?
    let stripe_onboarded: Bool?
    let share_cents: Int?
    let active: Bool?
    let email: String?
}
struct EASubscription: Decodable {
    let org_id: String
    let status: String?
    let plan: String?
    let current_period_end: String?
}

// ─── Model: legge le credenziali dal .env.local del progetto e carica i dati ───
@MainActor
final class EasyActModel: ObservableObject {
    let project: Project
    @Published var orgs: [EAOrg] = []
    @Published var partners: [EAPartner] = []
    @Published var subs: [EASubscription] = []
    @Published var loading = true
    @Published var error: String?

    init(project: Project) { self.project = project }

    private func loadEnv(_ path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var dict: [String: String] = [:]
        for raw in content.split(whereSeparator: \.isNewline) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = String(l[l.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, (f == "\"" || f == "'"), v.last == f { v = String(v.dropFirst().dropLast()) }
            dict[k] = v
        }
        return dict
    }

    private func client() -> SupabaseClient? {
        guard let base = project.local_path else { return nil }
        for p in [base + "/apps/web/.env.local", base + "/.env.local"] {
            let env = loadEnv(p)
            if let urlStr = env["NEXT_PUBLIC_SUPABASE_URL"],
               let key = env["SUPABASE_SERVICE_ROLE_KEY"],
               let url = URL(string: urlStr) {
                return SupabaseClient(baseURL: url, secretKey: key)
            }
        }
        return nil
    }

    func load() async {
        guard let sb = client() else {
            error = "Credenziali EasyAct non trovate in apps/web/.env.local"
            loading = false
            return
        }
        loading = true; error = nil
        do {
            async let o: [EAOrg] = sb.fetch("orgs?select=id,name,vat_id,country,plan,created_at,referred_by_partner_id&order=created_at.desc&limit=2000")
            async let p: [EAPartner] = sb.fetch("partners?select=id,name,slug,stripe_onboarded,share_cents,active,email&order=created_at.desc&limit=1000")
            async let s: [EASubscription] = sb.fetch("subscriptions?select=org_id,status,plan,current_period_end&limit=5000")
            orgs = try await o; partners = try await p; subs = try await s
        } catch let e { error = e.localizedDescription }
        loading = false
    }

    // ── KPI ──
    var totale: Int { orgs.count }
    private var pagantiOrgIds: Set<String> {
        Set(subs.filter { ["active", "trialing"].contains($0.status ?? "") }.map { $0.org_id })
    }
    var paganti: Int { pagantiOrgIds.count }
    var diretti: Int { orgs.filter { $0.referred_by_partner_id == nil }.count }
    var daAssoc: Int { orgs.filter { $0.referred_by_partner_id != nil }.count }
    var assocAttive: Int { partners.filter { $0.active == true }.count }
    /// Registrazioni clienti per giorno, ultimi 14 giorni (per le colonne animate).
    var activityBuckets: [Int] { eaBucketByDay(orgs.map { $0.created_at }, days: 14) }

    func partnerName(_ id: String?) -> String? {
        guard let id else { return nil }
        return partners.first { $0.id == id }?.name
    }
    func subStatus(_ orgId: String) -> String? { subs.first { $0.org_id == orgId }?.status }
    func clientiCount(partner: EAPartner) -> Int { orgs.filter { $0.referred_by_partner_id == partner.id }.count }
    func isPagante(_ orgId: String) -> Bool { pagantiOrgIds.contains(orgId) }
}

// ─── Dash EasyAct: KPI + clienti + associazioni (stile holo, come Energizzo) ───
struct EasyActLayout: View {
    @StateObject private var model: EasyActModel
    @State private var search = ""

    init(project: Project) { _model = StateObject(wrappedValue: EasyActModel(project: project)) }

    private var clientiFiltrati: [EAOrg] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.orgs }
        return model.orgs.filter { ($0.name ?? "").lowercased().contains(q) || ($0.vat_id ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let err = model.error {
                GlassCard { Text("Errore: \(err)").foregroundStyle(Color(hex: 0xffb3ad))
                    .font(.system(size: 12.5)).padding(20) }
            } else if model.loading {
                Text("Caricamento dati EasyAct…").font(.system(size: 13)).foregroundStyle(Holo.subDim)
            } else {
                topRow
                clientiSection
                associazioniSection
            }
        }
        .task { await model.load() }
    }

    private var acc: Double { model.project.hue }   // colore del progetto (giallo per easyact)

    // ── Riga in alto stile Energizzo: colonne animate (sx) + pannello stat (dx) ──
    private var topRow: some View {
        HStack(spacing: 16) {
            SkyBars(values: model.activityBuckets, hue: acc, height: 80)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
                .frame(maxWidth: .infinity)
                .background(LinearGradient(
                    colors: [Holo.hsl(acc, 60, 30).opacity(0.22),
                             Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Holo.hsl(acc, 85, 62).opacity(0.45), lineWidth: 1))

            EAStatPanel(model: model)
        }
    }

    // ── Clienti ──
    private var clientiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("CLIENTI").font(.system(size: 13, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.hsl(acc, 85, 72))
                Text("\(clientiFiltrati.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Holo.subDim)
                Spacer()
                searchField
            }
            if clientiFiltrati.isEmpty {
                Text(search.isEmpty ? "Nessun cliente." : "Nessun cliente trovato.")
                    .font(.system(size: 12)).foregroundStyle(Holo.labelDim).padding(.vertical, 6)
            } else {
                EAAccentCard(hue: acc) {
                    VStack(spacing: 0) {
                        clientiHeader
                        Divider().overlay(Holo.hsl(acc, 70, 55).opacity(0.25))
                        ForEach(Array(clientiFiltrati.enumerated()), id: \.element.id) { i, o in
                            clienteRow(o)
                            if i < clientiFiltrati.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    private var clientiHeader: some View {
        HStack(spacing: 12) {
            col("RAGIONE SOCIALE", width: nil)
            col("P.IVA", width: 120)
            col("PAESE", width: 60)
            col("PIANO", width: 90)
            col("STATO", width: 100)
            col("ASSOCIAZIONE", width: 140)
            col("DATA", width: 90)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
    private func col(_ t: String, width: CGFloat?) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(Holo.labelDim)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
    private func clienteRow(_ o: EAOrg) -> some View {
        HStack(spacing: 12) {
            Text(o.name ?? "—").font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.text)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(o.vat_id ?? "—").font(.system(size: 11)).foregroundStyle(Holo.subDim).lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text((o.country ?? "—").trimmingCharacters(in: .whitespaces).uppercased())
                .font(.system(size: 11)).foregroundStyle(Holo.subDim).frame(width: 60, alignment: .leading)
            Text((o.plan ?? "—").capitalized).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 90, alignment: .leading)
            statoBadge(model.subStatus(o.id)).frame(width: 100, alignment: .leading)
            Text(model.partnerName(o.referred_by_partner_id) ?? "—").font(.system(size: 11))
                .foregroundStyle(o.referred_by_partner_id != nil ? Holo.hsl(38, 80, 72) : Holo.labelDim)
                .lineLimit(1).frame(width: 140, alignment: .leading)
            Text(String((o.created_at ?? "").prefix(10))).font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func statoBadge(_ status: String?) -> some View {
        let s = status ?? "—"
        let paga = ["active", "trialing"].contains(s)
        let hue: Double = paga ? 152 : (s == "past_due" || s == "unpaid" ? 0 : 217)
        return Text(s == "—" ? "—" : s.uppercased())
            .font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
            .foregroundStyle(s == "—" ? Holo.labelDim : Holo.hsl(hue, 85, 75))
            .padding(.horizontal, s == "—" ? 0 : 8).padding(.vertical, s == "—" ? 0 : 3)
            .overlay(s == "—" ? nil : Capsule().strokeBorder(Holo.hsl(hue, 80, 60).opacity(0.5), lineWidth: 1))
    }

    // ── Associazioni ──
    private var associazioniSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("ASSOCIAZIONI").font(.system(size: 13, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(Holo.hsl(acc, 85, 72))
                Text("\(model.partners.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Holo.subDim)
            }
            if model.partners.isEmpty {
                Text("Nessuna associazione white-label ancora.")
                    .font(.system(size: 12)).foregroundStyle(Holo.labelDim).padding(.vertical, 6)
            } else {
                EAAccentCard(hue: acc) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.partners.enumerated()), id: \.element.id) { i, p in
                            partnerRow(p)
                            if i < model.partners.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    private func partnerRow(_ p: EAPartner) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Holo.hsl(300, 75, 62)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name ?? "—").font(.system(size: 13, weight: .semibold)).foregroundStyle(Holo.text).lineLimit(1)
                if let slug = p.slug { Text(slug).font(.system(size: 10)).foregroundStyle(Holo.labelDim) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(model.clientiCount(partner: p)) clienti").font(.system(size: 11)).foregroundStyle(Holo.subDim)
                .frame(width: 90, alignment: .leading)
            if let share = p.share_cents {
                Text("\(share / 100)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(Holo.subDim)
                    .frame(width: 60, alignment: .leading)
            }
            if p.stripe_onboarded == true {
                miniTag("STRIPE", hue: 152)
            } else {
                miniTag("NO STRIPE", hue: 38)
            }
            miniTag(p.active == true ? "ATTIVA" : "OFF", hue: p.active == true ? 152 : 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
    private func miniTag(_ t: String, hue: Double) -> some View {
        Text(t).font(.system(size: 8.5, weight: .heavy)).tracking(0.5)
            .foregroundStyle(Holo.hsl(hue, 85, 75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Holo.hsl(hue, 80, 60).opacity(0.5), lineWidth: 1))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.6))
            TextField("Cerca cliente…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Holo.text).frame(width: 180)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Color(red: 165/255, green: 200/255, blue: 250/255).opacity(0.5))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color(red: 13/255, green: 21/255, blue: 44/255).opacity(0.75)))
        .overlay(Capsule().strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.25), lineWidth: 1))
    }
}

/// Card come GlassCard ma con bordo/alone del colore del progetto (giallo per easyact).
struct EAAccentCard<Content: View>: View {
    let hue: Double
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(LinearGradient(
                colors: [Color(red: 18/255, green: 28/255, blue: 58/255).opacity(0.92),
                         Color(red: 10/255, green: 16/255, blue: 34/255).opacity(0.94)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Holo.hsl(hue, 72, 58).opacity(0.4), lineWidth: 1))
            .shadow(color: Holo.hsl(hue, 80, 50).opacity(0.22), radius: 17)
    }
}

/// Bucket di date ISO per giorno (ultimi N giorni), come bucketEventsByDay.
func eaBucketByDay(_ isoDates: [String?], days: Int, today: Date = Date()) -> [Int] {
    var buckets = [Int](repeating: 0, count: days)
    let cal = Calendar.current
    let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: today) ?? today
    for s in isoDates {
        guard let s, let d = parseISO(s) else { continue }
        let diff = Int(floor(end.timeIntervalSince(d) / 86_400))
        if diff >= 0 && diff < days { buckets[days - 1 - diff] += 1 }
    }
    return buckets
}

// ─── Pannello stat EasyAct: Clienti · Diretti · Da associazioni (stile ServicePanel) ───
private struct EAStatPanel: View {
    @ObservedObject var model: EasyActModel

    private func pct(_ n: Int) -> Int { model.totale > 0 ? Int((Double(n) / Double(model.totale) * 100).rounded()) : 0 }

    var body: some View {
        EAAccentCard(hue: model.project.hue) {
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    cap("Clienti", n: model.totale, pct: 100, hue: model.project.hue)
                    cap("Diretti", n: model.diretti, pct: pct(model.diretti), hue: 217)
                    cap("Da assoc.", n: model.daAssoc, pct: pct(model.daAssoc), hue: 38)
                }
                EASparkField(direttiFrac: model.totale > 0 ? CGFloat(model.diretti) / CGFloat(model.totale) : 0.5)
                    .frame(height: 36)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
        }
        .frame(maxWidth: .infinity)
    }

    private func cap(_ label: String, n: Int, pct: Int, hue: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Holo.labelDim)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(n)").font(.system(size: 22, weight: .black)).foregroundStyle(Holo.hsl(hue, 90, 68))
                    .shadow(color: Holo.hsl(hue, 90, 60).opacity(0.55), radius: 6)
                Text("\(pct)%").font(.system(size: 10, weight: .semibold)).foregroundStyle(Holo.subDim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Holo.hsl(hue, 90, 60))
                        .frame(width: geo.size.width * CGFloat(pct) / 100)
                        .shadow(color: Holo.hsl(hue, 90, 60).opacity(0.8), radius: 4)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Equalizer rilassato: bande proporzionali (blu = diretti · ambra = da associazioni).
private struct EASparkField: View {
    let direttiFrac: CGFloat
    private let n = 40

    private func hue(at f: CGFloat) -> Double { f < direttiFrac ? 217 : 38 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let slot = size.width / CGFloat(n)
                let bw: CGFloat = 2.5
                for i in 0..<n {
                    let f = CGFloat(i) / CGFloat(n - 1)
                    let wave = 0.5 + 0.5 * sin(t * 1.3 + Double(i) * 0.45)
                    let h = 5 + CGFloat(wave) * (size.height - 7)
                    let x = slot * CGFloat(i) + (slot - bw) / 2
                    let color = Color(hue: hue(at: f) / 360, saturation: 0.82, brightness: 0.96)
                        .opacity(0.28 + 0.55 * wave)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - h, width: bw, height: h),
                                  cornerRadius: 1.25), with: .color(color))
                }
            }
        }
        .clipped()
    }
}
