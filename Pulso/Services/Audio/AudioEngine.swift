import AVFoundation
import Accelerate
import Combine
import SwiftUI

@MainActor
final class AudioEngine: ObservableObject {
    private struct DeckSnapshot: Codable {
        var trackID: UUID?
        var currentTime: TimeInterval
        var tempo: Double
        var volume: Double
        var eqLow: Double
        var eqMid: Double
        var eqHigh: Double
        var isLooping: Bool
        var loopStart: TimeInterval
        var loopEnd: TimeInterval
        var keyLock: Bool
        var hotCues: [HotCue]
    }

    private struct SessionSnapshot: Codable {
        var crossfader: Double
        var masterVolume: Double
        var deckA: DeckSnapshot
        var deckB: DeckSnapshot
    }

    private enum DeckChannel {
        case left
        case right
    }

    private let sessionStorageKey = "pulso_session_snapshot"

    // MARK: - Decks
    let deckA = DeckState(id: .left)
    let deckB = DeckState(id: .right)

    // MARK: - Estado publicado
    @Published var crossfader: Double = 0.5
    @Published var masterVolume: Double = 0.8
    @Published var vuLevelA: Float = 0
    @Published var vuLevelB: Float = 0

    // MARK: - Grafo AVAudioEngine
    private let engine = AVAudioEngine()

    private var playerA = AVAudioPlayerNode()
    private var pitchA  = AVAudioUnitTimePitch()
    private var eqA     = AVAudioUnitEQ(numberOfBands: 3)
    private var faderA  = AVAudioMixerNode()

    private var playerB = AVAudioPlayerNode()
    private var pitchB  = AVAudioUnitTimePitch()
    private var eqB     = AVAudioUnitEQ(numberOfBands: 3)
    private var faderB  = AVAudioMixerNode()

    private var masterMixer: AVAudioMixerNode { engine.mainMixerNode }

    // Archivo cargado por deck
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?

    // Frame de inicio del segmento programado (para calcular currentTime)
    private var segStartA: AVAudioFramePosition = 0
    private var segStartB: AVAudioFramePosition = 0

    // Frame donde se pausó (para reanudar)
    private var pausedAtA: AVAudioFramePosition = 0
    private var pausedAtB: AVAudioFramePosition = 0

    private var cancellables = Set<AnyCancellable>()
    private var timerA: AnyCancellable?
    private var timerB: AnyCancellable?

    // MARK: - Init
    init() {
        // Orden obligatorio: grafo → engine arranca → observadores
        setupGraph()
        #if os(iOS)
        applyAudioLatencySetting()
        #endif
        guard (try? engine.start()) != nil else {
            print("[AudioEngine] ❌ No se pudo iniciar el engine")
            return
        }
        print("[AudioEngine] ✅ Engine iniciado")
        setupObservers()
    }

    // MARK: - Grafo

    private func setupGraph() {
        let nodesA: [AVAudioNode] = [playerA, pitchA, eqA, faderA]
        let nodesB: [AVAudioNode] = [playerB, pitchB, eqB, faderB]
        (nodesA + nodesB).forEach { engine.attach($0) }

        // Deck A: player → pitch → eq → fader → master
        engine.connect(playerA, to: pitchA,      format: nil)
        engine.connect(pitchA,  to: eqA,         format: nil)
        engine.connect(eqA,     to: faderA,      format: nil)
        engine.connect(faderA,  to: masterMixer, format: nil)

        // Deck B: igual
        engine.connect(playerB, to: pitchB,      format: nil)
        engine.connect(pitchB,  to: eqB,         format: nil)
        engine.connect(eqB,     to: faderB,      format: nil)
        engine.connect(faderB,  to: masterMixer, format: nil)

        // TimePitch: solo cambia velocidad, no tono
        pitchA.pitch = 0; pitchA.rate = 1
        pitchB.pitch = 0; pitchB.rate = 1

        // EQ: iniciar en flat
        setupEQ(eqA)
        setupEQ(eqB)

        // Volúmenes iniciales
        masterMixer.outputVolume = Float(masterVolume)
        // Crossfader centrado: ambos a cos(45°) ≈ 0.707
        let initialGain = Float(cos(Double.pi / 4))
        faderA.outputVolume = initialGain
        faderB.outputVolume = initialGain

        installVUMeterTap(on: faderA, deck: .left)
        installVUMeterTap(on: faderB, deck: .right)
    }

