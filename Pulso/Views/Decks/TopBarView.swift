import SwiftUI

struct TopBarView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var libraryService: LibraryService

    @State private var selectedDesign = "Defecto"
    @State private var selectedDesempen = "Defecto"
    @State private var selectedRack = "Elegir"
    @State private var isMaestroActive = false
    @State private var cpuPercent: Int = 3
    @State private var currentTime = "00:00:00"

    var body: some View {
        HStack(spacing: 12) {
            // Nombre DJ (izquierda)
            Text(authService.djName)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            // DISEÑO ▾
            Picker("Diseño", selection: $selectedDesign) {
                Text("Defecto").tag("Defecto")
            }
            .pickerStyle(.menu)
            .frame(width: 90)

            // DESEMPEÑO ▾
            Picker("Desempeño", selection: $selectedDesempen) {
                Text("Defecto").tag("Defecto")
            }
            .pickerStyle(.menu)
            .frame(width: 100)

            Spacer()

            // RACK ▾
            Picker("Rack", selection: $selectedRack) {
                Text("Elegir").tag("Elegir")
            }
            .pickerStyle(.menu)
            .frame(width: 80)

            // ELEGIR ▾
            Picker("Elegir", selection: $selectedDesign) {
                Text("Defecto").tag("Defecto")
            }
            .pickerStyle(.menu)
            .frame(width: 80)

            Spacer()

            // Botón MAESTRO
            Button(action: { isMaestroActive.toggle() }) {
                Text("MAESTRO")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isMaestroActive ? Color.accentColor : Color.white.opacity(0.08))
                    .foregroundStyle(isMaestroActive ? .white : .secondary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            // CPU indicator
            Text("CPU \(cpuPercent)%")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 50)

            // Reloj
            Text(currentTime)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 55)

            // Settings icon
            Button(action: {}) {
                Image(systemName: "gear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Logo PULSO (derecha)
            Text("PULSO")
                .font(.system(.caption, design: .rounded).bold())
                .tracking(2)
                .foregroundStyle(Color.accentColor)
        }
        .frame(height: 28)
        .onAppear {
            startClock()
        }
    }

    private func startClock() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                let formatter = DateFormatter()
                formatter.timeZone = TimeZone.current
                formatter.dateFormat = "HH:mm:ss"
                currentTime = formatter.string(from: Date())
            }
        }
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
