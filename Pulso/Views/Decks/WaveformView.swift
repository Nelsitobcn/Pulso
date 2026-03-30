import SwiftUI

/// Visualización de la forma de onda de una pista con posición de reproducción
struct WaveformView: View {
    @ObservedObject var deck: DeckState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Waveform bars
                if let waveform = deck.track?.waveformData, !waveform.isEmpty {
                    WaveformBarsShape(samples: waveform, progress: deck.progress)
                        .fill(waveformGradient(width: geo.size.width))
                } else {
                    // Placeholder cuando no hay canción
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .overlay(
                            Text("Sin pista")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        )
                }

                // Línea de posición actual
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2)
                    .offset(x: geo.size.width * deck.progress - 1)

                // Marcador de cue
                if let cue = deck.cuePoint, let duration = deck.track?.duration, duration > 0 {
                    let cueX = geo.size.width * (cue / duration)
                    Triangle()
                        .fill(Color.yellow)
                        .frame(width: 8, height: 8)
                        .offset(x: cueX - 4, y: -4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Gesture para seek
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        _ = value.location.x / geo.size.width
                    }
            )
        }
    }

    private func waveformGradient(width: CGFloat) -> LinearGradient {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.5)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Shape que dibuja las barras de la waveform
struct WaveformBarsShape: Shape {
    let samples: [Float]
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }

        let barWidth = rect.width / CGFloat(samples.count)
        let centerY = rect.midY

        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * barWidth
            let height = CGFloat(sample) * rect.height * 0.9
            let barRect = CGRect(
                x: x + barWidth * 0.1,
                y: centerY - height / 2,
                width: barWidth * 0.8,
                height: height
            )
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
