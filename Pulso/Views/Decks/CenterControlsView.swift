import SwiftUI

/// Mixer central estilo VirtualDJ: 2 columnas de knobs (AGUDO/MEDIO/BAJO) + VU central + crossfader
struct CenterControlsView: View {
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        VStack(spacing: 0) {
            // Tabs AUDIO / Video
            HStack(spacing: 0) {
                Text("AUDIO")
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.25))
                    .foregroundStyle(Color.accentColor)
                Text("Video")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))
                    .foregroundStyle(.secondary)
            }
            .cornerRadius(4)
            .padding(.horizontal, 6)
            .padding(.top, 6)

            HStack {
                Spacer()
                Button(action: {}) {
                    Text("Emparejar")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            Spacer().frame(height: 6)

            // EQ KNOBS — 2 columnas (Deck A | VU central | Deck B)
            HStack(alignment: .top, spacing: 0) {
                eqColumn(deck: audioEngine.deckA)
                    .frame(maxWidth: .infinity)

                centralVU
                    .frame(width: 28)

                eqColumn(deck: audioEngine.deckB)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 8)

            // Bottom: MEZCLAR + auriculares + crossfader
            VStack(spacing: 6) {
                Text("MEZCLAR")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(2)

                Image(systemName: "headphones")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)

                HStack {
                    Text("A")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(audioEngine.crossfader < 0.5 ? Color.accentColor : .secondary)
                    Spacer()
                    Text("B")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(audioEngine.crossfader > 0.5 ? Color.accentColor : .secondary)
                }
                .padding(.horizontal, 4)

                CrossfaderView(value: $audioEngine.crossfader)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .background(Color("BGSecondary").opacity(0.6))
    }

    private func eqColumn(deck: DeckState) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("AGUDO")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                MixerKnob(value: Binding(get: { deck.eqHigh }, set: { deck.eqHigh = $0 }), color: .orange)
            }

            VStack(spacing: 4) {
                Text("MEDIO")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                MixerKnob(value: Binding(get: { deck.eqMid }, set: { deck.eqMid = $0 }), color: Color(red: 0.2, green: 0.85, blue: 0.4))
            }

            VStack(spacing: 4) {
                Text("BAJO")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                MixerKnob(value: Binding(get: { deck.eqLow }, set: { deck.eqLow = $0 }), color: Color(red: 0.3, green: 0.6, blue: 1.0))
            }
        }
        .padding(.vertical, 6)
    }

    private var centralVU: some View {
        VStack(spacing: 1) {
            ForEach((0..<24).reversed(), id: \.self) { i in
                let threshold = Double(i) / 24.0
                let levelL = Double(audioEngine.vuLevelA)
                let levelR = Double(audioEngine.vuLevelB)
                let activeL = levelL > threshold
                let activeR = levelR > threshold

                HStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(activeL ? barColor(i) : Color.white.opacity(0.08))
                        .frame(width: 5, height: 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(activeR ? barColor(i) : Color.white.opacity(0.08))
                        .frame(width: 5, height: 4)
                }
            }
        }
        .padding(.top, 14)
    }

    private func barColor(_ index: Int) -> Color {
        if index >= 22 { return .red }
        if index >= 18 { return .yellow }
        return .green
    }
}

// MARK: - MixerKnob — knob bonito 50x50 con look profesional

struct MixerKnob: View {
    @Binding var value: Double
    let color: Color

    @State private var lastDragY: CGFloat = 0
    @State private var isDragging = false

    private let size: CGFloat = 50

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.5), Color.black.opacity(0.0)],
                        center: .center,
                        startRadius: size * 0.4,
                        endRadius: size * 0.6
                    )
                )
                .frame(width: size + 6, height: size + 6)

            Circle()
                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 3)
                .frame(width: size, height: size)

            Circle()
                .trim(from: 0.1, to: max(0.105, 0.1 + 0.8 * ((value + 1) / 2)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-225))

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.black.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size - 12, height: size - 12)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )

            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: size * 0.28)
                .offset(y: -(size * 0.18))
                .rotationEffect(.degrees(value * 135))

            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 3, height: 3)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        lastDragY = drag.location.y
                        return
                    }
                    let delta = Double(lastDragY - drag.location.y) / 100.0
                    lastDragY = drag.location.y
                    value = max(-1.0, min(1.0, value + delta))
                }
                .onEnded { _ in
                    isDragging = false
                    lastDragY = 0
                }
        )
        .onLongPressGesture(minimumDuration: 0.5) {
            value = 0
        }
    }
}

// MARK: - Crossfader rojo VirtualDJ

struct CrossfaderView: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.4))
                    .frame(height: 8)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.7), Color.red.opacity(0.5)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * value, height: 8)

                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color.gray.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 22, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .offset(x: geo.size.width * value - 11)
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
