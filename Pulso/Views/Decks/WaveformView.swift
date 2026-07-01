import SwiftUI

struct WaveformView: View {
    @ObservedObject var deck: DeckState
    let onSeek: (Double) -> Void

    /// Fracción [0,1] → tiempo, respetando el rango visible por zoom.
    private func fractionToProgress(_ xFraction: Double) -> Double {
        let (start, end) = deck.waveformVisibleRange
        return start + xFraction * (end - start)
    }

    var body: some View {
        GeometryReader { geo in
            let (visStart, visEnd) = deck.waveformVisibleRange
            let visWidth = max(0.0001, visEnd - visStart)

            ZStack(alignment: .leading) {
                if let waveform = deck.track?.waveformData, !waveform.isEmpty {
                    Canvas { ctx, size in
                        let count = waveform.count
                        let midY  = size.height / 2
                        // Solo dibujamos las muestras dentro de la ventana visible, estiradas
                        // a todo el ancho → esto ES el zoom.
                        let firstIdx = Int(Double(count) * visStart)
                        let lastIdx  = min(count, Int(Double(count) * visEnd) + 1)
                        guard lastIdx > firstIdx else { return }
                        let visibleCount = lastIdx - firstIdx
                        let barW = size.width / CGFloat(visibleCount)
                        let progress = deck.progress

                        for i in firstIdx..<lastIdx {
                            let x = CGFloat(i - firstIdx) * barW
                            let h = max(2, CGFloat(waveform[i]) * size.height * 0.9)
                            let rect = CGRect(x: x + barW * 0.1, y: midY - h / 2,
                                              width: max(0.5, barW * 0.8), height: h)
                            let sampleProg = Double(i) / Double(count)
                            let played = sampleProg < progress
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

                // Playhead: su x depende del rango visible (si está fuera, se sale de cuadro).
                let playheadFrac = (deck.progress - visStart) / visWidth
                if playheadFrac >= 0, playheadFrac <= 1 {
                    Color.white.opacity(0.85)
                        .frame(width: 2)
                        .offset(x: geo.size.width * playheadFrac - 1)
                }

                if let dur = deck.track?.duration, dur > 0 {
                    // Marcas de beat + downbeat del beatgrid, reposicionadas según el zoom.
                    if let grid = deck.track?.beatGrid, !grid.beats.isEmpty {
                        Canvas { ctx, size in
                            let dbIndex = grid.downbeatIndex
                            let bpb = max(1, grid.beatsPerBar)
                            for (i, beat) in grid.beats.enumerated() {
                                let frac = (beat / dur - visStart) / visWidth
                                guard frac >= 0, frac <= 1 else { continue }
                                let x = size.width * frac
                                let isBar = dbIndex.map { (i - $0) % bpb == 0 } ?? false
                                let w: CGFloat = isBar ? 2 : 1
                                let color: Color = isBar ? .white.opacity(0.55) : .white.opacity(0.14)
                                ctx.fill(Path(CGRect(x: x - w / 2, y: 0, width: w, height: size.height)),
                                         with: .color(color))
                            }
                        }
                        .allowsHitTesting(false)
                    }

                    // Hot cues, reposicionados según el zoom.
                    ForEach(deck.hotCues) { cue in
                        let frac = (cue.time / dur - visStart) / visWidth
                        if frac >= 0, frac <= 1 {
                            cue.color.swiftUIColor
                                .frame(width: 3)
                                .offset(x: geo.size.width * frac - 1)
                        }
                    }
                }

                // Indicador de zoom (solo si hay zoom activo)
                if deck.waveformZoom > 1.01 {
                    Text(String(format: "%.0f×", deck.waveformZoom))
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.5))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let xFrac = max(0, min(1, Double(v.location.x / geo.size.width)))
                        onSeek(fractionToProgress(xFrac))
                    }
            )
            #if os(macOS)
            // Rueda del ratón = zoom (con ⌥ o sin modificador). Trackpad pinch también.
            .modifier(ScrollZoomModifier(deck: deck))
            #endif
        }
    }
}

#if os(macOS)
/// Captura la rueda del ratón sobre la waveform para hacer zoom [1×,32×].
/// Al cambiar el zoom se fija el centro en el playhead actual (empieza a seguirlo).
private struct ScrollZoomModifier: ViewModifier {
    @ObservedObject var deck: DeckState

    func body(content: Content) -> some View {
        content.background(ScrollCatcher { deltaY in
            let factor = 1.0 + (deltaY * 0.01)
            let newZoom = min(32.0, max(1.0, deck.waveformZoom * factor))
            if abs(newZoom - deck.waveformZoom) > 0.001 {
                // Al hacer zoom, centrar en el playhead y seguirlo (no scroll manual).
                deck.waveformManualScroll = false
                deck.waveformZoom = newZoom
                if newZoom <= 1.001 { deck.waveformManualScroll = false }
            }
        })
    }
}

/// NSView puente que reenvía scrollWheel a un callback SwiftUI.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (Double) -> Void
    func makeNSView(context: Context) -> NSView { ScrollNSView(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ScrollNSView: NSView {
        let onScroll: (Double) -> Void
        init(onScroll: @escaping (Double) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func scrollWheel(with event: NSEvent) {
            // scrollingDeltaY: positivo = scroll arriba = zoom in.
            let dy = event.scrollingDeltaY
            if dy != 0 { onScroll(Double(dy)) } else { super.scrollWheel(with: event) }
        }
    }
}
#endif

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
