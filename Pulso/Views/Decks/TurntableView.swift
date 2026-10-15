import SwiftUI

/// Plato giratorio visual — efecto vinilo
struct TurntableView: View {
    let isSpinning: Bool

    @State private var rotation: Double = 0
    @State private var animating: Bool  = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color("PlatterBase"))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)

            ForEach(1..<8) { i in
                Circle()
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 0.5)
                    .scaleEffect(CGFloat(i) / 8.0)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.3)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 30
                    )
                )
                .frame(width: 48, height: 48)

            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
        }
        .rotationEffect(.degrees(rotation))
        .onChange(of: isSpinning) { _, newValue in
            if newValue {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    rotation += 360
                }
                animating = true
            } else {
                // Detener la animación continua
                let current = rotation.truncatingRemainder(dividingBy: 360)
                withAnimation(.easeOut(duration: 0.6)) {
                    rotation = current
                }
                animating = false
            }
        }
    }
}
