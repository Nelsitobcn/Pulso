import SwiftUI

struct WaveformView: View {
    @ObservedObject var deck: DeckState
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let waveform = deck.track?.waveformData, !waveform.isEmpty {
                    Canvas { ctx, size in
                        let count    = waveform.count
                        let barW     = size.width / CGFloat(count)
                        let midY     = size.height / 2
                        let progress = deck.progress

                        for i in 0..<count {
                            let x      = CGFloat(i) * barW
                            let h      = max(2, CGFloat(waveform[i]) * size.height * 0.9)
                            let rect   = CGRect(x: x + barW * 0.1,
                                                y: midY - h / 2,
                                                width: barW * 0.8,
                                                height: h)
                            let played = Double(i) / Double(count) < progress
                            ctx.fill(
                                Path(roundedRect: rect, cornerRadius: 1),
                                with: .color(played ? Color.accentColor : Color.accentColor.opacity(0.3))
                            )
                        }
                    }
                } else {
                    ZStack {
                        Color.gray.opacity(0.12)
                        Text("Sin pista cargada")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Línea de playhead
                Color.white.opacity(0.85)
                    .frame(width: 2)
                    .offset(x: geo.size.width * deck.progress - 1)

                if let dur = deck.track?.duration, dur > 0 {
                    ForEach(deck.hotCues) { cue in
                        cue.color.swiftUIColor
                            .frame(width: 3)
                            .offset(x: geo.size.width * (cue.time / dur) - 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onSeek(max(0, min(1, Double(v.location.x / geo.size.width))))
                    }
            )
        }
    }
}

extension HotCueColor {
    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }
}

// Triangle sigue existiendo para otros usos
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
