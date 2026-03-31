import AVFoundation
import Combine
import Accelerate
import SwiftUI

/// Motor de audio profesional para Pulso DJ
/// Arquitectura: PlayerNode → TimePitch → EQ Isolator (3 bandas) → Channel Fader → Master Mixer
@MainActor
final class AudioEngine: ObservableObject {

    // MARK: - Decks
    let deckA = DeckState(id: .left)
    let deckB = DeckState(id: .right)

    // MARK: - Published state
    @Published var crossfader: Double = 0.5
    @Published var masterVolume: Double = 0.8
    @Published var vuLevelA: Float = 0
    @Published var vuLevelB: Float = 0

    // MARK: - Audio graph
    private let engine = AVAudioEngine()

    private var playerA   = AVAudioPlayerNode()
    private var pitchA    = AVAudioUnitTimePitch()
    private var eqA       = AVAudioUnitEQ(numberOfBands: 3)
    private var faderA    = AVAudioMixerNode()

    private var playerB   = AVAudioPlayerNode()
    private var pitchB    = AVAudioUnitTimePitch()
    private var eqB       = AVAudioUnitEQ(numberOfBands: 3)
    private var faderB    = AVAudioMixerNode()

    private var masterMixer: AVAudioMixerNode { engine.mainMixerNode }

    // Archivo activo por deck
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?

    // Frame en el que se pausó (para reanudar desde ahí)
    private var pauseFrameA: AVAudioFramePosition = 0
    private var pauseFrameB: AVAudioFramePosition = 0

    // Frame en el que empezó el segmento actual (para calcular posición)
    private var segmentStartFrameA: AVAudioFramePosition = 0
    private var segmentStartFrameB: AVAudioFramePosition = 0

    private var cancellables = Set<AnyCancellable>()
    private var timerA: AnyCancellable?
    private var timerB: AnyCancellable?

    // MARK: - Init

    init() {
        buildGraph()
        observeDeckChanges()
        startEngine()
    }

    // MARK: - Grafo de audio

    private func buildGraph() {
        for node in [playerA, pitchA, eqA, faderA] as [AVAudioNode] { engine.attach(node) }
        for node in [playerB, pitchB, eqB, faderB] as [AVAudioNode] { engine.attach(node) }

        engine.connect(playerA, to: pitchA,      format: nil)
        engine.connect(pitchA,  to: eqA,         format: nil)
        engine.connect(eqA,     to: faderA,      format: nil)
        engine.connect(faderA,  to: masterMixer, format: nil)

        engine.connect(playerB, to: pitchB,      format: nil)
        engine.connect(pitchB,  to: eqB,         format: nil)
        engine.connect(eqB,     to: faderB,      format: nil)
        engine.connect(faderB,  to: masterMixer, format: nil)

        pitchA.pitch = 0
        pitchB.pitch = 0

        configureIsolator(eqA)
        configureIsolator(eqB)

        masterMixer.outputVolume = Float(masterVolume)
        faderA.outputVolume = 1.0
        faderB.outputVolume = 1.0
    }

    /// EQ Isolator DJ 3 bandas: LOW shelf 200Hz / MID parametric 1kHz / HIGH shelf 8kHz
    private func configureIsolator(_ eq: AVAudioUnitEQ) {
        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency  = 200
        eq.bands[0].gain       = 0
        eq.bands[0].bypass     = false

        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency  = 1000
        eq.bands[1].bandwidth  = 1.5
        eq.bands[1].gain       = 0
        eq.bands[1].bypass     = false

        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency  = 8000
        eq.bands[2].gain       = 0
        eq.bands[2].bypass     = false
    }

    private func startEngine() {
        do {
            try engine.start()
            print("[AudioEngine] Motor iniciado OK")
        } catch {
            print("[AudioEngine] Error al iniciar: \(error)")
        }
    }

    // MARK: - Observadores de estado

