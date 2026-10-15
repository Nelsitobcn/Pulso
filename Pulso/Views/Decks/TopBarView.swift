import SwiftUI

struct TopBarView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        HStack {
            // Estado de análisis
            if libraryService.isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analizando \(Int(libraryService.analysisProgress * 100))%...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // REC: graba la salida master a WAV (~/Music/Pulso Recordings)
            Button {
                audioEngine.toggleRecording()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(audioEngine.isRecording ? Color.red : Color.secondary.opacity(0.6))
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(audioEngine.isRecording ? Color.red.opacity(0.25) : Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(audioEngine.isRecording ? "Parar grabación" : "Grabar el set (WAV en ~/Music/Pulso Recordings)")

            if !audioEngine.isRecording, let url = audioEngine.lastRecordingURL {
                Text("Guardado: \(url.lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
            }

            Spacer()

            // Nombre de DJ y plan
            HStack(spacing: 8) {
                Text(authService.djName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PlanBadgeView(plan: authService.plan)
            }
        }
        .frame(height: 28)
    }
}

struct PlanBadgeView: View {
    let plan: AuthService.SubscriptionPlan

    var body: some View {
        Text(plan.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(plan.color.opacity(0.2))
            .foregroundStyle(plan.color)
            .clipShape(Capsule())
    }
}

extension AuthService.SubscriptionPlan {
    var color: Color {
        switch self {
        case .free: return .gray
        case .pro: return .accentColor
        case .proPlus: return .purple
        }
    }
}
