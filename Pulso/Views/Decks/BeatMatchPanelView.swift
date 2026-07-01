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
/// Se puede ARRASTRAR como un vinilo (mover la pista) — ver el DragGesture al final.
private struct ScrollingWaveformLane: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine
    @ObservedObject private var hires = HiResWaveformCache.shared
    let halfWindow: Double
    let tint: Color

    // Estado del arrastre tipo vinilo.
    @State private var dragAnchorTime: Double? = nil   // currentTime al empezar el arrastre

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard let track = deck.track, track.duration > 0 else { return }
                let midY = size.height / 2
                let center = deck.currentTime
                let winStart = center - halfWindow
                let winDur   = 2 * halfWindow
                let dur = track.duration
                let W = Int(size.width)

                // Color por banda: lo tomamos del waveformDetail general (interpolado por
                // tiempo), ya que los HiRes peaks no llevan FFT. Si no hay, color por amplitud.
                let bands = track.waveformDetail
                func colorAt(_ t: Double, amp: Float) -> Color {
                    if let b = bands, !b.isEmpty {
                        let j = min(b.count - 1, max(0, Int(t / dur * Double(b.count))))
                        let lo = b.low[j], md = b.mid[j], hi = b.high[j]
                        let s = max(0.0001, lo + md + hi)
                        return Color(red: 0.35 + 0.65*Double(lo/s),
                                     green: 0.30 + 0.55*Double(md/s),
                                     blue: 0.40 + 0.60*Double(hi/s))
                    }
                    return Color(hue: 0.55, saturation: 0.5, brightness: 0.6 + 0.4*Double(amp))
                }

                // 1) Onda estilo AGUJA/HILO: una línea fina de 1px por columna de píxel, usando
                // los picos de ALTA DENSIDAD (si están) para que no sea un bloque. Silueta espejo.
                if let hi = hires.peaks(for: track.id), hi.count > 0 {
                    for x in 0..<W {
                        let t = winStart + (Double(x) / Double(W)) * winDur
                        guard t >= 0, t <= dur else { continue }
                        let i = hi.index(atTime: t)
                        let up   = CGFloat(hi.maxs[i]) * midY * 0.92
                        let down = CGFloat(-hi.mins[i]) * midY * 0.92
                        let amp = max(hi.maxs[i], -hi.mins[i])
                        var path = Path()
                        path.move(to: CGPoint(x: CGFloat(x) + 0.5, y: midY - up))
                        path.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: midY + down))
                        ctx.stroke(path, with: .color(colorAt(t, amp: amp)), lineWidth: 1)
                    }
                } else if let d = track.waveformDetail, !d.isEmpty {
                    // Fallback mientras se generan los HiRes: onda general (se verá menos fina).
                    let n = d.count
                    for x in 0..<W {
                        let t = winStart + (Double(x) / Double(W)) * winDur
                        guard t >= 0, t <= dur else { continue }
                        let i = min(n - 1, max(0, Int(t / dur * Double(n))))
                        let up = CGFloat(d.maxs[i]) * midY * 0.9
                        let down = CGFloat(-d.mins[i]) * midY * 0.9
                        var path = Path()
                        path.move(to: CGPoint(x: CGFloat(x) + 0.5, y: midY - up))
                        path.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: midY + down))
                        ctx.stroke(path, with: .color(colorAt(t, amp: 0.5)), lineWidth: 1)
                    }
                }

                // 2) Beatgrid superpuesto.
                if let grid = track.beatGrid, !grid.beats.isEmpty {
                    let bpb = max(1, grid.beatsPerBar)
                    let db = grid.downbeatIndex
                    for (idx, beat) in grid.beats.enumerated() {
                        guard beat >= winStart, beat <= winStart + winDur else { continue }
                        let x = (beat - winStart) / winDur * Double(size.width)
                        let isBar = db.map { (idx - $0) % bpb == 0 } ?? false
                        let w: CGFloat = isBar ? 1.5 : 0.75
                        let alpha = isBar ? 0.6 : 0.2
                        ctx.fill(Path(CGRect(x: CGFloat(x) - w/2, y: 0, width: w, height: size.height)),
                                 with: .color(.white.opacity(alpha)))
                    }
                }
            }
            .background(tint.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            // ARRASTRE TIPO VINILO: agarrar y mover la onda desplaza la pista. Al arrastrar a la
            // DERECHA la onda va con el dedo → la pista RETROCEDE (como empujar un plato).
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        guard let track = deck.track, track.duration > 0 else { return }
                        if dragAnchorTime == nil {
                            dragAnchorTime = deck.currentTime
                            audioEngine.beginScrub(deck: deck.id)
                        }
                        let secPerPx = (2 * halfWindow) / Double(geo.size.width)
                        // translation.width > 0 (arrastrar a la derecha) → retroceder en el tiempo.
                        let deltaT = -Double(v.translation.width) * secPerPx
                        let target = min(max(0, (dragAnchorTime ?? 0) + deltaT), track.duration)
                        audioEngine.scrub(to: target, deck: deck.id)
                    }
                    .onEnded { _ in
                        dragAnchorTime = nil
                        audioEngine.endScrub(deck: deck.id)
                    }
            )
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