    private func observeDeckChanges() {
        $masterVolume
            .sink { [weak self] v in self?.masterMixer.outputVolume = Float(v) }
            .store(in: &cancellables)

        $crossfader
            .sink { [weak self] v in self?.applyCrossfader(v) }
            .store(in: &cancellables)

        // EQ Deck A
        deckA.$eqLow.sink  { [weak self] v in self?.eqA.bands[0].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckA.$eqMid.sink  { [weak self] v in self?.eqA.bands[1].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckA.$eqHigh.sink { [weak self] v in self?.eqA.bands[2].gain = Self.eqGain(v) }.store(in: &cancellables)

        // EQ Deck B
        deckB.$eqLow.sink  { [weak self] v in self?.eqB.bands[0].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckB.$eqMid.sink  { [weak self] v in self?.eqB.bands[1].gain = Self.eqGain(v) }.store(in: &cancellables)
        deckB.$eqHigh.sink { [weak self] v in self?.eqB.bands[2].gain = Self.eqGain(v) }.store(in: &cancellables)

        // Tempo → TimePitch.rate
        deckA.$tempo.sink { [weak self] v in self?.pitchA.rate = Float(v) }.store(in: &cancellables)
        deckB.$tempo.sink { [weak self] v in self?.pitchB.rate = Float(v) }.store(in: &cancellables)

        // Volume fader de cada deck
        deckA.$volume.sink { [weak self] v in self?.updateFaderVolume(deck: .left)  }.store(in: &cancellables)
        deckB.$volume.sink { [weak self] v in self?.updateFaderVolume(deck: .right) }.store(in: &cancellables)
    }

    /// knob -1.0…+1.0 → dB: kill (-96) / flat (0) / boost (+20)
    private static func eqGain(_ knob: Double) -> Float {
        if knob <= -0.98 { return -96 }
        return Float(knob * 20)
    }

    // MARK: - Crossfader constante-power

    private func applyCrossfader(_ x: Double) {
        let angle = x * .pi / 2.0
        updateFaderVolume(deck: .left,  crossGain: Float(cos(angle)))
        updateFaderVolume(deck: .right, crossGain: Float(sin(angle)))
    }

    private func updateFaderVolume(deck: DeckID, crossGain: Float? = nil) {
        let deckState = deck == .left ? deckA : deckB
        let fader     = deck == .left ? faderA : faderB

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

        // Detener reproducción anterior
        if player.isPlaying { player.stop() }
        stopTimer(deck: deck)

        // Resetear posición de pausa
        if deck == .left { pauseFrameA = 0; segmentStartFrameA = 0 }
        else             { pauseFrameB = 0; segmentStartFrameB = 0 }

        do {
            let file = try AVAudioFile(forReading: track.url)
            if deck == .left { fileA = file } else { fileB = file }

            // Programar desde el inicio
            scheduleFrom(frame: 0, deck: deck, file: file, autoPlay: false)

            deckState.track       = track
            deckState.currentTime = 0
            deckState.isPlaying   = false
            deckState.isLooping   = false
            deckState.loopStart   = 0
            deckState.loopEnd     = 0
            deckState.cuePoint    = nil

            print("[AudioEngine] Cargado \(track.title) en deck \(deck.rawValue)")
        } catch {
            print("[AudioEngine] Error cargando \(track.title): \(error)")
        }
    }

    func togglePlay(deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB

        guard deckState.track != nil else {
            print("[AudioEngine] togglePlay: no hay track en deck \(deck.rawValue)")
            return
        }

        if deckState.isPlaying {
            // PAUSE — guardar frame actual para poder reanudar
            let pauseFrame = currentFrame(deck: deck)
            if deck == .left { pauseFrameA = pauseFrame }
            else             { pauseFrameB = pauseFrame }

            player.pause()
            stopTimer(deck: deck)
            deckState.isPlaying = false
            print("[AudioEngine] Pausa deck \(deck.rawValue) en frame \(pauseFrame)")
        } else {
            // PLAY / RESUME
            let file = deck == .left ? fileA : fileB
            guard let file else { return }

            let resumeFrame = deck == .left ? pauseFrameA : pauseFrameB

            if resumeFrame > 0 {
                // Reanudar desde donde se pausó
                scheduleFrom(frame: resumeFrame, deck: deck, file: file, autoPlay: false)
            }

            player.play()
            startTimer(deck: deck)
            deckState.isPlaying = true
            print("[AudioEngine] Play deck \(deck.rawValue) desde frame \(resumeFrame)")
        }
    }

    func seek(to time: TimeInterval, deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB
        let file      = deck == .left ? fileA   : fileB

        guard let file, deckState.track != nil else { return }

        let sampleRate  = file.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(max(0, time) * sampleRate)
        let totalFrames = file.length
        guard targetFrame < totalFrames else { return }

        let wasPlaying = deckState.isPlaying

        // Detener completamente para limpiar el schedule
        player.stop()
        stopTimer(deck: deck)

        // Resetear frame de pausa
        if deck == .left { pauseFrameA = targetFrame }
        else             { pauseFrameB = targetFrame }

        scheduleFrom(frame: targetFrame, deck: deck, file: file, autoPlay: false)

        deckState.currentTime = time

        if wasPlaying {
            player.play()
            startTimer(deck: deck)
            deckState.isPlaying = true
        }
    }

    // MARK: - Sync BPM

    func sync(slave: DeckID) {
        let master     = slave == .left ? deckB : deckA
        let slaveState = slave == .left ? deckA : deckB

        guard let masterBPM = master.track?.bpm,
              let slaveBPM  = slaveState.track?.bpm,
              slaveBPM > 0 else {
            print("[AudioEngine] sync: no hay BPM disponible")
            return
        }

        slaveState.tempo = masterBPM / slaveBPM
        print("[AudioEngine] Sync: deck \(slave.rawValue) → \(String(format: "%.2f", slaveState.tempo))x")
    }

    // MARK: - Cue

    func setCue(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        d.cuePoint = d.currentTime
        print("[AudioEngine] Cue marcado en \(d.currentTime)s deck \(deck.rawValue)")
    }

    func jumpToCue(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        guard let cue = d.cuePoint else {
            print("[AudioEngine] jumpToCue: sin cue en deck \(deck.rawValue)")
            return
        }
        seek(to: cue, deck: deck)
    }

    // MARK: - Loops

    func toggleLoop(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        guard let track = d.track else { return }

        if d.isLooping {
            d.isLooping = false
            print("[AudioEngine] Loop OFF deck \(deck.rawValue)")
        } else {
            if d.loopEnd <= d.loopStart {
                let beatDuration = track.bpm != nil ? (60.0 / track.bpm!) : 0.5
                d.loopStart = d.currentTime
                d.loopEnd   = min(d.currentTime + beatDuration * 4, track.duration)
            }
            d.isLooping = true
            print("[AudioEngine] Loop ON: \(String(format: "%.2f", d.loopStart))s → \(String(format: "%.2f", d.loopEnd))s")
        }
    }

    func scaleLoop(deck: DeckID, factor: Double) {
        let d = deck == .left ? deckA : deckB
        guard let duration = d.track?.duration else { return }
        let length = d.loopEnd - d.loopStart
        d.loopEnd = min(d.loopStart + length * factor, duration)
    }

    // MARK: - Helpers internos

    /// Programa un segmento desde un frame concreto hasta el final del archivo
    private func scheduleFrom(frame: AVAudioFramePosition, deck: DeckID, file: AVAudioFile, autoPlay: Bool) {
        let player     = deck == .left ? playerA : playerB
        let deckState  = deck == .left ? deckA   : deckB
        let totalFrames = file.length
        guard frame < totalFrames else { return }
        let frameCount = AVAudioFrameCount(totalFrames - frame)

        if deck == .left { segmentStartFrameA = frame }
        else             { segmentStartFrameB = frame }

        player.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount:    frameCount,
            at:            nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Solo marcar como terminado si no estamos en loop
                if !deckState.isLooping {
                    deckState.isPlaying = false
                    if deck == .left { self.pauseFrameA = 0 }
                    else             { self.pauseFrameB = 0 }
                    self.stopTimer(deck: deck)
                    print("[AudioEngine] Fin de pista deck \(deck.rawValue)")
                }
            }
        }
    }

    /// Devuelve el frame actual del PlayerNode (posición real en el archivo)
    private func currentFrame(deck: DeckID) -> AVAudioFramePosition {
        let player       = deck == .left ? playerA : playerB
        let segmentStart = deck == .left ? segmentStartFrameA : segmentStartFrameB

        guard let nodeTime   = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            // Sin render time todavía: devolver el frame de inicio del segmento
            return segmentStart
        }
        return segmentStart + playerTime.sampleTime
    }

