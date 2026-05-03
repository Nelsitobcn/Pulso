import SwiftUI

struct TopBarView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var libraryService: LibraryService

    @State private var selectedDesign = "INICIAL"
    @State private var selectedDesempen = "Defecto"
    @State private var selectedRack = "Elegir"
    @State private var selectedElegir = "Elegir"
    @State private var isMaestroActive = false
    @State private var cpuPercent: Int = 3
    @State private var currentTime = "00:00:00"

    var body: some View {
        HStack(spacing: 14) {
            // Avatar + Nombre DJ
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(authService.djName.isEmpty ? "DJ" : authService.djName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(minWidth: 130, alignment: .leading)

            // DISEÑO
            labeledMenu(title: "Diseño", selection: $selectedDesign,
                        options: ["INICIAL", "ESENCIAL", "PRO", "DESEMPEÑO"])

            // DESEMPEÑO
            labeledMenu(title: "Desempeño", selection: $selectedDesempen,
                        options: ["Defecto", "Estudio", "Club", "Festival"])

            Spacer()

            // 4 barras MAESTRO indicators (decoración)
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 22, height: 6)
                }
            }

            Spacer()

            // RACK
            labeledMenu(title: "Rack", selection: $selectedRack,
                        options: ["Elegir", "Defecto", "FX Pro"])

            // ELEGIR
            labeledMenu(title: "Elegir", selection: $selectedElegir,
                        options: ["Elegir", "Defecto", "Custom"])

            Spacer()

            // MAESTRO toggle
            Button(action: { isMaestroActive.toggle() }) {
                Text("MAESTRO")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isMaestroActive ? Color.accentColor : Color.white.opacity(0.08))
                    .foregroundStyle(isMaestroActive ? .white : .secondary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            // CPU
            Text("CPU \(cpuPercent)%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            // Reloj
            Text(currentTime)
                .font(.system(size: 11, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 64, alignment: .trailing)

            // Gear
            Button(action: {}) {
                Image(systemName: "gear")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Logo PULSO
            Text("PULSO")
                .font(.system(size: 12, design: .rounded).bold())
                .tracking(3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .onAppear { startClock() }
    }

    /// Menu con label "Título" + valor seleccionado a la derecha tipo VirtualDJ
    private func labeledMenu(title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Menu {
                ForEach(options, id: \.self) { opt in
                    Button(opt) { selection.wrappedValue = opt }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(selection.wrappedValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
