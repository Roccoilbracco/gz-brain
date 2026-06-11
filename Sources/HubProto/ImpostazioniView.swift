import SwiftUI

// ─── Impostazioni: tema holo fisso (gli altri temi arriveranno), info config ───
struct ImpostazioniView: View {
    private var configPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.unvrslabs.hub/config.json").path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("IMPOSTAZIONI")
                    .font(.system(size: 19, weight: .heavy)).tracking(5)
                    .foregroundStyle(Holo.titleText)
                    .shadow(color: Color(red: 110/255, green: 180/255, blue: 1).opacity(0.7), radius: 9)

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TEMA").font(.system(size: 10, weight: .heavy)).tracking(2)
                            .foregroundStyle(Holo.hsl(217, 90, 70))
                        HStack(spacing: 10) {
                            HStack(spacing: 3) {
                                ForEach([0x0b142e, 0x2563eb, 0x34d399, 0xd97757], id: \.self) { c in
                                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: UInt32(c)))
                                        .frame(width: 16, height: 16)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("1 · Holo").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Holo.titleText)
                                Text("Centro di controllo sci-fi — blu profondo, glow, griglia circuito")
                                    .font(.system(size: 10.5)).foregroundStyle(Holo.subDim)
                            }
                            Spacer()
                            Text("ATTIVO").font(.system(size: 8.5, weight: .heavy)).tracking(1)
                                .foregroundStyle(Color(hex: 0x9af0c5))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .overlay(Capsule().strokeBorder(Color(hex: 0x34d399).opacity(0.55), lineWidth: 1))
                        }
                        Text("Gli altri temi della versione Tauri arriveranno qui dopo l'approvazione del port.")
                            .font(.system(size: 10.5)).foregroundStyle(Holo.labelDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
                }
                .frame(maxWidth: 700)

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CONFIGURAZIONE").font(.system(size: 10, weight: .heavy)).tracking(2)
                            .foregroundStyle(Holo.hsl(217, 90, 70))
                        HStack(spacing: 8) {
                            Circle().fill(SupabaseClient.shared != nil ? Color(hex: 0x34d399) : Color(hex: 0xff5f57))
                                .frame(width: 8, height: 8)
                                .shadow(color: SupabaseClient.shared != nil ? Color(hex: 0x34d399) : Color(hex: 0xff5f57), radius: 4)
                            Text(SupabaseClient.shared != nil ? "Supabase collegato" : "config.json mancante")
                                .font(.system(size: 12)).foregroundStyle(Holo.text)
                        }
                        Text(configPath)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(Holo.labelDim)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
                }
                .frame(maxWidth: 700)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 40, leading: 30, bottom: 34, trailing: 30))
        }
    }
}
