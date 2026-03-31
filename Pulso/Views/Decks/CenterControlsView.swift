import SwiftUI

/// Controles centrales: crossfader, volumen master, VU meters
struct CenterControlsView: View {
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        VStack(spacing: 16) {
            // Logo / branding
            Text("PULSO")
                .font(.system(.caption, design: .rounded).bold())
                .tracking(4)
                .foregroundStyle(Color.accentColor)

            Divider()

            // Volumen master
            VStack(spacing: 4) {
                Text("MASTER")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Slider(
                    value: $audioEngine.masterVolume,
                    in: 0...1
                )
                .tint(.white)
                .frame(height: 20)
            }

            // VU Meters reales desde el fader
            HStack(spacing: 6) {
                VUMeterView(label: "A", level: Double(audioEngine.vuLevelA))
                VUMeterView(label: "B", level: Double(audioEngine.vuLevelB))
            }

            Spacer()

            // Crossfader
            VStack(spacing: 6) {
                // Indicadores A / B
                HStack {
                    Text("A")
                        .font(.caption.bold())
                        .foregroundStyle(audioEngine.crossfader < 0.5 ? Color.accentColor : .secondary)
                    Spacer()
                    Text("B")
                        .font(.caption.bold())
                        .foregroundStyle(audioEngine.crossfader > 0.5 ? Color.accentColor : .secondary)
                }

                CrossfaderView(value: $audioEngine.crossfader)

                Text("CROSSFADER")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
    }
}

/// Crossfader horizontal con estética de hardware
struct CrossfaderView: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 6)

                // Relleno izquierdo
                Capsule()
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: geo.size.width * value, height: 6)

                // Fader handle
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 20, height: 32)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: geo.size.width * value - 10)
                    .gesture(
                        DragGesture()
                            .onChanged { drag in
                                let newValue = drag.location.x / geo.size.width
                                value = max(0, min(1, newValue))
                            }
                    )
            }
        }
        .frame(height: 32)
    }
}

/// VU Meter vertical con nivel real del engine
struct VUMeterView: View {
    let label: String
    var level: Double  // 0.0–1.0 desde AudioEngine

    private let segments = 12

    var body: some View {
        VStack(spacing: 2) {
            ForEach((0..<segments).reversed(), id: \.self) { i in
                let threshold = Double(i) / Double(segments)
                let active = level > threshold
                RoundedRectangle(cornerRadius: 2)
                    .fill(segmentColor(index: i, active: active))
                    .frame(width: 12, height: 4)
                    .animation(.easeOut(duration: 0.05), value: active)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func segmentColor(index: Int, active: Bool) -> Color {
        guard active else { return Color.gray.opacity(0.15) }
        if index >= segments - 2 { return .red }
        if index >= segments - 4 { return .yellow }
        return .green
    }
}