    // MARK: - Timer de progreso

    private func startTimer(deck: DeckID) {
        stopTimer(deck: deck)   // evitar timers duplicados

        let timer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let d      = deck == .left ? self.deckA : self.deckB
                let fader  = deck == .left ? self.faderA : self.faderB
                let file   = deck == .left ? self.fileA  : self.fileB

                guard let file, let duration = d.track?.duration else { return }

                // Calcular tiempo desde frame real
                let frame      = self.currentFrame(deck: deck)
                let sampleRate = file.processingFormat.sampleRate
                let realTime   = Double(frame) / sampleRate
                d.currentTime  = min(realTime, duration)

                // Loop
                if d.isLooping && d.currentTime >= d.loopEnd {
                    self.seek(to: d.loopStart, deck: deck)
                    return
                }

                // Fin de pista
                if d.currentTime >= duration - 0.1 && !d.isLooping {
                    d.isPlaying   = false
                    d.currentTime = duration
                    self.stopTimer(deck: deck)
                    return
                }

                // VU meter
                let level = fader.outputVolume * Float(d.isPlaying ? Double.random(in: 0.6...1.0) : 0)
                if deck == .left { self.vuLevelA = level }
                else             { self.vuLevelB = level }
            }

        if deck == .left { timerA = timer } else { timerB = timer }
    }

    private func stopTimer(deck: DeckID) {
        if deck == .left { timerA = nil; vuLevelA = 0 }
        else             { timerB = nil; vuLevelB = 0 }
    }
}
