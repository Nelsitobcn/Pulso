import SwiftUI

/// Controles de EQ de 3 bandas para un deck
struct EQView: View {
    @ObservedObject var deck: DeckState

    var body: some View {
        HStack(spacing: 16) {
            EQKnob(label: "LOW", value: $deck.eqLow, color: .blue)
            EQKnob(label: "MID", value: $deck.eqMid, color: .green)
            EQKnob(label: "HIGH", value: $deck.eqHigh, color: .orange)
        }
    }
}

/// Knob circular para cada banda de EQ
struct EQKnob: View {
    let label: String
    @Binding var value: Double    // -1.0 (kill) a +1.0 (boost)
    let color: Color

    // Guardamos el valor al inicio del drag para calcular el delta desde ahí
    @State private var valueAtDragStart: Double = 0
    @State private var dragStartY: CGFloat = 0
    @State private var isDragging: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Track del knob
                Circle()
                    .strokeBorder(Color.gray.opacity(0.3), lineWidth: 3)
                    .frame(width: 44, height: 44)

                // Arco de valor
                Circle()
                    .trim(from: 0.1, to: max(0.1, 0.1 + 0.8 * ((value + 1) / 2)))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-225))

                // Indicador central
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 12)
                    .offset(y: -10)
                    .rotationEffect(.degrees(value * 135))

                // Double-click para reset a centro
                Color.clear
                    .frame(width: 44, height: 44)
                    .onTapGesture(count: 2) { value = 0 }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if !isDragging {
                            // Capturar estado inicial solo una vez por gesto
                            isDragging = true
                            dragStartY = drag.startLocation.y
                            valueAtDragStart = value
                        }
                        // Delta desde el inicio del gesto — sin acumulación
                        let deltaY = dragStartY - drag.location.y
                        let newValue = valueAtDragStart + Double(deltaY) / 60.0
                        value = max(-1.0, min(1.0, newValue))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )

            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        }
    }
}
