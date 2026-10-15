import Foundation
import AVFoundation
import Accelerate

/// Picos de alta densidad (min/max por columna) para dibujar la onda AMPLIADA del panel de
/// beatmatch con detalle real (estilo Serato), no bloques.
///
/// Por qué existe: `Track.waveformDetail` tiene ~3000 columnas para toda la pista (miniatura
/// general). Al ampliar una ventana de ~6s en el panel central, esas 3000 columnas aportan
/// solo ~80 muestras en la ventana → cada una se estira ~17px = bloque macizo. Aquí generamos
/// ~200 columnas por segundo (≈ 1 px por columna a la escala del panel) leyendo el audio.
///
/// Se guarda SOLO en RAM (no en disco): ~44 KB/min por pista (min+max Float). Se genera al
/// cargar la pista en un deck y se descarta al descargarla.
struct HiResPeaks {
    /// Columnas por segundo (densidad). ~200 da ~5 ms/columna → detalle de aguja al ampliar.
    let columnsPerSecond: Double
    let mins: [Float]
    let maxs: [Float]
    /// Bandas de color por columna (mismas que waveformDetail, para heredar el color por
    /// frecuencia). Opcionales: si el cálculo FFT por columna es caro a esta densidad, se
    /// dejan vacías y el panel colorea por amplitud.
    let low: [Float]
    let mid: [Float]
    let high: [Float]

    var count: Int { maxs.count }

    /// Índice de columna para un tiempo dado (segundos). Clampa a rango válido.
    func index(atTime t: Double) -> Int {
        min(max(0, Int(t * columnsPerSecond)), max(0, count - 1))
    }
}

/// Caché en memoria de los picos de alta densidad, indexada por id de pista.
@MainActor
final class HiResWaveformCache: ObservableObject {
    static let shared = HiResWaveformCache()

    /// Publica el id de la última pista añadida para que las vistas SwiftUI se refresquen.
    @Published private(set) var lastUpdated: UUID?

    private var cache: [UUID: HiResPeaks] = [:]
    private var inFlight: Set<UUID> = []

    func peaks(for trackID: UUID) -> HiResPeaks? { cache[trackID] }

    /// Genera (si falta) los picos de alta densidad de una pista, en background. Idempotente.
    func ensure(track: Track, columnsPerSecond: Double = 200) {
        guard cache[track.id] == nil, !inFlight.contains(track.id) else { return }
        inFlight.insert(track.id)
        let id = track.id
        let url = track.url
        Task.detached(priority: .userInitiated) {
            let peaks = await Self.build(url: url, columnsPerSecond: columnsPerSecond)
            await MainActor.run {
                if let peaks { self.cache[id] = peaks; self.lastUpdated = id }
                self.inFlight.remove(id)
            }
        }
    }

    /// Descarta los picos de una pista (al expulsarla del deck) para liberar RAM.
    func evict(trackID: UUID) { cache[trackID] = nil }

    // MARK: - Generación (fuera del main actor)

    private static func build(url: URL, columnsPerSecond: Double) async -> HiResPeaks? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let frameCount = Int(file.length)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount)),
              (try? file.read(into: buf)) != nil,
              let chans = buf.floatChannelData else { return nil }

        let n = Int(buf.frameLength)
        let sr = fmt.sampleRate
        let channelCount = Int(fmt.channelCount)

        // Mono-mix (L+R)/2 — igual que el waveform general, para no perder audio paneado.
        var mono = [Float](repeating: 0, count: n)
        if channelCount >= 2 {
            vDSP_vadd(chans[0], 1, chans[1], 1, &mono, 1, vDSP_Length(n))
            var half: Float = 0.5
            vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(n))
        } else {
            mono = Array(UnsafeBufferPointer(start: chans[0], count: n))
        }

        let durSec = Double(n) / sr
        let cols = max(1, Int(durSec * columnsPerSecond))
        let per = Double(n) / Double(cols)
        var mins = [Float](repeating: 0, count: cols)
        var maxs = [Float](repeating: 0, count: cols)
        mono.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress!
            for c in 0..<cols {
                let start = Int(Double(c) * per)
                let end = (c == cols - 1) ? n : min(n, Int(Double(c + 1) * per))
                let cnt = max(1, end - start)
                var mn: Float = 0, mx: Float = 0
                vDSP_minv(base + start, 1, &mn, vDSP_Length(cnt))
                vDSP_maxv(base + start, 1, &mx, vDSP_Length(cnt))
                mins[c] = mn; maxs[c] = mx
            }
        }
        // Color: reusamos las bandas del waveformDetail general (interpoladas) en la vista;
        // aquí dejamos las bandas vacías para no repetir la FFT a esta densidad (sería caro).
        return HiResPeaks(columnsPerSecond: columnsPerSecond,
                          mins: mins, maxs: maxs, low: [], mid: [], high: [])
    }
}
