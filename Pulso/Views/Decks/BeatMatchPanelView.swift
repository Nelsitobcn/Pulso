import SwiftUI

/// Panel central de "Visualización de Combinación de Ritmo" (estilo Serato).
/// Muestra las ondas de Deck A (arriba) y Deck B (abajo) apiladas, ampliadas y en movimiento
/// continuo, con el beatgrid superpuesto y una barra de match arriba. Sirve para cuadrar los
/// beats de las dos canciones visualmente.
///
/// Se sitúa cruzando el ancho completo, bajo la barra superior, sin tocar los decks izq/der.
struct BeatMatchPanelView: View {
    @EnvironmentObject var audioEngine: AudioEngine

    /// Segundos de audio visibles a cada lado del playhead (ventana total = 2×). Menos = más zoom.
    private let halfWindow: Double = 3.0

    var body: some View {
        VStack(spacing: 3) {
            // Barra de match de beats (fase de cada deck; se encuentran en el centro al cuadrar).
            BeatMatchBar()
                .frame(height: 14)

            // Onda Deck A (arriba)
            ScrollingWaveformLane(deck: audioEngine.deckA, halfWindow: halfWindow, tint: .cyan)
                .frame(height: 46)
            // Onda Deck B (abajo)
            ScrollingWaveformLane(deck: audioEngine.deckB, halfWindow: halfWindow, tint: .orange)
                .frame(height: 46)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            // Línea de playhead central fija (el audio "pasa" por aquí).
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 1.5)
        )
    }
}

/// Una "calle" de onda que scrollea: muestra una ventana de ±halfWindow segundos centrada en el
/// playhead del deck. El waveform y el beatgrid se mueven; el playhead está fijo en el centro.
private struct ScrollingWaveformLane: View {
    @ObservedObject var deck: DeckState
    let halfWindow: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard let track = deck.track, track.duration > 0 else { return }
                let midY = size.height / 2
                let center = deck.currentTime                 // segundos, tiempo de archivo
                let winStart = center - halfWindow
                let winEnd   = center + halfWindow
                let winDur   = winEnd - winStart
                let dur = track.duration

                // 1) Onda (pico-a-pico + color por banda) de la ventana visible.
                if let d = track.waveformDetail, !d.isEmpty {
                    let n = d.count
                    // Recorremos por columna de PÍXEL para no dibujar de más.
                    let px = Int(size.width)
                    for x in 0..<px {
                        let t = winStart + (Double(x) / Double(px)) * winDur
                        guard t >= 0, t <= dur else { continue }
                        let i = min(n - 1, max(0, Int(t / dur * Double(n))))
                        let up   = CGFloat(d.maxs[i]) * midY * 0.9
                        let down = CGFloat(-d.mins[i]) * midY * 0.9
                        let lo = d.low[i], md = d.mid[i], hi = d.high[i]
                        let sum = max(0.0001, lo + md + hi)
                        let r = Double(lo/sum), g = Double(md/sum), b = Double(hi/sum)
                        let col = Color(red: 0.35 + 0.65*r, green: 0.30 + 0.55*g, blue: 0.40 + 0.60*b)
                        ctx.fill(Path(CGRect(x: CGFloat(x), y: midY - up, width: 1, height: up + down)),
                                 with: .color(col))
                    }
                } else {
                    ctx.fill(Path(CGRect(x: 0, y: midY - 1, width: size.width, height: 2)),
                             with: .color(.gray.opacity(0.2)))
                }

                // 2) Beatgrid superpuesto: líneas verticales en cada beat de la ventana.
                if let grid = track.beatGrid, !grid.beats.isEmpty {
                    let bpb = max(1, grid.beatsPerBar)
                    let db = grid.downbeatIndex
                    for (idx, beat) in grid.beats.enumerated() {
                        guard beat >= winStart, beat <= winEnd else { continue }
                        let x = (beat - winStart) / winDur * Double(size.width)
                        let isBar = db.map { (idx - $0) % bpb == 0 } ?? false
                        let w: CGFloat = isBar ? 2 : 1
                        let alpha = isBar ? 0.7 : 0.25
                        ctx.fill(Path(CGRect(x: CGFloat(x) - w/2, y: 0, width: w, height: size.height)),
                                 with: .color(.white.opacity(alpha)))
                    }
                }
            }
            .background(tint.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .topLeading) {
                Text("Deck \(deck.id.rawValue)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint.opacity(0.8))
                    .padding(2)
            }
        }
    }
}

/// Barra fina con dos marcadores (uno por deck) que representan la FASE dentro del beat.
/// Cuando los bombos de A y B coinciden, ambos marcadores caen en el centro exacto.
private struct BeatMatchBar: View {
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let phaseA = audioEngine.deckBeatPhase(.left)
            let phaseB = audioEngine.deckBeatPhase(.right)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))

                // Guía central (donde deben encontrarse).
                Rectangle().fill(Color.white.opacity(0.25))
                    .frame(width: 1).position(x: w/2, y: h/2)

                // Marcador de A y B: la fase [0,1) se mapea a [0,w]. Al cuadrar, ambos ≈ misma x.
                if let pa = phaseA {
                    marker(color: .cyan, x: CGFloat(pa) * w, h: h)
                }
                if let pb = phaseB {
                    marker(color: .orange, x: CGFloat(pb) * w, h: h)
                }

                // Verde cuando están alineados (diferencia de fase circular pequeña).
                if isMatched(phaseA, phaseB) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.green, lineWidth: 1.5)
                }
            }
        }
    }

    /// True si las fases de A y B están alineadas (distancia circular < 2%).
    private func isMatched(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return false }
        let d = abs(a - b)
        return min(d, 1 - d) < 0.02
    }

    private func marker(color: Color, x: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 6, height: h * 0.8)
            .position(x: x, y: h/2)
    }
}
