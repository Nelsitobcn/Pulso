import SwiftUI

/// Pantalla de login/registro
struct AuthView: View {
    @EnvironmentObject var authService: AuthService
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""

    var body: some View {
        ZStack {
            // Fondo degradado
            LinearGradient(
                colors: [Color.black, Color("BGPrimary")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                // Logo
                VStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse)

                    Text("PULSO")
                        .font(.system(.largeTitle, design: .rounded).bold())
                        .tracking(8)
                        .foregroundStyle(.white)

                    Text("Professional DJ Software")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Formulario
                VStack(spacing: 14) {
                    if isSignUp {
                        PulsoTextField(icon: "person", placeholder: "Nombre de DJ", text: $displayName)
                    }

                    PulsoTextField(icon: "envelope", placeholder: "Email", text: $email)
                        .textContentType(.emailAddress)

                    PulsoTextField(icon: "lock", placeholder: "Contraseña", text: $password, isSecure: true)
                        .textContentType(isSignUp ? .newPassword : .password)

                    // Error
                    if let error = authService.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }

                    // Botón principal
                    Button {
                        Task {
                            if isSignUp {
                                await authService.signUp(email: email, password: password, displayName: displayName)
                            } else {
                                await authService.signIn(email: email, password: password)
                            }
                        }
                    } label: {
                        HStack {
                            if authService.isLoading {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(isSignUp ? "Crear cuenta" : "Iniciar sesión")
                                .bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(authService.isLoading)

                    // Toggle login/registro
                    Button {
                        withAnimation { isSignUp.toggle() }
                        authService.errorMessage = nil
                    } label: {
                        Text(isSignUp ? "¿Ya tienes cuenta? Inicia sesión" : "¿Sin cuenta? Regístrate gratis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 360)
            }
            .padding(40)
        }
        .frame(minWidth: 480, minHeight: 520)
        .preferredColorScheme(.dark)
    }
}

struct PulsoTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
                .frame(width: 20)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}
