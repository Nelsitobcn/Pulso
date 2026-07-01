import AVFoundation
import Accelerate

/// Analiza una pista de audio para extraer BPM, key, duración y waveform
actor TrackAnalyzer {

    static let shared = TrackAnalyzer()

    // MARK: - API principal

    func analyze(track: inout Track) async {
        let url = track.url
        guard let (buffer, format) = await loadAudioBuffer(url: url) else { return }

        track.duration = await getDuration(url: url)
        track.key = detectKey(buffer: buffer, sampleRate: format.sampleRate)
        // 3000 muestras (antes 512): da nitidez al hacer zoom en la waveform hasta ~16×
        // para colocar el cursor en el drop con precisión. El coste extra de RAM/JSON por
        // pista es despreciable (~12 KB de floats).
        track.waveformData = buildWaveform(buffer: buffer, targetSamples: 3000)

        // Beatgrid + downbeat (Sesión 1, jul-2026). Sustituye al antiguo `detectBPM` de un solo
        // número: ahora calculamos el envelope de onset una vez y de ahí salen TANTO el BPM como
        // las posiciones de cada beat (DP tipo Ellis) y el downbeat. El SYNC usará la rejilla.
        let grid = detectBeatGrid(buffer: buffer, sampleRate: format.sampleRate)
        track.beatGrid = grid
        // `bpm` se mantiene como campo propio (UI, sugerencias, SYNC legacy). Sale del grid si lo hay.
        track.bpm = grid?.bpm ?? detectBPM(buffer: buffer, sampleRate: format.sampleRate)
    }

    // MARK: - Duración

    private func getDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.duration))?.seconds ?? 0
    }

    // MARK: - BPM (onset detection + autocorrelación)

    private func detectBPM(buffer: AVAudioPCMBuffer, sampleRate: Double) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 120.0 }
        let frameCount = Int(buffer.frameLength)

        let windowSize = 512
        let hopSize = 256
        var energyEnvelope: [Float] = []

        var i = 0
        while i + windowSize < frameCount {
            let slice = Array(UnsafeBufferPointer(start: channelData + i, count: windowSize))
            var energy: Float = 0
            vDSP_svesq(slice, 1, &energy, vDSP_Length(windowSize))
            energyEnvelope.append(energy)
            i += hopSize
        }

        var onsetStrength: [Float] = [0]
        for j in 1..<energyEnvelope.count {
            let diff = max(0, energyEnvelope[j] - energyEnvelope[j - 1])
            onsetStrength.append(diff)
        }

        let acSize = onsetStrength.count
        var autocorr = [Float](repeating: 0, count: acSize)
        vDSP_conv(onsetStrength, 1, onsetStrength, 1, &autocorr, 1, vDSP_Length(acSize), vDSP_Length(acSize))

        let hopDuration = Double(hopSize) / sampleRate
        let minLag = Int(60.0 / (180.0 * hopDuration))
        let maxLag = Int(60.0 / (60.0 * hopDuration))

        var bestLag = minLag
        var bestValue: Float = 0
        for lag in minLag...min(maxLag, acSize - 1) {
            if autocorr[lag] > bestValue {
                bestValue = autocorr[lag]
                bestLag = lag
            }
        }

        // Interpolación parabólica alrededor del pico para precisión sub-muestra.
        // El lag entero solo da resolución ~±1.5 BPM a tempos altos; con los 3 puntos
        // alrededor del máximo refinamos el lag real (decimal), eliminando el error que
        // hacía que 128 BPM se detectara como 127.5 y causaba drift en el SYNC.
        var refinedLag = Double(bestLag)
        if bestLag > minLag && bestLag < min(maxLag, acSize - 1) {
            let y0 = Double(autocorr[bestLag - 1])
            let y1 = Double(autocorr[bestLag])
            let y2 = Double(autocorr[bestLag + 1])
            let denom = y0 - 2 * y1 + y2
            if abs(denom) > 1e-9 {
                let offset = 0.5 * (y0 - y2) / denom   // en [-0.5, 0.5]
                if offset.isFinite && abs(offset) <= 1 { refinedLag += offset }
            }
        }

        let bpm = 60.0 / (refinedLag * hopDuration)
        // Plegar a la octava de tempo canónica de DJ [90, 180). La autocorrelación se engancha
        // con frecuencia al medio-beat o doble-beat (error x2 / ÷2 clásico): "Lloraras" salía
        // 181 en vez de ~90. Casi toda la música mezclable vive en [90,180); fuera de ahí se
        // dobla o se halva hasta caer dentro. Esto da un BPM estable para el SYNC.
        let folded = Self.foldToDJRange(bpm)
        return (folded * 10).rounded() / 10
    }

    /// Lleva un BPM a la octava [90, 180) doblando/halvando. Mantiene la clase de tempo
    /// correcta y elimina los errores x2/÷2 de la autocorrelación.
    private static func foldToDJRange(_ bpm: Double) -> Double {
        guard bpm > 0 else { return 120 }
        var b = bpm
        while b >= 180 { b /= 2 }
        while b < 90 { b *= 2 }
        return b
    }

    // MARK: - Key Detection (Krumhansl-Schmuckler)

    private func detectKey(buffer: AVAudioPCMBuffer, sampleRate: Double) -> MusicalKey? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)

        // Calcular chroma vector (12 clases de pitch) via FFT por ventanas
        let windowSize = 4096
        let hopSize = 2048
        var chromaAccum = [Double](repeating: 0, count: 12)

        var windowStart = 0
        var windowCount = 0
        let log2n = vDSP_Length(log2(Double(windowSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        while windowStart + windowSize <= frameCount {
            let slice = Array(UnsafeBufferPointer(start: channelData + windowStart, count: windowSize))

            // Aplicar ventana de Hann
            var windowed = [Float](repeating: 0, count: windowSize)
            var hannWindow = [Float](repeating: 0, count: windowSize)
            vDSP_hann_window(&hannWindow, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
            vDSP_vmul(slice, 1, hannWindow, 1, &windowed, 1, vDSP_Length(windowSize))

            // FFT
            var real = windowed
            var imag = [Float](repeating: 0, count: windowSize)
            var magnitudes = [Float](repeating: 0, count: windowSize / 2)

            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    magnitudes.withUnsafeMutableBufferPointer { magBuf in
                        vDSP_zvabs(&splitComplex, 1, magBuf.baseAddress!, 1, vDSP_Length(windowSize / 2))
                    }
                }
            }

            // Mapear frecuencias a clases de pitch (chroma)
            for bin in 1..<(windowSize / 2) {
                let freq = Double(bin) * sampleRate / Double(windowSize)
                guard freq >= 27.5 && freq <= 4186.0 else { continue }
                // Convertir frecuencia a nota MIDI
                let midi = 12.0 * log2(freq / 440.0) + 69.0
                let pitchClass = Int(midi.rounded()) % 12
                if pitchClass >= 0 {
                    chromaAccum[pitchClass] += Double(magnitudes[bin])
                }
            }

            windowStart += hopSize
            windowCount += 1
        }

        guard windowCount > 0 else { return nil }

        // Normalizar chroma
        let maxChroma = chromaAccum.max() ?? 1.0
        if maxChroma > 0 {
            chromaAccum = chromaAccum.map { $0 / maxChroma }
        }

        // Perfiles de tonalidad Krumhansl-Schmuckler
        let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

        // Correlación de Pearson para cada tonalidad
        var bestCorrelation = -Double.infinity
        var bestKey: MusicalKey? = nil

        for root in 0..<12 {
            let majorCorr = pearsonCorrelation(chromaAccum, rotated(majorProfile, by: root))
            let minorCorr = pearsonCorrelation(chromaAccum, rotated(minorProfile, by: root))

            if majorCorr > bestCorrelation {
                bestCorrelation = majorCorr
                bestKey = camelotKey(root: root, isMajor: true)
            }
            if minorCorr > bestCorrelation {
                bestCorrelation = minorCorr
                bestKey = camelotKey(root: root, isMajor: false)
            }
        }

        return bestKey
    }

    private func rotated(_ array: [Double], by n: Int) -> [Double] {
        let count = array.count
        let shift = n % count
        return Array(array[shift...] + array[..<shift])
    }

    private func pearsonCorrelation(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        let num = zip(x, y).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denX = sqrt(x.reduce(0.0) { $0 + pow($1 - meanX, 2) })
        let denY = sqrt(y.reduce(0.0) { $0 + pow($1 - meanY, 2) })
        guard denX > 0 && denY > 0 else { return 0 }
        return num / (denX * denY)
    }

    /// Convierte root (0=C, 1=C#, ..., 11=B) + mayor/menor a notación Camelot
    private func camelotKey(root: Int, isMajor: Bool) -> MusicalKey {
        // Orden Camelot: las mayores son "B", las menores son "A"
        // Camelot 1B = A♭maj, 2B = E♭maj, 3B = B♭maj, 4B = Fmaj, 5B = Cmaj, 6B = Gmaj,
        //              7B = Dmaj, 8B = Amaj, 9B = Emaj, 10B = Bmaj, 11B = F#maj, 12B = D♭maj
        // Camelot 1A = A♭min, 2A = E♭min, etc.
        let majorCamelot = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10] // C=5B, C#=12B, D=7B...
        let minorCamelot = [2, 9, 4, 11, 6, 1, 8, 3, 10, 5, 12, 7] // C=2A, C#=9A, D=4A...

        let number = isMajor ? majorCamelot[root] : minorCamelot[root]
        let letter = isMajor ? "B" : "A"
        let raw = "\(number)\(letter)"
        return MusicalKey(rawValue: raw) ?? .c5B
    }

    // MARK: - Waveform

    private func buildWaveform(buffer: AVAudioPCMBuffer, targetSamples: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let frameCount = Int(buffer.frameLength)
        let samplesPerBucket = max(1, frameCount / targetSamples)
        var waveform: [Float] = []

        for i in 0..<targetSamples {
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, frameCount)
            let slice = Array(UnsafeBufferPointer(start: channelData + start, count: end - start))
            var peak: Float = 0
            vDSP_maxmgv(slice, 1, &peak, vDSP_Length(slice.count))
            waveform.append(peak)
        }
        return waveform
    }

    // MARK: - Carga de buffer

    private func loadAudioBuffer(url: URL) async -> (AVAudioPCMBuffer, AVAudioFormat)? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            // Analizar el TRACK ENTERO, no solo los primeros 60s. El shortcut de 60s fallaba en
            // intros largas/ambient y daba BPM de intro ≠ BPM del drop (hallazgo concilio+NBLM
            // jul-2026). En M3 Ultra el análisis completo es de milisegundos. Cap de seguridad a
            // 12 min para que un archivo gigante no agote RAM (a 44.1kHz mono ≈ 127 MB de floats).
            let maxSeconds = 12.0 * 60.0
            let maxFrames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(format.sampleRate * maxSeconds)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else { return nil }
            try file.read(into: buffer, frameCount: maxFrames)
            return (buffer, format)
        } catch {
            print("[TrackAnalyzer] Error cargando \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
