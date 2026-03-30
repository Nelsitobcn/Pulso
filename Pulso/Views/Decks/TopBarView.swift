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

            // Info de usuario + plan
            HStack(spacing: 8) {
                if let user = authService.currentUser {
                    Text(user.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    PlanBadgeView(plan: user.plan)
                }

                Button {
                    authService.signOut()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cerrar sesión")
            }
        }
        .frame(height: 28)
    }
}

struct PlanBadgeView: View {
    let plan: PulsoUser.SubscriptionPlan

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

extension PulsoUser.SubscriptionPlan {
    var displayName: String {
        switch self {
        case .free: return "FREE"
        case .pro: return "PRO"
        case .proPlus: return "PRO+"
        }
    }

    var color: Color {
        switch self {
        case .free: return .gray
        case .pro: return .accentColor
        case .proPlus: return .purple
        }
    }
}