    private func setupEQ(_ eq: AVAudioUnitEQ) {
        // LOW shelf ≤ 200 Hz
        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency  = 200
        eq.bands[0].gain       = 0
        eq.bands[0].bypass     = false

        // MID parametric 1 kHz
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency  = 1000
        eq.bands[1].bandwidth  = 1.5
        eq.bands[1].gain       = 0
        eq.bands[1].bypass     = false

        // HIGH shelf ≥ 8 kHz
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency  = 8000
        eq.bands[2].gain       = 0
        eq.bands[2].bypass     = false
    }

    // MARK: - Observadores (se conectan DESPUÉS de que el engine esté corriendo)

    private func setupObservers() {
        // Master volume
        $masterVolume
            .sink { [weak self] v in self?.masterMixer.outputVolume = Float(v) }
            .store(in: &cancellables)

        // Crossfader
        $crossfader
            .sink { [weak self] _ in
                self?.refreshFaders()
            }
            .store(in: &cancellables)

        // EQ Deck A — knob -1…+1 → gain -20…+20 dB, kill = -96 dB
        deckA.$eqLow .sink { [weak self] v in self?.eqA.bands[0].gain = Self.knobToGain(v) }.store(in: &cancellables)
        deckA.$eqMid .sink { [weak self] v in self?.eqA.bands[1].gain = Self.knobToGain(v) }.store(in: &cancellables)
        deckA.$eqHigh.sink { [weak self] v in self?.eqA.bands[2].gain = Self.knobToGain(v) }.store(in: &cancellables)

        // EQ Deck B
        deckB.$eqLow .sink { [weak self] v in self?.eqB.bands[0].gain = Self.knobToGain(v) }.store(in: &cancellables)
        deckB.$eqMid .sink { [weak self] v in self?.eqB.bands[1].gain = Self.knobToGain(v) }.store(in: &cancellables)
        deckB.$eqHigh.sink { [weak self] v in self?.eqB.bands[2].gain = Self.knobToGain(v) }.store(in: &cancellables)

        // Tempo → rate del TimePitch
        deckA.$tempo.sink { [weak self] _ in self?.updateTimePitch(for: .left) }.store(in: &cancellables)
        deckB.$tempo.sink { [weak self] _ in self?.updateTimePitch(for: .right) }.store(in: &cancellables)
        deckA.$keyLock.sink { [weak self] _ in self?.updateTimePitch(for: .left) }.store(in: &cancellables)
        deckB.$keyLock.sink { [weak self] _ in self?.updateTimePitch(for: .right) }.store(in: &cancellables)

        // Volume de deck → fader (recalculando con crossfader)
        deckA.$volume.sink { [weak self] _ in self?.refreshFaders() }.store(in: &cancellables)
        deckB.$volume.sink { [weak self] _ in self?.refreshFaders() }.store(in: &cancellables)
    }

    private static func knobToGain(_ knob: Double) -> Float {
        if knob <= -0.98 { return -96 }   // kill total
        return Float(knob * 20)            // -20 … +20 dB
    }

    private func refreshFaders() {
        let curve = UserDefaults.standard.string(forKey: "pulso_crossfade_curve") ?? "linear"
        let x = crossfader
        let gainA: Float
        let gainB: Float

        switch curve {
        case "scurve":
            let smooth = x * x * (3 - 2 * x)
            let angle = smooth * .pi / 2
            gainA = Float(cos(angle))
            gainB = Float(sin(angle))
        case "cut":
            gainA = x < 0.5 ? 1 : 0
            gainB = x >= 0.5 ? 1 : 0
        default:
            gainA = Float(1.0 - x)
            gainB = Float(x)
        }

        faderA.outputVolume = Float(deckA.volume) * gainA
        faderB.outputVolume = Float(deckB.volume) * gainB
    }

    // MARK: - API pública

    func load(track: Track, into deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB

        if player.isPlaying { player.stop() }
        stopTimer(deck: deck)
        resetPosition(deck: deck, frame: 0)

        do {
            let file = try AVAudioFile(forReading: track.url)
            if deck == .left { fileA = file } else { fileB = file }

            scheduleSegment(file: file, from: 0, deck: deck)

            deckState.track       = track
            deckState.currentTime = 0
            deckState.isPlaying   = false
            deckState.isLooping   = false
            deckState.loopStart   = 0
            deckState.loopEnd     = 0
            deckState.hotCues     = []
            print("[AudioEngine] ✅ Cargado '\(track.title)' en deck \(deck.rawValue)")
            saveSession()
        } catch {
            print("[AudioEngine] ❌ Error cargando \(track.title): \(error)")
        }
    }

