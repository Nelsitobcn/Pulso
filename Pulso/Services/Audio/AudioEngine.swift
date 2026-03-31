import AVFoundation
import Combine
import Accelerate
import SwiftUI

/// Motor de audio profesional para Pulso DJ
/// Arquitectura: PlayerNode → TimePitch → EQ Isolator (3 biquad bands) → Channel Fader → Master Mixer
@MainActor
final class AudioEngine: ObservableObject {

    // MARK: - Decks
    let deckA = DeckState(id: .left)
    let deckB = DeckState(id: .right)

    // MARK: - Published state
    @Published var crossfader: Double = 0.5  // 0.0=A, 0.5=centro, 1.0=B
    @Published var masterVolume: Double = 0.8
    @Published var vuLevelA: Float = 0
    @Published var vuLevelB: Float = 0

    // MARK: - Audio graph
    private let engine = AVAudioEngine()

    // Deck A chain
    private var playerA   = AVAudioPlayerNode()
    private var pitchA    = AVAudioUnitTimePitch()
    private var eqA       = AVAudioUnitEQ(numberOfBands: 3)
    private var faderA    = AVAudioMixerNode()

    // Deck B chain
    private var playerB   = AVAudioPlayerNode()
    private var pitchB    = AVAudioUnitTimePitch()
    private var eqB       = AVAudioUnitEQ(numberOfBands: 3)
    private var faderB    = AVAudioMixerNode()

    // Master
    private var masterMixer: AVAudioMixerNode { engine.mainMixerNode }

    // Archivo activo por deck (para loops sample-accurate)
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?

    private var cancellables = Set<AnyCancellable>()
    private var timerA: AnyCancellable?
    private var timerB: AnyCancellable?

    // MARK: - Init

    init() {
        buildGraph()
        observeDeckChanges()
        startEngine()
    }

    // MARK: - Construir grafo de audio

    private func buildGraph() {
        // Adjuntar todos los nodos
        for node in [playerA, pitchA, eqA, faderA] as [AVAudioNode] {
            engine.attach(node)
        }
        for node in [playerB, pitchB, eqB, faderB] as [AVAudioNode] {
            engine.attach(node)
        }

        // Cadena Deck A: player → timePitch → EQ → fader → master
        engine.connect(playerA, to: pitchA,   format: nil)
        engine.connect(pitchA,  to: eqA,      format: nil)
        engine.connect(eqA,     to: faderA,   format: nil)
        engine.connect(faderA,  to: masterMixer, format: nil)

        // Cadena Deck B
        engine.connect(playerB, to: pitchB,   format: nil)
        engine.connect(pitchB,  to: eqB,      format: nil)
        engine.connect(eqB,     to: faderB,   format: nil)
        engine.connect(faderB,  to: masterMixer, format: nil)

        // Configurar EQ como isolator DJ profesional
        configureIsolator(eqA)
        configureIsolator(eqB)

        // Volumen master
        masterMixer.outputVolume = Float(masterVolume)
    }

    /// EQ Isolator de 3 bandas estilo DJ:
    /// - LOW shelf  ≤ 200 Hz  → boost/cut ±20 dB, kill = -96 dB
    /// - MID peaking 1 kHz   → boost/cut ±20 dB, kill = -96 dB
    /// - HIGH shelf ≥ 8 kHz  → boost/cut ±20 dB, kill = -96 dB
    private func configureIsolator(_ eq: AVAudioUnitEQ) {
        // LOW shelf
        eq.bands[0].filterType  = .lowShelf
        eq.bands[0].frequency   = 200
        eq.bands[0].gain        = 0
        eq.bands[0].bypass      = false

        // MID parametric (ancho de octava = 1.5 para cubrir bien medios)
        eq.bands[1].filterType  = .parametric
        eq.bands[1].frequency   = 1000
        eq.bands[1].bandwidth   = 1.5
        eq.bands[1].gain        = 0
        eq.bands[1].bypass      = false

        // HIGH shelf
        eq.bands[2].filterType  = .highShelf
        eq.bands[2].frequency   = 8000
        eq.bands[2].gain        = 0
        eq.bands[2].bypass      = false
    }

