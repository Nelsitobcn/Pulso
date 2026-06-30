import AVFoundation
import Accelerate

// MARK: - Motor de beatgrid + downbeat (Sesión 1, jul-2026)
//
// Diseño "robusto y barato" (decisión owner) validado por concilio multi-modelo
// (Gemini 2.5 Pro + Codex + Claude) y research NotebookLM deep (98 fuentes). Consenso unánime:
//
//   • Swift puro + Accelerate/vDSP. NADA de aubio/BTrack/QM-DSP/Essentia: todas son GPL/AGPL
//     copyleft → bloquean la distribución en App Store (Fase 3 de Pulso). Hallazgo crítico del
//     research: aubio NO es BSD como mucha gente cree, es GPL-3.
//   • Beats por Dynamic Programming tipo Ellis 2007 (camino de menor coste sobre el onset
//     envelope, penalizando desvíos del período de beat). No peak-picking ingenuo.
//   • Downbeat por heurística 4/4: energía sub-bass (<150 Hz) que ancla el "1" en la mayoría de
//     géneros. Es heurística, NO certeza → en Sesión 2 la UI dejará corregirlo a mano.
//   • Analizar el track entero (ya hecho en loadAudioBuffer), no los primeros 60s.
//
// Pipeline:  PCM → onset strength envelope (spectral flux multibanda) → tempo (autocorrelación
//            ponderada log-normal) → DP Ellis → posiciones de beat → downbeat → BeatGrid.

extension TrackAnalyzer {

    /// Frecuencia de frames del envelope de onset. windowSize 1024 / hop 256 sobre audio a la
    /// sampleRate del archivo (típico 44100) → ~172 Hz. Resolución temporal suficiente para beats.
    private static var onsetWindow: Int { 1024 }
    private static var onsetHop: Int { 256 }

    // MARK: API

    /// Calcula la rejilla de beats + downbeat de un buffer ya cargado (track entero).
    /// Devuelve `nil` si el audio es demasiado corto o no se detecta ritmo fiable.
    func detectBeatGrid(buffer: AVAudioPCMBuffer, sampleRate: Double) -> BeatGrid? {
        guard let envelope = onsetEnvelope(buffer: buffer), envelope.count > 16 else { return nil }
        let frameRate = sampleRate / Double(Self.onsetHop)   // frames de onset por segundo

        // 1) Tempo global: período de beat en frames de onset.
        guard let (beatPeriodFrames, confidence) = estimateBeatPeriod(envelope: envelope, frameRate: frameRate)
        else { return nil }
        let bpmRaw = 60.0 * frameRate / beatPeriodFrames
        let bpm = Self.foldBPM(bpmRaw)
        // El plegado a [90,180) puede cambiar el período → recalcular el período usado por el DP
        // a partir del BPM plegado, para que la rejilla quede en la octava de tempo correcta.
        let beatPeriodFolded = 60.0 * frameRate / bpm

        // 2) Posiciones de beat por Dynamic Programming (Ellis 2007).
        let beatFrames = Self.trackBeats(onsetEnvelope: envelope,
                                         beatPeriod: Int(beatPeriodFolded.rounded()))
        guard beatFrames.count >= 4 else { return nil }
        let beats = beatFrames.map { Double($0) / frameRate }   // → segundos (tiempo de archivo)

        // 3) Tempo variable: ¿los intervalos entre beats se desvían > 1.5% de la mediana?
        let isVariable = Self.isVariableTempo(beats: beats)

        // 4) Downbeat: cuál de las 4 fases del compás acumula más energía sub-bass.
        let downbeatIndex = detectDownbeat(buffer: buffer, sampleRate: sampleRate, beats: beats)

        return BeatGrid(beats: beats,
                        downbeatIndex: downbeatIndex,
                        beatsPerBar: 4,
                        bpm: (bpm * 10).rounded() / 10,
                        confidence: confidence,
                        isVariableTempo: isVariable)
    }

    // MARK: 1 · Onset strength envelope (spectral flux multibanda)

