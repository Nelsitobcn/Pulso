import AVFoundation
import Accelerate

/// Analiza una pista de audio para extraer BPM, key, duración y waveform
actor TrackAnalyzer {

    static let shared = TrackAnalyzer()

    // MARK: - API principal

    func analyze(track: inout Track) async {
        let url = track.url
        guard let (buffer, format) = await loadAudioBuffer(url: url) else { return }

        // Ejecutar en secuencia para evitar captura mutable de inout en concurrente
        track.duration = await getDuration(url: url)
        track.bpm = detectBPM(buffer: buffer, sampleRate: format.sampleRate)
        track.waveformData = buildWaveform(buffer: buffer, targetSamples: 512)
        // key detection: fase 2 con Core ML
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

        // 1. Calcular energía en ventanas de 512 samples
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

        // 2. Diferencia de energía (onset strength)
        var onsetStrength: [Float] = [0]
        for j in 1..<energyEnvelope.count {
            let diff = max(0, energyEnvelope[j] - energyEnvelope[j - 1])
            onsetStrength.append(diff)
        }

        // 3. Autocorrelación para encontrar período dominante
        let acSize = onsetStrength.count
        var autocorr = [Float](repeating: 0, count: acSize)
        vDSP_conv(onsetStrength, 1, onsetStrength, 1, &autocorr, 1, vDSP_Length(acSize), vDSP_Length(acSize))

        // 4. Buscar el pico en rango de BPM 60–180
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

        let bpm = 60.0 / (Double(bestLag) * hopDuration)
        // Redondear al múltiplo de 0.5 más cercano
        return (bpm * 2).rounded() / 2
    }

    // MARK: - Waveform (downsampling para dibujar)

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
            // Limitamos a los primeros 60 segundos para el análisis rápido
            let maxFrames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(format.sampleRate * 60)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else { return nil }
            try file.read(into: buffer, frameCount: maxFrames)
            return (buffer, format)
        } catch {
            print("[TrackAnalyzer] Error cargando \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