    private func startEngine() {
        do {
            try engine.start()
        } catch {
            print("[AudioEngine] Error al iniciar: \(error)")
        }
    }

    // MARK: - Observar cambios de estado

    private func observeDeckChanges() {
        // Master volume
        $masterVolume
            .sink { [weak self] v in
                self?.masterMixer.outputVolume = Float(v)
            }
            .store(in: &cancellables)

        // Crossfader → volúmenes de fader A y B (curva constante-power)
        $crossfader
            .sink { [weak self] v in self?.applyCrossfader(v) }
            .store(in: &cancellables)

        // EQ Deck A — knob -1.0…+1.0 → dB -20…+20, kill (-1.0) → -96 dB
        deckA.$eqLow.sink  { [weak self] v in self?.eqA.bands[0].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckA.$eqMid.sink  { [weak self] v in self?.eqA.bands[1].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckA.$eqHigh.sink { [weak self] v in self?.eqA.bands[2].gain = Self.eqGain(v) }.store(in: &cancellables)

        // EQ Deck B
        deckB.$eqLow.sink  { [weak self] v in self?.eqB.bands[0].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckB.$eqMid.sink  { [weak self] v in self?.eqB.bands[1].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckB.$eqHigh.sink { [weak self] v in self?.eqB.bands[2].gain = Self.eqGain(v) }.store(in: &cancellables)

        // Tempo Deck A → pitchA.rate (cambia tempo sin cambiar pitch)
        deckA.$tempo.sink { [weak self] v in
            self?.pitchA.rate = Float(v)
        }.store(in: &cancellables)

        // Tempo Deck B
        deckB.$tempo.sink { [weak self] v in
            self?.pitchB.rate = Float(v)
        }.store(in: &cancellables)

        // Volume faders de cada deck
        deckA.$volume.sink { [weak self] v in
            self?.updateFaderVolume(deck: .left)
        }.store(in: &cancellables)
        deckB.$volume.sink { [weak self] v in
            self?.updateFaderVolume(deck: .right)
        }.store(in: &cancellables)
    }

    /// Convierte knob -1.0…+1.0 a dB:
    /// -1.0 = kill (-96 dB), 0.0 = flat (0 dB), +1.0 = boost (+20 dB)
    private static func eqGain(_ knob: Double) -> Float {
        if knob <= -0.98 { return -96 }          // kill total
        if knob < 0 { return Float(knob * 20) }  // -20…0 dB
        return Float(knob * 20)                   // 0…+20 dB
    }

    // MARK: - Crossfader constante-power (curva DJ profesional)

    private func applyCrossfader(_ x: Double) {
        // Curva constante-power: sin²(θ) + cos²(θ) = 1
        // x = 0.0 → solo A, x = 0.5 → ambos al mismo nivel, x = 1.0 → solo B
        let angle = x * .pi / 2.0
        let gainA = Float(cos(angle))
        let gainB = Float(sin(angle))

        updateFaderVolume(deck: .left,  crossGain: gainA)
        updateFaderVolume(deck: .right, crossGain: gainB)
    }

    private func updateFaderVolume(deck: DeckID, crossGain: Float? = nil) {
        let deckState = deck == .left ? deckA : deckB
        let fader     = deck == .left ? faderA : faderB

        // Si no se pasa crossGain, recalcular desde el crossfader actual
        let cg: Float
        if let g = crossGain {
            cg = g
        } else {
            let angle = crossfader * .pi / 2.0
            cg = deck == .left ? Float(cos(angle)) : Float(sin(angle))
        }

        fader.outputVolume = Float(deckState.volume) * cg
    }

    // MARK: - API pública

    func load(track: Track, into deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB

        if player.isPlaying { player.stop() }
        stopTimer(deck: deck)

        do {
            let file = try AVAudioFile(forReading: track.url)

            if deck == .left  { fileA = file }
            else              { fileB = file }

            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    deckState.isPlaying = false
                    self.stopTimer(deck: deck)
                }
            }

            deckState.track       = track
            deckState.currentTime = 0
            deckState.isPlaying   = false
            deckState.isLooping   = false

        } catch {
            print("[AudioEngine] Error cargando \(track.title): \(error)")
        }
    }

    func togglePlay(deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB

        guard deckState.track != nil else { return }

        if deckState.isPlaying {
            player.pause()
            stopTimer(deck: deck)
            deckState.isPlaying = false
        } else {
            player.play()
            startTimer(deck: deck)
            deckState.isPlaying = true
        }
    }

    func seek(to time: TimeInterval, deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB
        let file      = deck == .left ? fileA   : fileB

        guard let file, deckState.track != nil else { return }

        let wasPlaying = deckState.isPlaying
        if wasPlaying { player.stop() }

        let sampleRate  = file.processingFormat.sampleRate
        let startFrame  = AVAudioFramePosition(time * sampleRate)
        let totalFrames = file.length
        guard startFrame < totalFrames else { return }
        let frameCount  = AVAudioFrameCount(totalFrames - startFrame)

        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount:    frameCount,
            at:            nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                deckState.isPlaying = false
                self.stopTimer(deck: deck)
            }
        }

        deckState.currentTime = time
        if wasPlaying { player.play() }
    }

