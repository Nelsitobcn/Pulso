import SwiftUI

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

struct EQKnob: View {
    let label: String
    @Binding var value: Double    // -1.0 (kill) a +1.0 (boost)
    let color: Color

    @State private var lastDragY: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.3), lineWidth: 3)
                    .frame(width: 44, height: 44)

                Circle()
                    .trim(from: 0.1, to: max(0.105, 0.1 + 0.8 * ((value + 1) / 2)))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-225))

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 12)
                    .offset(y: -10)
                    .rotationEffect(.degrees(value * 135))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            lastDragY = drag.location.y
                            return
                        }
                        let delta = Double(lastDragY - drag.location.y) / 80.0
                        lastDragY = drag.location.y
                        value = max(-1.0, min(1.0, value + delta))
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastDragY = 0
                    }
            )
            // Reset con long press (no interfiere con drag)
            .onLongPressGesture(minimumDuration: 0.5) {
                value = 0
            }

            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        }
    }
}