    /// Envelope de onset por spectral flux: diferencia positiva de la magnitud del espectro entre
    /// frames sucesivos, sumada en bandas. Más robusto que la energía cruda (que el detector viejo
    /// usaba) en música acústica/salsa donde el ataque del kick no domina la energía total.
    private func onsetEnvelope(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let n = Self.onsetWindow
        let hop = Self.onsetHop
        guard frameCount > n else { return nil }

        // Mezclar todos los canales a mono. Antes solo se usaba el canal 0 → en estéreo se perdían
        // onsets del canal derecho (p.ej. un kick paneado) (hallazgo Verifier Fugu). Promediamos.
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            // Copia directa del canal único (sin vDSP, un memcpy de floats — sin supuestos de
            // alineamiento de ningún tipo).
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: channels[0], count: frameCount)
            }
        } else {
            for c in 0..<channelCount {
                vDSP_vadd(mono, 1, channels[c], 1, &mono, 1, vDSP_Length(frameCount))
            }
            var scale = 1.0 / Float(channelCount)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frameCount))
        }

        let log2n = vDSP_Length(log2(Double(n)))
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fft) }

        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let halfN = n / 2
        var prevMag = [Float](repeating: 0, count: halfN)
        var envelope: [Float] = []
        envelope.reserveCapacity(frameCount / hop + 1)

        var windowed = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        var mag = [Float](repeating: 0, count: halfN)

        var pos = 0
        while pos + n <= frameCount {
            mono.withUnsafeBufferPointer { mp in
                vDSP_vmul(mp.baseAddress! + pos, 1, hann, 1, &windowed, 1, vDSP_Length(n))
            }

            // FFT in-place (zip). real = señal, imag = 0.
            real = windowed
            for i in 0..<n { imag[i] = 0 }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mag.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(halfN))
                    }
                }
            }

            // Spectral flux: suma de diferencias positivas mag - prevMag.
            var flux: Float = 0
            for k in 0..<halfN {
                let d = mag[k] - prevMag[k]
                if d > 0 { flux += d }
            }
            envelope.append(flux)
            prevMag = mag
            pos += hop
        }

        // Normalizar a media móvil (restar baseline) y rectificar → realza picos de beat.
        return Self.normalizeEnvelope(envelope)
    }

    /// Resta una media móvil local del envelope y rectifica a positivo. Quita la deriva lenta de
    /// energía (subidas/bajadas de sección) y deja los transientes, que son los beats.
    private static func normalizeEnvelope(_ env: [Float]) -> [Float] {
        guard !env.isEmpty else { return env }
        let w = 16   // ventana de media móvil (~0.1s)
        var out = [Float](repeating: 0, count: env.count)
        var runningSum: Float = 0
        for i in 0..<env.count {
            runningSum += env[i]
            if i >= w { runningSum -= env[i - w] }
            let mean = runningSum / Float(min(i + 1, w))
            out[i] = max(0, env[i] - mean)
        }
        // Normalizar a máximo 1 para que el score del DP sea comparable entre tracks.
        var maxv: Float = 0
        vDSP_maxv(out, 1, &maxv, vDSP_Length(out.count))
        if maxv > 0 { vDSP_vsdiv(out, 1, &maxv, &out, 1, vDSP_Length(out.count)) }
        return out
    }

    // MARK: 2 · Tempo (autocorrelación ponderada)

    /// Estima el período de beat (en frames de onset) por autocorrelación del envelope, con un
    /// peso log-normal centrado en 120 BPM para penalizar errores de octava (x2/÷2).
    /// Devuelve (período, confianza 0…1).
    private func estimateBeatPeriod(envelope: [Float], frameRate: Double) -> (Double, Double)? {
        let count = envelope.count
        guard count > 8 else { return nil }

        // Rango de lag plausible: 50–210 BPM.
        let minLag = max(1, Int((60.0 * frameRate) / 210.0))
        let maxLag = min(count - 1, Int((60.0 * frameRate) / 50.0))
        guard minLag < maxLag else { return nil }

        // Autocorrelación calculada lag-a-lag con vDSP_dotpr en vez de vDSP_conv. Evita por
        // completo las reglas de longitud de la convolución "full" (2N-1 muestras) que causaban
        // riesgo de buffer overflow (insistido por el Verifier Fugu). Para cada lag L,
        // autocorr[L] = Σ env[n]·env[n+L]. Solo computamos lags [0, maxLag] → barato y sin riesgo
        // de escribir fuera de límites: `autocorr` se indexa exactamente en [0, maxLag].
        var autocorr = [Float](repeating: 0, count: maxLag + 1)
        envelope.withUnsafeBufferPointer { env in
            let base = env.baseAddress!
            for lag in 0...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(count - lag))
                autocorr[lag] = dot
            }
        }

        // Peso log-normal centrado en 120 BPM (σ = 0.5 octavas).
        let prefLag = (60.0 * frameRate) / 120.0
        let sigma = 0.5

        var bestLag = minLag
        var bestScore: Float = -.infinity
        var rawPeakAtBest: Float = 0
        for lag in minLag...maxLag {
            let octave = log2(Double(lag) / prefLag)
            let weight = exp(-0.5 * (octave / sigma) * (octave / sigma))
            let score = autocorr[lag] * Float(weight)
            if score > bestScore {
                bestScore = score
                bestLag = lag
                rawPeakAtBest = autocorr[lag]
            }
        }

        // Refinamiento parabólico sub-frame alrededor del pico (igual que el detector viejo).
        var refined = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let y0 = Double(autocorr[bestLag - 1])
            let y1 = Double(autocorr[bestLag])
            let y2 = Double(autocorr[bestLag + 1])
            let denom = y0 - 2 * y1 + y2
            if abs(denom) > 1e-9 {
                let offset = 0.5 * (y0 - y2) / denom
                if offset.isFinite && abs(offset) <= 1 { refined += offset }
            }
        }

        // Confianza: pico normalizado por la energía total del envelope (autocorr[0]).
        let conf = autocorr[0] > 0 ? Double(min(1, max(0, rawPeakAtBest / autocorr[0]))) : 0
        return (refined, conf)
    }

    // MARK: 3 · Beat tracking por Dynamic Programming (Ellis 2007)

    /// Encuentra la secuencia global de beats que maximiza onset_strength manteniendo el intervalo
    /// cerca del `beatPeriod` esperado. Port directo del algoritmo de Dan Ellis (2007), el mismo
    /// que usan librosa y Mixxx (modo variable). Penalización log-temporal del desvío de intervalo.
    /// Devuelve índices de frame (en coordenadas del envelope) de cada beat.
    static func trackBeats(onsetEnvelope env: [Float], beatPeriod: Int, tightness: Float = 100.0) -> [Int] {
        let count = env.count
        guard count > 1, beatPeriod > 0 else { return [] }

        var score = [Float](repeating: -.infinity, count: count)
        var backptr = [Int](repeating: -1, count: count)
        score[0] = env[0]

        let minLag = max(1, Int(Double(beatPeriod) * 0.5))
        let maxLag = max(minLag + 1, Int(Double(beatPeriod) * 2.0))

        for current in 1..<count {
            let searchStart = max(0, current - maxLag)
            let searchEnd = current - minLag
            var best: Float = -.infinity
            var bestPrev = -1
            if searchStart <= searchEnd {
                for prev in searchStart...searchEnd {
                    let interval = current - prev
                    let ratio = Float(interval) / Float(beatPeriod)
                    let logRatio = log2(ratio)
                    let penalty = -tightness * logRatio * logRatio
                    let cand = penalty + score[prev]
                    if cand > best { best = cand; bestPrev = prev }
                }
            }
            if best == -.infinity || best <= 0 {
                score[current] = env[current]
                backptr[current] = -1
            } else {
                score[current] = env[current] + best
                backptr[current] = bestPrev
            }
        }

        // Anclar el backtrack en el mejor score de la ventana final.
        let finalCut = max(0, count - Int(Double(beatPeriod) * 1.5))
        var anchor = count - 1
        var maxEnd: Float = -.infinity
        for i in finalCut..<count where score[i] > maxEnd { maxEnd = score[i]; anchor = i }

        var beats: [Int] = []
        var p = anchor
        while p >= 0 {
            beats.append(p)
            p = backptr[p]
        }
        return beats.reversed()
    }

    /// ¿El tempo varía > 1.5% entre intervalos de beat consecutivos respecto a la mediana?
    static func isVariableTempo(beats: [Double]) -> Bool {
        guard beats.count > 4 else { return false }
        var intervals: [Double] = []
        for i in 1..<beats.count { intervals.append(beats[i] - beats[i - 1]) }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return false }
        let off = intervals.filter { abs($0 - median) / median > 0.015 }.count
        return Double(off) / Double(intervals.count) > 0.10   // >10% de beats fuera de tolerancia
    }

    // MARK: 4 · Downbeat (heurística sub-bass)

    /// Decide cuál de las 4 posiciones del compás 4/4 es el "1", midiendo qué fase acumula más
    /// energía sub-bass (<150 Hz, el kick/bombo que ancla el downbeat). Devuelve el índice dentro
    /// de `beats` del primer downbeat. Heurística — falla en salsa/funk con "1" desplazado; en
    /// Sesión 2 la UI permitirá corregirlo. `nil` si no hay datos suficientes.
    private func detectDownbeat(buffer: AVAudioPCMBuffer, sampleRate: Double, beats: [Double]) -> Int? {
        guard beats.count >= 8, let ch0 = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        // Copiar el canal 0 a un array Swift propio: evita pasar punteros crudos del buffer a vDSP
        // dentro del bucle (más seguro y sin supuestos de alineamiento — hallazgo Verifier Fugu).
        // Para sub-bass el canal 0 basta; el "1" lo marca el kick, presente en ambos canales.
        let samples = [Float](UnsafeBufferPointer(start: ch0, count: frameCount))

        // Energía sub-bass por beat: ventana corta tras cada beat, filtrada paso-bajo simple
        // (media móvil sobre la señal = atenúa agudos) y sumada al cuadrado.
        func subBassEnergy(at t: Double) -> Float {
            let start = Int(t * sampleRate)
            let win = Int(0.08 * sampleRate)   // 80 ms tras el beat
            guard start >= 0, start + win < frameCount else { return 0 }
            // Filtro paso-bajo barato: promedio en bloques de ~M muestras ≈ corta agudos.
            let m = max(1, Int(sampleRate / 300.0))   // corte ~300 Hz
            var energy: Float = 0
            var i = start
            while i + m < start + win {
                var blockMean: Float = 0
                samples.withUnsafeBufferPointer { sp in
                    vDSP_meanv(sp.baseAddress! + i, 1, &blockMean, vDSP_Length(m))
                }
                energy += blockMean * blockMean
                i += m
            }
            return energy
        }

        let energies = beats.map { subBassEnergy(at: $0) }

        // Probar las 4 fases del compás: phase p agrupa los beats p, p+4, p+8... El primer
        // downbeat de cada fase es exactamente el beat de índice `p` (0..3), así que la fase
        // ganadora ES el índice del primer downbeat dentro de `beats` (consistente con la
        // semántica de BeatGrid.downbeatIndex y firstDownbeat). Guardamos el promedio de cada
        // fase para medir cuán marcada está la ganadora frente a las demás.
        var phaseAvg = [Float](repeating: 0, count: 4)
        for phase in 0..<4 {
            var sum: Float = 0
            var n = 0
            var i = phase
            while i < energies.count { sum += energies[i]; n += 1; i += 4 }
            phaseAvg[phase] = n > 0 ? sum / Float(n) : 0
        }
        let bestPhase = (0..<4).max(by: { phaseAvg[$0] < phaseAvg[$1] }) ?? 0
        let best = phaseAvg[bestPhase]
        let others = (0..<4).filter { $0 != bestPhase }.map { phaseAvg[$0] }
        let secondBest = others.max() ?? 0
        // Guard de confianza: si la fase ganadora no destaca ≥15% sobre la siguiente, el downbeat
        // es ambiguo (típico salsa/funk donde el "1" no lleva el kick más fuerte). Devolvemos nil
        // en vez de un falso "1" → la UI de Sesión 2 dejará fijarlo a mano. Mejor sin downbeat que
        // con uno engañoso que desalinee las frases del auto-mix.
        guard best > 0, best >= secondBest * 1.15 else { return nil }
        return bestPhase   // índice del primer downbeat dentro de `beats` (0..3)
    }

    // MARK: Util

    /// Pliega un BPM a la octava de DJ [90,180) doblando/halvando. (Misma lógica que el detector
    /// viejo; duplicada aquí para que el motor de beatgrid sea autónomo.)
    static func foldBPM(_ bpm: Double) -> Double {
        guard bpm > 0 else { return 120 }
        var b = bpm
        while b >= 180 { b /= 2 }
        while b < 90 { b *= 2 }
        return b
    }
}
