import SwiftUI

/// Controles centrales: EQ vertical por deck + crossfader (estilo VirtualDJ INICIAL)
struct CenterControlsView: View {
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        VStack(spacing: 6) {
            // Tabs AUDIO / Video
            HStack(spacing: 0) {
                Text("AUDIO")
                    .font(.system(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.3))
                    .foregroundStyle(Color.accentColor)
                Text("Video")
                    .font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .foregroundStyle(.secondary)
            }
            .cornerRadius(4)

            // Emparejar button
            HStack {
                Spacer()
                Button(action: {}) {
                    Text("Emparejar")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // EQ Section — 2 columnas (Deck A | Deck B) con sliders verticales
            HStack(spacing: 12) {
                // Deck A EQ
                eqColumn(deck: audioEngine.deckA)

                // Separador central
                VStack(spacing: 8) {
                    Text("AGUDO")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("MEDIO")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("BAJO")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 36)

                // Deck B EQ
                eqColumn(deck: audioEngine.deckB)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // MEZCLAR label
            Text("MEZCLAR")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(2)

            // Headphones
            HStack {
                Image(systemName: "headphones")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
            }

            // Crossfader A ←→ B
            VStack(spacing: 4) {
                HStack {
                    Text("A")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(audioEngine.crossfader < 0.5 ? Color.accentColor : .secondary)
                    Spacer()
                    Text("B")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(audioEngine.crossfader > 0.5 ? Color.accentColor : .secondary)
                }

                CrossfaderView(value: $audioEngine.crossfader)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(Color("BGSecondary").opacity(0.8))
    }

    // MARK: - EQ Column per deck (3 vertical sliders)

    private func eqColumn(deck: DeckState) -> some View {
        HStack(spacing: 6) {
            // AGUDO (High)
            verticalEQSlider(value: Binding(
                get: { deck.eqHigh },
                set: { deck.eqHigh = $0 }
            ), color: .orange)

            // MEDIO (Mid)
            verticalEQSlider(value: Binding(
                get: { deck.eqMid },
                set: { deck.eqMid = $0 }
            ), color: .green)

            // BAJO (Low)
            verticalEQSlider(value: Binding(
                get: { deck.eqLow },
                set: { deck.eqLow = $0 }
            ), color: .blue)
        }
    }

    // MARK: - Vertical EQ Slider

    private func verticalEQSlider(value: Binding<Double>, color: Color) -> some View {
        GeometryReader { geo in
            let height = geo.size.height
            let normalized = (value.wrappedValue + 1) / 2 // -1…1 → 0…1
            let knobY = height * (1 - normalized)

            ZStack {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 4)

                // Center line (0 position)
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 12, height: 1)
                    .offset(y: 0)

                // Active fill from center
                let centerY = height / 2
                let fillHeight = abs(knobY - centerY)
                let fillY = knobY < centerY ? knobY + fillHeight / 2 - centerY : knobY - fillHeight / 2 - centerY

                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.6))
                    .frame(width: 4, height: fillHeight)
                    .offset(y: fillY)

                // Knob
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: 20, height: 8)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(y: knobY - centerY)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let normalized = 1.0 - (drag.location.y / height)
                        let clamped = max(0, min(1, normalized))
                        value.wrappedValue = clamped * 2 - 1 // 0…1 → -1…1
                    }
            )
            .onTapGesture(count: 2) {
                value.wrappedValue = 0 // Reset to center
            }
        }
        .frame(width: 24)
    }
}

/// Crossfader horizontal
struct CrossfaderView: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 6)

                // Fill
                Capsule()
                    .fill(Color.red.opacity(0.6))
                    .frame(width: geo.size.width * value, height: 6)

                // Handle
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 24, height: 28)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: geo.size.width * value - 12)
                    .gesture(
                        DragGesture()
                            .onChanged { drag in
                                let newValue = drag.location.x / geo.size.width
                                value = max(0, min(1, newValue))
                            }
                    )
            }
        }
        .frame(height: 28)
    }
}