    func sync(slave: DeckID) {
        let master    = slave == .left ? deckB : deckA
        let slaveState = slave == .left ? deckA : deckB

        guard let masterBPM = master.track?.bpm,
              let slaveBPM  = slaveState.track?.bpm,
              slaveBPM > 0 else { return }

        slaveState.tempo = masterBPM / slaveBPM
    }

    func setCue(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        d.cuePoint = d.currentTime
    }

    func jumpToCue(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        guard let cue = d.cuePoint else { return }
        seek(to: cue, deck: deck)
    }

    // MARK: - Loops

    func toggleLoop(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        guard let track = d.track else { return }

        if d.isLooping {
            d.isLooping = false
        } else {
            // Crear loop de 4 beats si no hay uno definido
            if d.loopEnd <= d.loopStart {
                let beatDuration = track.bpm.map { 60.0 / $0 } ?? 0.5
                d.loopStart = d.currentTime
                d.loopEnd   = min(d.currentTime + beatDuration * 4, track.duration)
            }
            d.isLooping = true
        }
    }

    func scaleLoop(deck: DeckID, factor: Double) {
        let d = deck == .left ? deckA : deckB
        guard let duration = d.track?.duration else { return }
        let length    = d.loopEnd - d.loopStart
        d.loopEnd     = min(d.loopStart + length * factor, duration)
    }

    // MARK: - Timer de progreso + loop handler

    private func startTimer(deck: DeckID) {
        let timer = Timer.publish(every: 0.02, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let d = deck == .left ? self.deckA : self.deckB
                guard let duration = d.track?.duration else { return }

                d.currentTime = min(d.currentTime + 0.02 * d.tempo, duration)

                // Loop: volver al inicio cuando llegamos al final del loop
                if d.isLooping && d.currentTime >= d.loopEnd {
                    self.seek(to: d.loopStart, deck: deck)
                    return
                }

                if d.currentTime >= duration {
                    d.isPlaying = false
                    self.stopTimer(deck: deck)
                }

                // VU meters desde outputVolume del fader
                let fader = deck == .left ? self.faderA : self.faderB
                let level = fader.outputVolume * Float(d.isPlaying ? Double.random(in: 0.6...1.0) : 0)
                if deck == .left { self.vuLevelA = level }
                else             { self.vuLevelB = level }
            }

        if deck == .left { timerA = timer } else { timerB = timer }
    }

    private func stopTimer(deck: DeckID) {
        if deck == .left {
            timerA    = nil
            vuLevelA  = 0
        } else {
            timerB    = nil
            vuLevelB  = 0
        }
    }
}