    func togglePlay(deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB
        guard deckState.track != nil else { return }

        if deckState.isPlaying {
            // ── PAUSA ──
            // Guardar frame exacto antes de detener
            let frame = liveFrame(deck: deck)
            if deck == .left { pausedAtA = frame } else { pausedAtB = frame }

            player.stop()          // stop limpia el schedule; pause() no para de verdad
            stopTimer(deck: deck)
            deckState.isPlaying = false
            print("[AudioEngine] ⏸ Deck \(deck.rawValue) pausado en frame \(frame)")
            saveSession()

        } else {
            // ── PLAY / REANUDAR ──
            let file = deck == .left ? fileA : fileB
            guard let file else { return }

            let from = deck == .left ? pausedAtA : pausedAtB
            scheduleSegment(file: file, from: from, deck: deck)
            player.play()
            startTimer(deck: deck)
            deckState.isPlaying = true
            print("[AudioEngine] ▶ Deck \(deck.rawValue) play desde frame \(from)")
            saveSession()
        }
    }

    func seek(to time: TimeInterval, deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB
        let file      = deck == .left ? fileA   : fileB
        guard let file, deckState.track != nil else { return }

        let sr          = file.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(max(0, time) * sr)
        guard targetFrame < file.length else { return }

        let wasPlaying = deckState.isPlaying
        player.stop()
        stopTimer(deck: deck)

        resetPosition(deck: deck, frame: targetFrame)
        scheduleSegment(file: file, from: targetFrame, deck: deck)
        deckState.currentTime = time

        if wasPlaying {
            player.play()
            startTimer(deck: deck)
            deckState.isPlaying = true
        }
        saveSession()
    }

    func sync(slave: DeckID) {
        let masterDeck = slave == .left ? deckB : deckA
        let slaveDeck  = slave == .left ? deckA : deckB
        guard let masterBPM = masterDeck.track?.bpm,
              let slaveBPM  = slaveDeck.track?.bpm,
              slaveBPM > 0 else {
            print("[AudioEngine] sync: BPM no disponible")
            return
        }
        slaveDeck.tempo = masterBPM / slaveBPM
        print("[AudioEngine] 🔄 Sync deck \(slave.rawValue): rate=\(String(format:"%.3f", slaveDeck.tempo))")
        saveSession()
    }

    func setCue(deck: DeckID) {
        setHotCue(deck: deck, index: 0)
    }

    func jumpToCue(deck: DeckID) {
        jumpToHotCue(deck: deck, index: 0)
    }

    func setHotCue(deck: DeckID, index: Int) {
        let d = deck == .left ? deckA : deckB
        let cue = HotCue(
            index: index,
            time: d.currentTime,
            name: "C\(index + 1)",
            color: HotCueColor.allCases[index % HotCueColor.allCases.count]
        )

        if let existingIndex = d.hotCues.firstIndex(where: { $0.index == index }) {
            d.hotCues[existingIndex] = cue
        } else {
            d.hotCues.append(cue)
            d.hotCues.sort { $0.index < $1.index }
            if d.hotCues.count > 8 {
                d.hotCues = Array(d.hotCues.prefix(8))
            }
        }
        saveSession()
    }

    func jumpToHotCue(deck: DeckID, index: Int) {
        let d = deck == .left ? deckA : deckB
        guard let cue = d.hotCues.first(where: { $0.index == index }) else { return }
        seek(to: cue.time, deck: deck)
    }

    func toggleLoop(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        guard let track = d.track else { return }
        if d.isLooping {
            d.isLooping = false
        } else {
            if d.loopEnd <= d.loopStart {
                let beat = track.bpm.map { 60.0 / $0 } ?? 0.5
                d.loopStart = d.currentTime
                d.loopEnd   = min(d.currentTime + beat * 4, track.duration)
            }
            d.isLooping = true
        }
        saveSession()
    }

    func scaleLoop(deck: DeckID, factor: Double) {
        let d = deck == .left ? deckA : deckB
        guard let dur = d.track?.duration else { return }
        d.loopEnd = min(d.loopStart + (d.loopEnd - d.loopStart) * factor, dur)
        saveSession()
    }

    // MARK: - Internos

