import Foundation
import SwiftUI

/// Perfil local del DJ — sin backend, sin login
/// En Fase 3 (suscripciones) se añadirá RevenueCat + App Store
@MainActor
final class AuthService: ObservableObject {
    @Published var djName: String {
        didSet { UserDefaults.standard.set(djName, forKey: "pulso_dj_name") }
    }
    @Published var plan: SubscriptionPlan = .free

    init() {
        djName = UserDefaults.standard.string(forKey: "pulso_dj_name") ?? "DJ"
    }

    enum SubscriptionPlan: String, Codable {
        case free, pro, proPlus

        var displayName: String {
            switch self {
            case .free: return "Free"
            case .pro: return "Pro"
            case .proPlus: return "Pro+"
            }
        }
    }
}
