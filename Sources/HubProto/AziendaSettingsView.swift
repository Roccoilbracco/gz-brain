import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ─── Card "Dati aziendali" per le fatture (vive in Impostazioni) ───
struct AziendaSettingsCard: View {
    @State private var rs = ""
    @State private var indirizzo = ""
    @State private var vat = ""
    @State private var reg = ""
    @State private var iban = ""
    @State private var bic = ""
    @State private var website = ""
    @State private var email = ""
    @State private var firmatario = ""
    @State private var logoPath: String?
    @State private var loading = true
    @State private var saving = false
    @State private var msg: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("DATI AZIENDALI (FATTURE)").font(.system(size: 10, weight: .heavy)).tracking(2)
                    .foregroundStyle(Holo.hsl(217, 90, 70))

                if loading {
                    Text("Caricamento…").font(.system(size: 12)).foregroundStyle(Holo.subDim)
                } else {
                    HoloField(label: "Ragione sociale", text: $rs, placeholder: "Es. Unvrs Labs Limited")
                    HoloField(label: "Indirizzo", text: $indirizzo, placeholder: "Via, Città, Paese, CAP")
                    HStack(spacing: 12) {
                        HoloField(label: "VAT number", text: $vat)
                        HoloField(label: "Reg. number", text: $reg)
                    }
                    HStack(spacing: 12) {
                        HoloField(label: "IBAN", text: $iban)
                        HoloField(label: "BIC", text: $bic).frame(width: 150)
                    }
                    HStack(spacing: 12) {
                        HoloField(label: "Website", text: $website)
                        HoloField(label: "Email", text: $email)
                    }
                    HoloField(label: "Nome firmatario (corsivo in fattura)", text: $firmatario, placeholder: "Emanuele Maccari")
                    HStack(spacing: 16) {
                        assetButton("Logo", path: logoPath) { pickAsset("logo") }
                        Spacer()
                    }
                    if let msg {
                        Text(msg).font(.system(size: 11))
                            .foregroundStyle(msg.hasPrefix("✓") ? Color(hex: 0x9af0c5) : Color(hex: 0xffb3ad))
                    }
                    HStack {
                        Spacer()
                        Button { save() } label: {
                            Text(saving ? "Salvataggio…" : "Salva dati")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Capsule().fill(LinearGradient(
                                    colors: [Color(red: 37/255, green: 99/255, blue: 235/255), Color(red: 79/255, green: 70/255, blue: 229/255)],
                                    startPoint: .leading, endPoint: .trailing)))
                        }
                        .buttonStyle(.plain).disabled(saving)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(maxWidth: 700)
        .task { await load() }
    }

    private func assetButton(_ label: String, path: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: path != nil ? "checkmark.circle.fill" : "photo.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(path != nil ? Color(hex: 0x9af0c5) : Holo.subDim)
                Text(path != nil ? "\(label) ✓" : "Carica \(label)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Holo.text)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .overlay(Capsule().strokeBorder(Color(red: 125/255, green: 175/255, blue: 1).opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let a = try? await HubAPI.getAzienda() {
            rs = a.ragione_sociale ?? ""; indirizzo = a.indirizzo ?? ""
            vat = a.vat_number ?? ""; reg = a.reg_number ?? ""
            iban = a.iban ?? ""; bic = a.bic ?? ""
            website = a.website ?? ""; email = a.email ?? ""
            firmatario = a.firmatario ?? ""
            logoPath = a.logo_path
        }
    }

    private func save() {
        saving = true; msg = nil
        Task {
            do {
                try await HubAPI.saveAzienda([
                    "ragione_sociale": nzS(rs), "indirizzo": nzS(indirizzo),
                    "vat_number": nzS(vat), "reg_number": nzS(reg),
                    "iban": nzS(iban), "bic": nzS(bic),
                    "website": nzS(website), "email": nzS(email),
                    "firmatario": nzS(firmatario), "logo_path": logoPath,
                ])
                await MainActor.run { saving = false; msg = "✓ Dati salvati" }
            } catch {
                await MainActor.run { saving = false; msg = error.localizedDescription }
            }
        }
    }

    private func pickAsset(_ kind: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased().isEmpty ? "png" : url.pathExtension.lowercased()
        let ct = ext == "png" ? "image/png" : "image/jpeg"
        let name = "\(kind).\(ext)"
        Task {
            do {
                _ = try await HubAPI.uploadAziendaAsset(data, name: name, contentType: ct)
                await MainActor.run {
                    logoPath = name
                    msg = "✓ \(kind.capitalized) caricato (ricorda di salvare)"
                }
            } catch {
                await MainActor.run { msg = error.localizedDescription }
            }
        }
    }

    private func nzS(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
