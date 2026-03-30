import Foundation
import SwiftUI

/// Servicio de autenticación — preparado para Firebase Auth
/// En Fase 1 usa un mock local; en Fase 2 se conecta a Firebase
@MainActor
final class AuthService: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: PulsoUser?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let userDefaultsKey = "pulso_user"

    init() {
        // Cargar sesión guardada
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let user = try? JSONDecoder().decode(PulsoUser.self, from: data) {
            currentUser = user
            isAuthenticated = true
        }
    }

    // MARK: - Auth actions

    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil

        // TODO: Reemplazar con Firebase Auth en Fase 2
        // FirebaseApp.configure() + Auth.auth().signIn(withEmail:password:)
        try? await Task.sleep(nanoseconds: 800_000_000) // simula latencia de red

        if email.contains("@") && password.count >= 6 {
            let user = PulsoUser(id: UUID().uuidString, email: email, displayName: email.components(separatedBy: "@").first ?? "DJ")
            currentUser = user
            isAuthenticated = true
            if let data = try? JSONEncoder().encode(user) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        } else {
            errorMessage = "Email o contraseña incorrectos"
        }

        isLoading = false
    }

    func signUp(email: String, password: String, displayName: String) async {
        isLoading = true
        errorMessage = nil

        try? await Task.sleep(nanoseconds: 800_000_000)

        if email.contains("@") && password.count >= 6 {
            let user = PulsoUser(id: UUID().uuidString, email: email, displayName: displayName)
            currentUser = user
            isAuthenticated = true
            if let data = try? JSONEncoder().encode(user) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        } else {
            errorMessage = "Introduce un email válido y contraseña de al menos 6 caracteres"
        }

        isLoading = false
    }

    func signOut() {
        currentUser = nil
        isAuthenticated = false
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

struct PulsoUser: Codable {
    let id: String
    let email: String
    var displayName: String
    var plan: SubscriptionPlan = .free

    enum SubscriptionPlan: String, Codable {
        case free, pro, proPlus
    }
}