    private func scheduleSegment(file: AVAudioFile, from frame: AVAudioFramePosition, deck: DeckID) {
        let player = deck == .left ? playerA : playerB
        let d      = deck == .left ? deckA   : deckB
        guard frame < file.length else { return }

        let count = AVAudioFrameCount(file.length - frame)
        if deck == .left { segStartA = frame } else { segStartB = frame }

        player.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !d.isLooping else { return }
                d.isPlaying = false
                self.stopTimer(deck: deck)
                self.resetPosition(deck: deck, frame: 0)
                print("[AudioEngine] 🏁 Fin pista deck \(deck.rawValue)")
            }
        }
    }

    /// Frame real actual del player en el archivo
    private func liveFrame(deck: DeckID) -> AVAudioFramePosition {
        let player   = deck == .left ? playerA : playerB
        let segStart = deck == .left ? segStartA : segStartB
        guard let nodeTime   = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return segStart }
        return max(segStart, segStart + playerTime.sampleTime)
    }

    private func resetPosition(deck: DeckID, frame: AVAudioFramePosition) {
        if deck == .left { segStartA = frame; pausedAtA = frame }
        else             { segStartB = frame; pausedAtB = frame }
    }

    private func updateTimePitch(for deck: DeckChannel) {
        let state = deck == .left ? deckA : deckB
        let pitch = deck == .left ? pitchA : pitchB
        let rate = max(state.tempo, 0.01)

        pitch.rate = Float(rate)
        if state.keyLock {
            pitch.pitch = 0
        } else {
            pitch.pitch = Float(-1200.0 * log2(rate))
        }
        saveSession()
    }

    private func installVUMeterTap(on node: AVAudioMixerNode, deck: DeckChannel) {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let rms = Self.calculateRMS(buffer: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if deck == .left {
                    self.vuLevelA = rms
                } else {
                    self.vuLevelB = rms
                }
            }
        }
    }

    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        return min(max(rms * 6, 0), 1)
    }

    #if os(iOS)
    private func applyAudioLatencySetting() {
        let latency = UserDefaults.standard.double(forKey: "pulso_audio_latency")
        guard latency > 0 else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredIOBufferDuration(latency)
        try? session.setActive(true)
    }
    #endif

    func saveSession() {
        let snapshot = SessionSnapshot(
            crossfader: crossfader,
            masterVolume: masterVolume,
            deckA: snapshot(for: deckA),
            deckB: snapshot(for: deckB)
        )

        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            UserDefaults.standard.set(data, forKey: sessionStorageKey)
        }
    }

    func restoreSession(library: LibraryService) {
        guard let data = UserDefaults.standard.data(forKey: sessionStorageKey),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return }

        crossfader = snapshot.crossfader
        masterVolume = snapshot.masterVolume
        restore(deck: deckA, from: snapshot.deckA, deckID: .left, library: library)
        restore(deck: deckB, from: snapshot.deckB, deckID: .right, library: library)
        refreshFaders()
    }

    private func restore(deck: DeckState, from snapshot: DeckSnapshot, deckID: DeckID, library: LibraryService) {
        if let trackID = snapshot.trackID,
           let track = library.tracks.first(where: { $0.id == trackID }) {
            load(track: track, into: deckID)
        }

        deck.tempo = snapshot.tempo
        deck.volume = snapshot.volume
        deck.eqLow = snapshot.eqLow
        deck.eqMid = snapshot.eqMid
        deck.eqHigh = snapshot.eqHigh
        deck.isLooping = snapshot.isLooping
        deck.loopStart = snapshot.loopStart
        deck.loopEnd = snapshot.loopEnd
        deck.keyLock = snapshot.keyLock
        deck.hotCues = snapshot.hotCues

        if snapshot.trackID != nil {
            seek(to: snapshot.currentTime, deck: deckID)
        }
    }

    private func snapshot(for deck: DeckState) -> DeckSnapshot {
        DeckSnapshot(
            trackID: deck.track?.id,
            currentTime: deck.currentTime,
            tempo: deck.tempo,
            volume: deck.volume,
            eqLow: deck.eqLow,
            eqMid: deck.eqMid,
            eqHigh: deck.eqHigh,
            isLooping: deck.isLooping,
            loopStart: deck.loopStart,
            loopEnd: deck.loopEnd,
            keyLock: deck.keyLock,
            hotCues: deck.hotCues
        )
    }

    // MARK: - Timer

    private func startTimer(deck: DeckID) {
        stopTimer(deck: deck)
        let timer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let d    = deck == .left ? self.deckA    : self.deckB
                let file = deck == .left ? self.fileA    : self.fileB
                guard let file, let dur = d.track?.duration else { return }

                // Posición real
                let frame = self.liveFrame(deck: deck)
                d.currentTime = min(Double(frame) / file.processingFormat.sampleRate, dur)

                // Loop
                if d.isLooping && d.currentTime >= d.loopEnd {
                    self.seek(to: d.loopStart, deck: deck)
                    return
                }

                // Fin de pista
                if !d.isLooping && d.currentTime >= dur - 0.1 {
                    d.isPlaying   = false
                    d.currentTime = dur
                    self.stopTimer(deck: deck)
                    return
                }

            }
        if deck == .left { timerA = timer } else { timerB = timer }
    }

    private func stopTimer(deck: DeckID) {
        if deck == .left { timerA = nil; vuLevelA = 0 }
        else             { timerB = nil; vuLevelB = 0 }
    }
}
