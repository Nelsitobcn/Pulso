import SwiftUI

/// Visualización de la forma de onda de una pista con posición de reproducción
struct WaveformView: View {
    @ObservedObject var deck: DeckState
    let onSeek: (Double) -> Void   // recibe progress 0.0…1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Waveform bars
                if let waveform = deck.track?.waveformData, !waveform.isEmpty {
                    // Barras ya reproducidas (más brillante)
                    WaveformBarsShape(samples: waveform, from: 0, to: deck.progress)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        ))

                    // Barras pendientes (más tenue)
                    WaveformBarsShape(samples: waveform, from: deck.progress, to: 1)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.15)],
                            startPoint: .top, endPoint: .bottom
                        ))
                } else {
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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let progress = max(0, min(1, value.location.x / geo.size.width))
                        onSeek(Double(progress))
                    }
            )
        }
    }
}

/// Shape que dibuja las barras de waveform en un rango de progreso [from, to]
struct WaveformBarsShape: Shape {
    let samples: [Float]
    let from: Double    // 0.0 … 1.0
    let to: Double      // 0.0 … 1.0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }

        let count = samples.count
        let barWidth = rect.width / CGFloat(count)
        let centerY = rect.midY

        let startIdx = Int((from * Double(count)).rounded(.up))
        let endIdx   = Int((to   * Double(count)).rounded(.down))
        guard startIdx <= endIdx else { return path }

        for i in startIdx...endIdx {
            guard i < count else { break }
            let x = CGFloat(i) * barWidth
            let height = CGFloat(samples[i]) * rect.height * 0.9
            let barRect = CGRect(
                x: x + barWidth * 0.1,
                y: centerY - height / 2,
                width: barWidth * 0.8,
                height: max(1, height)
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
