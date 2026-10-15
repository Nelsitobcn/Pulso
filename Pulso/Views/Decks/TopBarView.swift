import SwiftUI

struct TopBarView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var libraryService: LibraryService

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
