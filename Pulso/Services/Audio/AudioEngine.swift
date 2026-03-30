import AVFoundation
import Combine
import SwiftUI

/// Motor de audio central — gestiona los dos decks con AVAudioEngine
@MainActor
final class AudioEngine: ObservableObject {
    // MARK: - Decks
    let deckA = DeckState(id: .left)
    let deckB = DeckState(id: .right)

    // MARK: - Crossfader (0.0 = solo A, 0.5 = ambos, 1.0 = solo B)
    @Published var crossfader: Double = 0.5

    // MARK: - Master volume
    @Published var masterVolume: Double = 0.8

    // MARK: - AVAudioEngine
    private let engine = AVAudioEngine()
    private var playerA: AVAudioPlayerNode?
    private var playerB: AVAudioPlayerNode?
    private var eqNodeA: AVAudioUnitEQ?
    private var eqNodeB: AVAudioUnitEQ?
    private var mixerNode: AVAudioMixerNode?

    private var timerA: AnyCancellable?
    private var timerB: AnyCancellable?

    init() {
        setupEngine()
    }

    // MARK: - Setup

    private func setupEngine() {
        let playerA = AVAudioPlayerNode()
        let playerB = AVAudioPlayerNode()
        let eqA = AVAudioUnitEQ(numberOfBands: 3)
        let eqB = AVAudioUnitEQ(numberOfBands: 3)
        let mixer = engine.mainMixerNode

        configureEQ(eqA)
        configureEQ(eqB)

        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(eqA)
        engine.attach(eqB)

        engine.connect(playerA, to: eqA, format: nil)
        engine.connect(playerB, to: eqB, format: nil)
        engine.connect(eqA, to: mixer, format: nil)
        engine.connect(eqB, to: mixer, format: nil)

        self.playerA = playerA
        self.playerB = playerB
        self.eqNodeA = eqA
        self.eqNodeB = eqB

        do {
            try engine.start()
        } catch {
            print("[AudioEngine] Error al iniciar: \(error)")
        }

        // Observar cambios de EQ y volumen en tiempo real
        observeDeckChanges()
    }

    private func configureEQ(_ eq: AVAudioUnitEQ) {
        // Low shelf — bajos (hasta 250 Hz)
        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency = 250
        eq.bands[0].gain = 0
        eq.bands[0].bypass = false

        // Parametric — medios (1 kHz)
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 1000
        eq.bands[1].bandwidth = 1.0
        eq.bands[1].gain = 0
        eq.bands[1].bypass = false

        // High shelf — agudos (desde 8 kHz)
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 8000
        eq.bands[2].gain = 0
        eq.bands[2].bypass = false
    }

    // MARK: - Observadores

    private func observeDeckChanges() {
        // Crossfader → volúmenes de cada deck
        $crossfader
            .sink { [weak self] value in
                self?.applyCrossfader(value)
            }
            .store(in: &cancellables)

        // EQ deck A
        deckA.$eqLow.sink { [weak self] v in self?.eqNodeA?.bands[0].gain = Float(v * 12) }.store(in: &cancellables)
        deckA.$eqMid.sink { [weak self] v in self?.eqNodeA?.bands[1].gain = Float(v * 12) }.store(in: &cancellables)
        deckA.$eqHigh.sink { [weak self] v in self?.eqNodeA?.bands[2].gain = Float(v * 12) }.store(in: &cancellables)

        // EQ deck B
        deckB.$eqLow.sink { [weak self] v in self?.eqNodeB?.bands[0].gain = Float(v * 12) }.store(in: &cancellables)
        deckB.$eqMid.sink { [weak self] v in self?.eqNodeB?.bands[1].gain = Float(v * 12) }.store(in: &cancellables)
        deckB.$eqHigh.sink { [weak self] v in self?.eqNodeB?.bands[2].gain = Float(v * 12) }.store(in: &cancellables)
    }

    private func applyCrossfader(_ value: Double) {
        // Curva lineal simple: A baja cuando crossfader va a la derecha
        let gainA = Float(max(0, 1.0 - (value * 2 - 1).clamped(to: 0...1)))
        let gainB = Float(max(0, (value * 2 - 1).clamped(to: -1...0) + 1))
        playerA?.volume = gainA * Float(deckA.volume) * Float(masterVolume)
        playerB?.volume = gainB * Float(deckB.volume) * Float(masterVolume)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - API pública

    func load(track: Track, into deck: DeckID) {
        let player = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA : deckB

        guard let player else { return }

        // Detener si estaba reproduciendo
        if player.isPlaying { player.stop() }

        do {
            let file = try AVAudioFile(forReading: track.url)
            player.scheduleFile(file, at: nil)
            deckState.track = track
            deckState.currentTime = 0
            deckState.isPlaying = false
        } catch {
            print("[AudioEngine] Error cargando \(track.title): \(error)")
        }
    }

    func togglePlay(deck: DeckID) {
        let player = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA : deckB

        guard let player, deckState.track != nil else { return }

        if deckState.isPlaying {
            player.pause()
            stopTimer(deck: deck)
        } else {
            player.play()
            startTimer(deck: deck)
        }
        deckState.isPlaying = !deckState.isPlaying
    }

    func sync(slave: DeckID) {
        // Sincroniza el BPM del deck esclavo al maestro
        let masterDeck = slave == .left ? deckB : deckA
        let slaveDeck = slave == .left ? deckA : deckB

        guard let masterBPM = masterDeck.track?.bpm,
              let slaveBPM = slaveDeck.track?.bpm,
              slaveBPM > 0 else { return }

        slaveDeck.tempo = masterBPM / slaveBPM
        applyCrossfader(crossfader)
    }

    func setCue(deck: DeckID) {
        let deckState = deck == .left ? deckA : deckB
        deckState.cuePoint = deckState.currentTime
    }

    func jumpToCue(deck: DeckID) {
        guard let cue = (deck == .left ? deckA : deckB).cuePoint else { return }
        seek(to: cue, deck: deck)
    }

    func seek(to time: TimeInterval, deck: DeckID) {
        let player = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA : deckB
        guard let player, let track = deckState.track else { return }

        let wasPlaying = deckState.isPlaying
        if wasPlaying { player.stop() }

        do {
            let file = try AVAudioFile(forReading: track.url)
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(time * sampleRate)
            let frameCount = AVAudioFrameCount(file.length - startFrame)
            player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
            deckState.currentTime = time
            if wasPlaying { player.play() }
        } catch {
            print("[AudioEngine] Error en seek: \(error)")
        }
    }

    // MARK: - Timer de progreso

    private func startTimer(deck: DeckID) {
        let timer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let deckState = deck == .left ? self.deckA : self.deckB
                if let duration = deckState.track?.duration {
                    deckState.currentTime = min(deckState.currentTime + 0.05, duration)
                    if deckState.currentTime >= duration {
                        deckState.isPlaying = false
                        self.stopTimer(deck: deck)
                    }
                }
            }

        if deck == .left { timerA = timer } else { timerB = timer }
    }

    private func stopTimer(deck: DeckID) {
        if deck == .left { timerA = nil } else { timerB = nil }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
