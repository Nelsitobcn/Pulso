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
        // Ola 2 — opcionales para poder decodificar snapshots anteriores.
        var filter: Double?
        var keyShift: Int?
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
    @Published var masterVolume: Double = 1.0
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

    // Ola 2 — Filtro DJ por deck (1 banda, LPF/HPF según signo del knob) post-fader.
    private var filterA = AVAudioUnitEQ(numberOfBands: 1)
    private var filterB = AVAudioUnitEQ(numberOfBands: 1)

    // Ola 2 — Bus master propio + peak limiter antes del mainMixerNode: al sumar dos decks
    // a volumen alto sin limiter hay clipping digital. mainMixerNode queda como volumen master.
    private var masterBus = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0))

    // Ola 2 — Grabación del set (tap post-limiter → WAV en ~/Music/Pulso Recordings).
    @Published var isRecording = false
    @Published var lastRecordingURL: URL?
    private var activeRecorder: StreamRecorder?

    // Ola 2 — VU real: el tap (hilo de render) deja el RMS aquí; el timer de UI lo lee.
    private let vuBoxA = VULevelBox()
    private let vuBoxB = VULevelBox()

    // STEMS: 4 players por deck (vocals/drums/bass/other) + un mixer sumador que converge
    // ANTES del TimePitch. Así tempo/keylock/SYNC/EQ/crossfader operan sobre la suma y no
    // cambian nada del pipeline existente. El mute por stem usa `player.volume`
    // (AVAudioPlayerNode adopta AVAudioMixing; el volumen aplica en la entrada del mixer).
    //
    //   playerA ──────────────┐
    //   stemPlayersA[0..3] ───┴→ stemSumA → pitchA → eqA → faderA → master
    private var stemPlayersA: [AVAudioPlayerNode] = (0..<4).map { _ in AVAudioPlayerNode() }
    private var stemPlayersB: [AVAudioPlayerNode] = (0..<4).map { _ in AVAudioPlayerNode() }
    private var stemSumA = AVAudioMixerNode()
    private var stemSumB = AVAudioMixerNode()

    private var masterMixer: AVAudioMixerNode { engine.mainMixerNode }

    // Canal de PREESCUCHA (cue): independiente de los decks. Suena una pista candidata
    // (p.ej. un resultado de YouTube ya descargado) con su propio volumen, sin pasar por
    // los faders/crossfader ni mezclarse con el master de los decks.
    private var previewPlayer = AVAudioPlayerNode()
    private var previewMixer  = AVAudioMixerNode()
    private var previewFile: AVAudioFile?
    /// Volumen del canal de preescucha (0…1), independiente del master.
    @Published var previewVolume: Double = 0.8 {
        didSet { previewMixer.outputVolume = Float(previewVolume) }
    }
    @Published var isPreviewingCue = false
    @Published var previewingTitle = ""
    /// Reproductor de preescucha completo (auditioning tipo Rekordbox):
    @Published var isPreviewPlaying = false          // play/pause
    @Published var previewTime: TimeInterval = 0      // posición actual (s)
    @Published var previewDuration: TimeInterval = 0  // duración total (s)
    /// Track de preescucha con BPM/key analizados (se rellena en background). Sirve para mostrar
    /// datos en el modal y para arrastrarlo/cargarlo a un deck.
    @Published var previewTrack: Track?
    // Base de tiempo del preview (mismo patrón que los decks).
    private var previewPausedAt: TimeInterval = 0
    private var previewHostTime: Double = 0
    private var previewURL: URL?
    private var previewTimer: AnyCancellable?

    // Archivo cargado por deck
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?

    // Archivos de stems cargados por deck (índice = StemType.rawValue). Si != nil, el deck
    // reproduce en MODO STEMS (los 4 stem players suenan; el player principal calla).
    private var stemFilesA: [AVAudioFile]?
    private var stemFilesB: [AVAudioFile]?

    // Tiempo de audio (segundos) donde se pausó — fuente de verdad
    private var pausedAtA: TimeInterval = 0
    private var pausedAtB: TimeInterval = 0

    // CACurrentMediaTime() cuando arrancó el play más reciente
    private var playHostTimeA: Double = 0
    private var playHostTimeB: Double = 0

    // Tempo en el momento de play (para calcular tiempo correcto)
    private var playTempoA: Double = 1.0
    private var playTempoB: Double = 1.0

    // Token de generación de segmento por deck. Cada scheduleSegment lo incrementa; el
    // completion callback solo actúa si su token sigue vigente. Evita que un stop() hecho
    // para REPROGRAMAR (load/seek/sync) dispare el callback del segmento viejo y resetee
    // playHostTime/isPlaying del segmento nuevo (bug: currentAudioTime se quedaba en 0).
    private var segmentTokenA: Int = 0
    private var segmentTokenB: Int = 0

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
        let nodesA: [AVAudioNode] = [playerA, stemSumA, pitchA, eqA, faderA, filterA] + stemPlayersA
        let nodesB: [AVAudioNode] = [playerB, stemSumB, pitchB, eqB, faderB, filterB] + stemPlayersB
        let nodesPreview: [AVAudioNode] = [previewPlayer, previewMixer]
        let nodesMaster: [AVAudioNode] = [masterBus, limiter]
        (nodesA + nodesB + nodesPreview + nodesMaster).forEach { engine.attach($0) }

        // Deck A: (player + 4 stem players) → stemSum → pitch → eq → fader → filter → masterBus
        engine.connect(playerA, to: stemSumA,    format: nil)
        stemPlayersA.forEach { engine.connect($0, to: stemSumA, format: nil) }
        engine.connect(stemSumA, to: pitchA,     format: nil)
        engine.connect(pitchA,  to: eqA,         format: nil)
        engine.connect(eqA,     to: faderA,      format: nil)
        engine.connect(faderA,  to: filterA,     format: nil)
        engine.connect(filterA, to: masterBus,   format: nil)

        // Deck B: igual
        engine.connect(playerB, to: stemSumB,    format: nil)
        stemPlayersB.forEach { engine.connect($0, to: stemSumB, format: nil) }
        engine.connect(stemSumB, to: pitchB,     format: nil)
        engine.connect(pitchB,  to: eqB,         format: nil)
        engine.connect(eqB,     to: faderB,      format: nil)
        engine.connect(faderB,  to: filterB,     format: nil)
        engine.connect(filterB, to: masterBus,   format: nil)

        // Bus master: suma de decks → limiter → mainMixerNode (volumen master).
        engine.connect(masterBus, to: limiter,    format: nil)
        engine.connect(limiter,   to: masterMixer, format: nil)

        // Filtros DJ arrancan en bypass (knob al centro).
        Self.applyFilter(0, to: filterA)
        Self.applyFilter(0, to: filterB)

        // VU real: tap post-fader por deck (el timer de UI lee las cajas).
        installVUTap(on: faderA, box: vuBoxA)
        installVUTap(on: faderB, box: vuBoxB)

        // Canal de preescucha: previewPlayer → previewMixer → master.
        // Va directo al master (sin EQ/crossfader): es un cue, no un deck.
        engine.connect(previewPlayer, to: previewMixer, format: nil)
        engine.connect(previewMixer,  to: masterMixer,  format: nil)
        previewMixer.outputVolume = Float(previewVolume)

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

    // MARK: - Filtro DJ / VU / pitch (Ola 2)

    /// Mapa del knob FILTER (−1…+1) a la banda del EQ: negativo = low-pass sweep
    /// 20 kHz→200 Hz, positivo = high-pass sweep 20 Hz→8 kHz, centro = bypass.
    private static func applyFilter(_ v: Double, to eq: AVAudioUnitEQ) {
        let band = eq.bands[0]
        guard abs(v) >= 0.03 else { band.bypass = true; return }
        band.bypass = false
        band.bandwidth = 0.7
        band.gain = 0
        if v < 0 {
            band.filterType = .resonantLowPass
            band.frequency = Float(20_000 * pow(200.0 / 20_000.0, -v))
        } else {
            band.filterType = .resonantHighPass
            band.frequency = Float(20 * pow(8_000.0 / 20.0, v))
        }
    }

    /// Pitch (cents) del TimePitch: compensación de keylock + key shift en semitonos.
    private static func pitchCents(keyLock: Bool, rate: Double, keyShift: Int) -> Float {
        let comp = keyLock ? 0.0 : -1200.0 * log2(rate)
        return Float(comp + Double(keyShift) * 100.0)
    }

    /// Tap post-fader: calcula el RMS de cada buffer en el hilo de render y lo deja en la
    /// caja thread-safe. El timer de UI (50 ms) lo convierte en nivel con attack/release.
    private func installVUTap(on node: AVAudioMixerNode, box: VULevelBox) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.value = Self.rms(of: buffer)
        }
    }

    private static nonisolated func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var acc: Float = 0
        for ch in 0..<channels {
            var meanSquare: Float = 0
            vDSP_measqv(data[ch], 1, &meanSquare, vDSP_Length(frames))
            acc += meanSquare
        }
        return sqrt(acc / Float(channels))
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

        // Mutes de stems → volumen del stem player (instantáneo, sin tocar el scheduling)
        deckA.$stemVocalMuted .sink { [weak self] m in self?.stemPlayersA[StemType.vocal.rawValue].volume  = m ? 0 : 1 }.store(in: &cancellables)
        deckA.$stemDrumsMuted .sink { [weak self] m in self?.stemPlayersA[StemType.drums.rawValue].volume  = m ? 0 : 1 }.store(in: &cancellables)
        deckA.$stemBassMuted  .sink { [weak self] m in self?.stemPlayersA[StemType.bass.rawValue].volume   = m ? 0 : 1 }.store(in: &cancellables)
        deckA.$stemMelodyMuted.sink { [weak self] m in self?.stemPlayersA[StemType.melody.rawValue].volume = m ? 0 : 1 }.store(in: &cancellables)
        deckB.$stemVocalMuted .sink { [weak self] m in self?.stemPlayersB[StemType.vocal.rawValue].volume  = m ? 0 : 1 }.store(in: &cancellables)
        deckB.$stemDrumsMuted .sink { [weak self] m in self?.stemPlayersB[StemType.drums.rawValue].volume  = m ? 0 : 1 }.store(in: &cancellables)
        deckB.$stemBassMuted  .sink { [weak self] m in self?.stemPlayersB[StemType.bass.rawValue].volume   = m ? 0 : 1 }.store(in: &cancellables)
        deckB.$stemMelodyMuted.sink { [weak self] m in self?.stemPlayersB[StemType.melody.rawValue].volume = m ? 0 : 1 }.store(in: &cancellables)

        // Filtro DJ (Ola 2)
        deckA.$filter.sink { [weak self] v in guard let self else { return }; Self.applyFilter(v, to: self.filterA) }.store(in: &cancellables)
        deckB.$filter.sink { [weak self] v in guard let self else { return }; Self.applyFilter(v, to: self.filterB) }.store(in: &cancellables)

        // Key Shift (Ola 2) → recalcular pitch del TimePitch. receive(on:) difiere al
        // siguiente ciclo del main loop: @Published emite en willSet y updateTimePitch
        // relee la propiedad (necesita el valor NUEVO ya asignado).
        deckA.$keyShift.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateTimePitch(for: .left) }.store(in: &cancellables)
        deckB.$keyShift.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateTimePitch(for: .right) }.store(in: &cancellables)
    }

    // MARK: - Helpers de stems

    private func stemFiles(for deck: DeckID) -> [AVAudioFile]? {
        deck == .left ? stemFilesA : stemFilesB
    }

    private func stemPlayers(for deck: DeckID) -> [AVAudioPlayerNode] {
        deck == .left ? stemPlayersA : stemPlayersB
    }

    /// `true` si el deck reproduce en modo stems (4 players) en vez del player principal.
    private func stemsActive(for deck: DeckID) -> Bool {
        stemFiles(for: deck) != nil
    }

    /// Para el deck: player principal + los 4 stem players. `stop()` sobre un player sin nada
    /// programado es inocuo, así que siempre paramos los 5 (evita ramas según el modo).
    private func stopAllPlayers(deck: DeckID) {
        let main = deck == .left ? playerA : playerB
        main.stop()
        stemPlayers(for: deck).forEach { $0.stop() }
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
        let deckState = deck == .left ? deckA : deckB

        stopAllPlayers(deck: deck)
        stopTimer(deck: deck)
        if deck == .left { pausedAtA = 0 } else { pausedAtB = 0 }

        do {
            let file = try AVAudioFile(forReading: track.url)
            if deck == .left { fileA = file } else { fileB = file }

            // STEMS: si los 4 archivos existen en disco, el deck entra en modo stems.
            // Los AVAudioFile de stems se abren aquí (una vez por carga, no por schedule).
            var stems: [AVAudioFile]? = nil
            if let stemURLs = StemStore.urls(for: track.id) {
                stems = try? stemURLs.map { try AVAudioFile(forReading: $0) }
            }
            if deck == .left { stemFilesA = stems } else { stemFilesB = stems }
            deckState.stemsAvailable = stems != nil
            deckState.stemError = nil
            // Pista nueva → los 4 stems suenan (mutes a off; los sinks reponen volume=1).
            deckState.stemVocalMuted  = false
            deckState.stemDrumsMuted  = false
            deckState.stemBassMuted   = false
            deckState.stemMelodyMuted = false

            scheduleFromBeginning(file: file, deck: deck)

            // Resetear pitch node al formato del archivo
            let pitch = deck == .left ? pitchA : pitchB
            pitch.rate  = Float(deckState.tempo)
            pitch.pitch = 0

            deckState.track       = track
            deckState.currentTime = 0
            deckState.isPlaying   = false
            deckState.isLooping   = false
            deckState.loopStart   = 0
            deckState.loopEnd     = 0
            deckState.hotCues     = []
            // Picos de alta densidad (RAM) para la onda ampliada del panel beatmatch.
            HiResWaveformCache.shared.ensure(track: track)
            saveSession()
        } catch {
            print("[AudioEngine] ❌ Error cargando \(track.title): \(error)")
        }
    }

    func togglePlay(deck: DeckID) {
        let deckState = deck == .left ? deckA : deckB
        guard deckState.track != nil else { return }

        if deckState.isPlaying {
            // ── PAUSA: guardar tiempo actual ──
            if deck == .left {
                pausedAtA = currentAudioTime(deck: deck)
            } else {
                pausedAtB = currentAudioTime(deck: deck)
            }
            // Si este deck participa en el phase-lock, soltarlo.
            if phaseLockSlave == deck || (phaseLockSlave != nil && phaseLockSlave != deck) {
                stopPhaseLock()
            }
            stopAllPlayers(deck: deck)
            stopTimer(deck: deck)
            deckState.isPlaying = false
            saveSession()
        } else {
            // ── PLAY / REANUDAR desde donde se pausó ──
            let pausedAt = deck == .left ? pausedAtA : pausedAtB
            startPlayback(from: pausedAt, deck: deck)
        }
    }

    func seek(to time: TimeInterval, deck: DeckID) {
        let deckState = deck == .left ? deckA : deckB
        guard deckState.track != nil else { return }
        let wasPlaying = deckState.isPlaying
        stopAllPlayers(deck: deck)
        stopTimer(deck: deck)
        if deck == .left { pausedAtA = time } else { pausedAtB = time }
        deckState.currentTime = time
        if wasPlaying {
            startPlayback(from: time, deck: deck)
        }
        saveSession()
    }

    // MARK: - Scrub (arrastre tipo vinilo)

    /// Recuerda si el deck estaba sonando al empezar un arrastre, para reanudar al soltar.
    private var scrubWasPlayingA = false
    private var scrubWasPlayingB = false

    /// Empieza un arrastre tipo vinilo: silencia el audio del deck (el player se para) para que
    /// mover la onda no dispare glitches. NO reprograma en cada frame (eso lo hace `endScrub`).
    func beginScrub(deck: DeckID) {
        let deckState = deck == .left ? deckA : deckB
        let wasPlaying = deckState.isPlaying
        if deck == .left { scrubWasPlayingA = wasPlaying } else { scrubWasPlayingB = wasPlaying }
        // Soltar el phase-lock si este deck participaba (el DJ está tomando control manual).
        if phaseLockSlave != nil { stopPhaseLock() }
        stopAllPlayers(deck: deck)
        stopTimer(deck: deck)
        deckState.isPlaying = false
    }

    /// Durante el arrastre: solo mueve el playhead (barato, a 60fps). No toca el audio.
    func scrub(to time: TimeInterval, deck: DeckID) {
        let deckState = deck == .left ? deckA : deckB
        guard let dur = deckState.track?.duration else { return }
        let t = min(max(0, time), dur)
        if deck == .left { pausedAtA = t } else { pausedAtB = t }
        deckState.currentTime = t
    }

    /// Fin del arrastre: fija la posición exacta y reanuda la reproducción si estaba sonando.
    func endScrub(deck: DeckID) {
        let deckState = deck == .left ? deckA : deckB
        let t = deckState.currentTime
        let wasPlaying = deck == .left ? scrubWasPlayingA : scrubWasPlayingB
        if deck == .left { pausedAtA = t } else { pausedAtB = t }
        if wasPlaying {
            startPlayback(from: t, deck: deck)   // reanuda exactamente donde soltó
        }
        saveSession()
    }

    // Inicia reproducción desde un tiempo dado (siempre hace play)
    private func startPlayback(from time: TimeInterval, deck: DeckID) {
        let player    = deck == .left ? playerA : playerB
        let deckState = deck == .left ? deckA   : deckB
        let file      = deck == .left ? fileA   : fileB
        let pitch     = deck == .left ? pitchA  : pitchB
        guard let file else { return }

        let sr          = file.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(max(0, time) * sr)
        guard targetFrame < file.length else { return }

        stopAllPlayers(deck: deck)
        scheduleSegment(file: file, from: targetFrame, deck: deck)

        // Reaplicar rate/pitch antes de play para asegurar que está activo
        let rate = max(deckState.tempo, 0.01)
        pitch.rate  = Float(rate)
        pitch.pitch = Self.pitchCents(keyLock: deckState.keyLock, rate: rate, keyShift: deckState.keyShift)

        // Arranque. En modo stems los 4 players deben arrancar en el MISMO instante de
        // hardware: play() secuencial los desalinearía unos ms entre sí. play(at:) con un
        // hostTime común (+ colchón de 30 ms para que los 4 lleguen) garantiza que salen
        // muestra-alineados del mixer sumador.
        let startDelay: TimeInterval
        if stemsActive(for: deck) {
            startDelay = 0.03
            let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: startDelay)
            let startTime = AVAudioTime(hostTime: startHost)
            stemPlayers(for: deck).forEach { $0.play(at: startTime) }
        } else {
            startDelay = 0
            player.play()
        }

        // Registrar el momento de inicio para el timer. El colchón de stems se SUMA a la
        // base de tiempo: si no, currentAudioTime adelantaría 30 ms la posición real y el
        // phase-lock del SYNC corregiría un desfase fantasma.
        let tempo = deckState.tempo
        if deck == .left {
            pausedAtA    = time
            playHostTimeA = CACurrentMediaTime() + startDelay
            playTempoA   = tempo
        } else {
            pausedAtB    = time
            playHostTimeB = CACurrentMediaTime() + startDelay
            playTempoB   = tempo
        }

        deckState.currentTime = time
        deckState.isPlaying   = true
        startTimer(deck: deck)
        saveSession()
    }

    /// Aplica tempo directo al nodo AVAudioUnitTimePitch (llamado desde slider)
    func applyTempo(_ newRate: Double, deck: DeckID) {
        // ÁRBITRO de escritura sobre pitch.rate: el slider manual y el phase-lock continuo
        // escriben el MISMO parámetro. Si el usuario mueve el tempo del deck que es el SLAVE
        // de un SYNC activo, el timer del phase-lock lo pisaría 10×/seg ("lo hace muy mal").
        // Comportamiento CDJ estándar: tocar el pitch a mano DESENGANCHA el sync de ese deck.
        if phaseLockSlave == deck {
            stopPhaseLock(restoreBaseRate: false)  // no restaurar: el slider manda ahora
        }

        let pitch     = deck == .left ? pitchA : pitchB
        let deckState = deck == .left ? deckA  : deckB
        let rate      = max(newRate, 0.01)

        pitch.rate  = Float(rate)
        pitch.pitch = Self.pitchCents(keyLock: deckState.keyLock, rate: rate, keyShift: deckState.keyShift)

        if deckState.isPlaying {
            let currentT = currentAudioTime(deck: deck)
            if deck == .left {
                pausedAtA     = currentT
                playHostTimeA = CACurrentMediaTime()
                playTempoA    = rate
            } else {
                pausedAtB     = currentT
                playHostTimeB = CACurrentMediaTime()
                playTempoB    = rate
            }
        }
    }

    func sync(slave: DeckID) {
        let masterDeck = slave == .left ? deckB : deckA
        let slaveDeck  = slave == .left ? deckA : deckB
        let slavePitch = slave == .left ? pitchA : pitchB

        guard let masterBPM = masterDeck.track?.bpm,
              let slaveBPM  = slaveDeck.track?.bpm,
              slaveBPM > 0 else { return }

        let newRate = masterBPM / slaveBPM

        // Aplicar tempo al nodo de audio del slave
        slavePitch.rate  = Float(newRate)
        slavePitch.pitch = Self.pitchCents(keyLock: slaveDeck.keyLock, rate: newRate, keyShift: slaveDeck.keyShift)

        // Actualizar base de tiempo del slave (el tempo cambió).
        if slaveDeck.isPlaying {
            let currentT = currentAudioTime(deck: slave)
            if slave == .left {
                pausedAtA = currentT; playHostTimeA = CACurrentMediaTime(); playTempoA = newRate
            } else {
                pausedAtB = currentT; playHostTimeB = CACurrentMediaTime(); playTempoB = newRate
            }
        }
        slaveDeck.tempo = newRate  // actualiza UI (bpmDisplay)
        saveSession()

        // Si ambos suenan, activar el PHASE-LOCK continuo. La investigación (NotebookLM
        // "Software DJ con IA 2026") confirma que un "align once" SIEMPRE deriva por
        // imprecisiones de punto flotante y por la latencia FFT de AVAudioUnitTimePitch.
        // Los DJ software pro usan un bucle que mide el error de fase contra un beatgrid y
        // hace NUDGE del rate (±pequeño) hasta corregir, sin saltos audibles.
        if slaveDeck.isPlaying && masterDeck.isPlaying {
            // NO se reposiciona el deck (eso lo hacía saltar al principio). El SYNC respeta
            // la posición actual del slave en la canción y SOLO ajusta el tempo de forma
            // continua (phase-lock por nudge) para enganchar y mantener la fase del beat.
            startPhaseLock(slave: slave, baseRate: newRate)
        }
    }

    // MARK: - Phase-lock continuo (beatmatching real)

    /// Posición REAL de salida del player (frames de audio que ya han pasado por el nodo),
    /// no el tiempo de archivo. Es la única fuente fiable para medir fase.
    private func playerOutputTime(_ player: AVAudioPlayerNode) -> Double? {
        guard let nodeTime = player.lastRenderTime,
              let pt = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return Double(pt.sampleTime) / pt.sampleRate
    }

    private var phaseLockTimer: AnyCancellable?
    private var phaseLockSlave: DeckID?

    /// Fase de reproducción respecto al BEATGRID REAL (no contra t=0).
    /// `fileTime` es la posición actual en tiempo de archivo (segundos). Devuelve:
    ///  - `phase`: fracción [0,1) recorrida entre el beat anterior y el siguiente del grid.
    ///  - `barPhase`: fracción [0,1) recorrida dentro del COMPÁS (si hay downbeat fiable),
    ///     para no engancharse a contratiempo. `nil` si no hay downbeat.
    /// Devuelve `nil` completo si el grid no sirve (sin beats / fuera de rango).
    private func gridPhase(beats: [Double], downbeatIndex: Int?, beatsPerBar: Int,
                           at fileTime: Double) -> (phase: Double, barPhase: Double?)? {
        guard beats.count >= 2 else { return nil }
        // Localiza el beat inmediatamente anterior a fileTime (búsqueda binaria).
        var lo = 0, hi = beats.count - 1
        if fileTime <= beats[0] || fileTime >= beats[hi] { return nil } // fuera del grid analizado
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if beats[mid] <= fileTime { lo = mid } else { hi = mid }
        }
        // lo = índice del beat previo, hi = lo+1 (beat siguiente).
        let interval = beats[hi] - beats[lo]
        guard interval > 0 else { return nil }
        let phase = (fileTime - beats[lo]) / interval   // [0,1) dentro del beat

        var barPhase: Double? = nil
        if let db = downbeatIndex, beatsPerBar > 0 {
            // Posición del beat previo dentro del compás (0…beatsPerBar-1), medido desde el "1".
            let beatInBar = ((lo - db) % beatsPerBar + beatsPerBar) % beatsPerBar
            barPhase = (Double(beatInBar) + phase) / Double(beatsPerBar)  // [0,1) dentro del compás
        }
        return (phase, barPhase)
    }

    /// Fase del beat del deck AHORA (para el Beat Match Bar del panel central).
    /// Devuelve la fracción [0,1) recorrida dentro del beat actual según el beatgrid real, o
    /// `nil` si no hay grid/posición usable. Reusa `gridPhase` (misma fuente que el phase-lock).
    func deckBeatPhase(_ deck: DeckID) -> Double? {
        let d = deck == .left ? deckA : deckB
        guard let grid = d.track?.beatGrid, !grid.beats.isEmpty else { return nil }
        let fileTime = currentAudioTime(deck: deck)
        return gridPhase(beats: grid.beats, downbeatIndex: grid.downbeatIndex,
                         beatsPerBar: grid.beatsPerBar, at: fileTime)?.phase
    }

    /// Arranca un bucle que cada 100ms mide el desfase de beat entre master y slave y empuja
    /// suavemente el rate del slave (nudge ±) hasta que los bombos coinciden. Es un controlador
    /// proporcional simple. Se detiene si algún deck para o se vuelve a sincronizar.
    private func startPhaseLock(slave: DeckID, baseRate: Double) {
        stopPhaseLock()
        phaseLockSlave = slave
        let master: DeckID = slave == .left ? .right : .left
        let slavePitch = slave == .left ? pitchA : pitchB

        let masterDeck = master == .left ? deckA : deckB
        let slaveDeck  = slave  == .left ? deckA : deckB
        guard let masterBPM = masterDeck.track?.bpm,
              let slaveBPM  = slaveDeck.track?.bpm,
              masterBPM > 0, slaveBPM > 0 else { return }

        // Beatgrids reales (fuente de verdad de fase). Si faltan → fallback contra t=0.
        let masterGrid = masterDeck.track?.beatGrid
        let slaveGrid  = slaveDeck.track?.beatGrid
        let masterTempo = masterDeck.tempo

        // Fallback (sin grid usable): beat abstracto desde t=0, como antes.
        let beatMasterFile = 60.0 / (masterBPM * masterTempo)
        let beatSlaveFile  = 60.0 / slaveBPM

        phaseLockTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let s = slave == .left ? self.deckA : self.deckB
                let m = master == .left ? self.deckA : self.deckB
                guard s.isPlaying, m.isPlaying else { self.stopPhaseLock(); return }

                // Posición en TIEMPO DE ARCHIVO de cada deck (donde viven los beats del grid).
                let mFile = self.currentAudioTime(deck: master)
                let sFile = self.currentAudioTime(deck: slave)

                // Fase de master y slave. Preferimos la fase del beatgrid real; si el grid no
                // cubre esta posición (intro/outro fuera de rango) caemos al beat abstracto.
                let mp = masterGrid.flatMap {
                    self.gridPhase(beats: $0.beats, downbeatIndex: $0.downbeatIndex,
                                   beatsPerBar: $0.beatsPerBar, at: mFile)
                }
                let sp = slaveGrid.flatMap {
                    self.gridPhase(beats: $0.beats, downbeatIndex: $0.downbeatIndex,
                                   beatsPerBar: $0.beatsPerBar, at: sFile)
                }

                let phaseM: Double
                let phaseS: Double
                if let mp, let sp {
                    // Ambos con grid: si los DOS tienen downbeat, alineamos por COMPÁS (evita
                    // enganche a contratiempo). Si no, beat-a-beat.
                    if let mBar = mp.barPhase, let sBar = sp.barPhase {
                        phaseM = mBar; phaseS = sBar
                    } else {
                        phaseM = mp.phase; phaseS = sp.phase
                    }
                } else {
                    // Fallback: beat abstracto desde t=0 (mismo comportamiento previo).
                    phaseM = mFile.truncatingRemainder(dividingBy: beatMasterFile) / beatMasterFile
                    phaseS = sFile.truncatingRemainder(dividingBy: beatSlaveFile) / beatSlaveFile
                }

                var err = phaseM - phaseS                 // error de fase, fracción de beat/compás
                if err > 0.5 { err -= 1 }                 // distancia circular más corta
                if err < -0.5 { err += 1 }

                // Controlador proporcional con nudge del rate (sin seek → sin saltos audibles).
                // Si el slave va atrasado (err>0) acelera; si adelantado, frena.
                //
                // Escala del error: cuando alineamos por COMPÁS (barPhase, ÷beatsPerBar) el mismo
                // desfase físico da un `err` beatsPerBar veces menor que beat-a-beat. Escalamos la
                // ganancia para que la respuesta del controlador sea la misma en ambos modos
                // (si no, en modo compás convergería ~4x más lento).
                let usingBar = (mp?.barPhase != nil && sp?.barPhase != nil)
                let gain = usingBar ? 2.0 * Double(slaveDeck.track?.beatGrid?.beatsPerBar ?? 4) : 2.0
                let nudge = max(-0.25, min(0.25, err * gain))
                let newRate = baseRate * (1.0 + nudge)
                slavePitch.rate = Float(max(0.01, newRate))

                // FIX crítico (feedback de tiempo): el nudge cambió el rate REAL del nodo, pero
                // currentAudioTime(slave) calcula la posición con playTempo. Si no lo re-anclamos,
                // el próximo tick mide la fase del slave sobre una posición de archivo MENTIROSA
                // → el lazo oscila en vez de converger. Congelamos la posición actual (con el
                // tempo viejo, ya integrado por currentAudioTime hasta ahora) y reiniciamos la
                // base de tiempo con el rate nuevo.
                let frozen = sFile
                if slave == .left {
                    self.pausedAtA = frozen
                    self.playHostTimeA = CACurrentMediaTime()
                    self.playTempoA = newRate
                } else {
                    self.pausedAtB = frozen
                    self.playHostTimeB = CACurrentMediaTime()
                    self.playTempoB = newRate
                }
            }
    }

    /// Detiene el phase-lock continuo.
    /// - Parameter restoreBaseRate: si `true`, devuelve el `pitch.rate` del slave a su tempo
    ///   base exacto (caso normal: el deck para o se re-sincroniza). Si `false`, NO lo toca
    ///   (caso árbitro: el slider acaba de fijar el rate manualmente y debe prevalecer).
    private func stopPhaseLock(restoreBaseRate: Bool = true) {
        phaseLockTimer?.cancel()
        phaseLockTimer = nil
        // Restaurar el rate base exacto del slave al soltar el lock.
        if restoreBaseRate, let s = phaseLockSlave {
            let pitch = s == .left ? pitchA : pitchB
            let deckState = s == .left ? deckA : deckB
            let baseTempo = max(0.01, deckState.tempo)
            pitch.rate = Float(baseTempo)
            // Re-anclar el estado de tiempo con el tempo base: el timer lo dejó en el último
            // rate con nudge, así que currentAudioTime mentiría si no lo reseteamos aquí.
            if deckState.isPlaying {
                let frozen = currentAudioTime(deck: s)
                if s == .left {
                    pausedAtA = frozen; playHostTimeA = CACurrentMediaTime(); playTempoA = baseTempo
                } else {
                    pausedAtB = frozen; playHostTimeB = CACurrentMediaTime(); playTempoB = baseTempo
                }
            }
        }
        phaseLockSlave = nil
    }

    /// Comportamiento CDJ: si reproduciendo → marca cue; si pausado → salta al cue marcado
    func setCue(deck: DeckID) {
        let d = deck == .left ? deckA : deckB
        if d.isPlaying {
            // Marca el cue en la posición actual
            setHotCue(deck: deck, index: 0)
        } else {
            // Parado: salta al cue marcado sin arrancar (preview)
            if d.hotCues.contains(where: { $0.index == 0 }) {
                seek(to: d.hotCues.first(where: { $0.index == 0 })!.time, deck: deck)
            }
        }
    }

    /// Shift+CUE: salta al cue marcado y hace play
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
        // Hot cue siempre arranca play (comportamiento estándar DJ)
        startPlayback(from: cue.time, deck: deck)
    }

    func deleteHotCue(deck: DeckID, index: Int) {
        let d = deck == .left ? deckA : deckB
        d.hotCues.removeAll { $0.index == index }
        saveSession()
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

    // MARK: - Stems (separación y recarga)

    /// Lanza la separación de stems de la pista cargada en `deck` (demucs-mlx en background).
    /// Al terminar, recarga el deck en MODO STEMS manteniendo posición y estado de play.
    func separateStems(deck: DeckID) {
        let deckState = deck == .left ? deckA : deckB
        guard let track = deckState.track, !deckState.isSeparatingStems else { return }
        guard !deckState.stemsAvailable else { return }

        deckState.isSeparatingStems = true
        deckState.stemError = nil

        Task { [weak self] in
            do {
                _ = try await StemSeparator.shared.separate(trackURL: track.url, trackID: track.id)
                await MainActor.run {
                    guard let self else { return }
                    let d = deck == .left ? self.deckA : self.deckB
                    d.isSeparatingStems = false
                    // Solo activar si el deck sigue con la MISMA pista (pudo cambiar durante
                    // la separación). Si cambió, los stems quedan en caché para la próxima.
                    guard d.track?.id == track.id else { return }
                    self.activateStems(deck: deck, trackID: track.id)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    let d = deck == .left ? self.deckA : self.deckB
                    d.isSeparatingStems = false
                    d.stemError = error.localizedDescription
                }
            }
        }
    }

    /// Abre los AVAudioFile de stems y conmuta el deck a modo stems EN CALIENTE:
    /// congela la posición actual, reprograma y (si sonaba) reanuda en el mismo punto.
    private func activateStems(deck: DeckID, trackID: UUID) {
        let deckState = deck == .left ? deckA : deckB
        guard let urls = StemStore.urls(for: trackID) else { return }
        guard let files = try? urls.map({ try AVAudioFile(forReading: $0) }) else {
            deckState.stemError = "No se pudieron abrir los archivos de stems."
            return
        }

        let wasPlaying = deckState.isPlaying
        let t = wasPlaying ? currentAudioTime(deck: deck) : deckState.currentTime

        stopAllPlayers(deck: deck)
        stopTimer(deck: deck)

        if deck == .left { stemFilesA = files; pausedAtA = t } else { stemFilesB = files; pausedAtB = t }
        deckState.stemsAvailable = true
        deckState.currentTime = t
        deckState.isPlaying = false

        if wasPlaying {
            startPlayback(from: t, deck: deck)
        }
    }

    // MARK: - Key Sync / Beat Jump / Grabación (Ola 2)

    /// Ajusta el keyShift del deck para casar su key (Camelot) con la del OTRO deck,
    /// por el camino de semitonos más corto. Sin key en alguna pista → no hace nada.
    func syncKey(deck: DeckID) {
        let own   = deck == .left ? deckA : deckB
        let other = deck == .left ? deckB : deckA
        guard let ownKey = own.track?.key, let otherKey = other.track?.key else { return }
        own.keyShift = ownKey.semitones(to: otherKey)
    }

    func resetKeyShift(deck: DeckID) {
        (deck == .left ? deckA : deckB).keyShift = 0
    }

    /// Salta ±N beats manteniendo reproducción (beats × 60/BPM en tiempo de archivo).
    func beatJump(deck: DeckID, beats: Int) {
        let deckState = deck == .left ? deckA : deckB
        guard let track = deckState.track, let bpm = track.bpm, bpm > 0 else { return }
        let now = deckState.isPlaying ? currentAudioTime(deck: deck) : deckState.currentTime
        let target = min(max(0, now + Double(beats) * 60.0 / bpm), track.duration)
        seek(to: target, deck: deck)
    }

    /// Graba la salida master (post-limiter = lo que suena) a WAV en ~/Music/Pulso Recordings.
    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        let dir = (FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                   ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Pulso Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter.recordingStamp.string(from: Date())
        let url = dir.appendingPathComponent("Pulso Set \(stamp).wav")

        let format = limiter.outputFormat(forBus: 0)
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            print("[AudioEngine] ❌ No se pudo crear el WAV de grabación en \(url.path)")
            return
        }
        let recorder = StreamRecorder(file: file)
        activeRecorder = recorder
        limiter.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.write(buffer)
        }
        lastRecordingURL = url
        isRecording = true
        print("[AudioEngine] ⏺ Grabando en \(url.path)")
    }

    private func stopRecording() {
        guard isRecording else { return }
        limiter.removeTap(onBus: 0)
        activeRecorder = nil   // AVAudioFile se cierra al liberarse
        isRecording = false
        if let url = lastRecordingURL {
            print("[AudioEngine] ⏹ Grabación guardada: \(url.path)")
        }
    }

    // MARK: - Preescucha (cue) por canal propio

    /// Reproduce un archivo LOCAL por el canal de preescucha (auditioning tipo Rekordbox):
    /// suena con volumen propio, sin mezclarse con los decks, y se puede pausar/adelantar. Además
    /// analiza BPM/key en background para mostrarlos antes de cargar. Pensado para escuchar un
    /// candidato (mitad, drop, final) antes de decidir cargarlo a un deck.
    func startCuePreview(url: URL, title: String) {
        stopCuePreview()
        guard let file = try? AVAudioFile(forReading: url) else { return }
        previewFile = file
        previewURL = url
        previewDuration = Double(file.length) / file.processingFormat.sampleRate
        previewingTitle = title
        isPreviewingCue = true
        // Track base con nombre; BPM/key se rellenan al analizar.
        previewTrack = Track.from(url: url)
        schedulePreview(fromTime: 0)
        startPreviewTimer()
        // Análisis previo en background (BPM/key) → se refleja en previewTrack cuando termina.
        Task { [weak self] in
            guard let self, var t = self.previewTrack else { return }
            await TrackAnalyzer.shared.analyze(track: &t)
            await MainActor.run {
                // Solo aplica si seguimos con la misma pista en preescucha.
                if self.previewURL == url { self.previewTrack = t }
            }
        }
    }

    /// Programa el segmento de preview desde un tiempo dado y (re)arranca la reproducción.
    private func schedulePreview(fromTime time: TimeInterval) {
        guard let file = previewFile else { return }
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(time, previewDuration)) * sr)
        let framesToPlay = AVAudioFrameCount(max(0, file.length - startFrame))
        guard framesToPlay > 0 else { finishCuePreview(); return }
        previewPlayer.stop()
        previewPlayer.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay,
                                      at: nil) { [weak self] in
            Task { @MainActor in self?.previewSegmentFinished() }
        }
        if !engine.isRunning { try? engine.start() }
        previewPlayer.play()
        previewPausedAt = time
        previewHostTime = CACurrentMediaTime()
        previewTime = time
        isPreviewPlaying = true
    }

    /// Play/pause de la preescucha.
    func togglePreviewPlay() {
        guard isPreviewingCue else { return }
        if isPreviewPlaying {
            previewPausedAt = currentPreviewTime()
            previewPlayer.pause()
            isPreviewPlaying = false
        } else {
            previewPlayer.play()
            previewHostTime = CACurrentMediaTime()
            isPreviewPlaying = true
        }
    }

    /// Adelanta/retrocede la preescucha a un tiempo dado (scrub / saltos 25-50-75%).
    func seekCuePreview(to time: TimeInterval) {
        guard isPreviewingCue else { return }
        let wasPlaying = isPreviewPlaying
        schedulePreview(fromTime: max(0, min(time, previewDuration)))
        if !wasPlaying { previewPlayer.pause(); isPreviewPlaying = false }
    }

    /// Detiene la preescucha del canal de cue y limpia el estado.
    func stopCuePreview() {
        if previewPlayer.isPlaying { previewPlayer.stop() }
        previewTimer?.cancel(); previewTimer = nil
        previewFile = nil
        previewURL = nil
        previewTrack = nil
        isPreviewingCue = false
        isPreviewPlaying = false
        previewingTitle = ""
        previewTime = 0
        previewDuration = 0
    }

    /// Posición actual real del preview (base de tiempo + tiempo transcurrido).
    private func currentPreviewTime() -> TimeInterval {
        guard isPreviewPlaying, previewHostTime > 0 else { return previewPausedAt }
        return previewPausedAt + (CACurrentMediaTime() - previewHostTime)
    }

    private func startPreviewTimer() {
        previewTimer?.cancel()
        previewTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isPreviewingCue else { return }
                if self.isPreviewPlaying {
                    self.previewTime = min(self.currentPreviewTime(), self.previewDuration)
                }
            }
    }

    /// El segmento programado llegó al final del archivo.
    private func previewSegmentFinished() {
        // Si de verdad llegamos al final (no fue un stop por seek), marcamos fin.
        if previewTime >= previewDuration - 0.2 { finishCuePreview() }
    }

    /// Fin natural de la preescucha (llegó al final del archivo). Deja el estado listo para
    /// re-escuchar desde el inicio con play, sin cerrar el modal.
    private func finishCuePreview() {
        previewPlayer.stop()
        isPreviewPlaying = false
        previewPausedAt = 0
        previewTime = 0
    }

    /// Borde de un loop para el ajuste fino.
    enum LoopEdge { case loopIn, loopOut }

    /// Ajuste fino de un punto del loop en milisegundos (botones +/−). Mueve `loopStart`
    /// (loopIn) o `loopEnd` (loopOut) con guardas: nunca cruzar el otro borde (mínimo 10 ms
    /// de longitud) ni salir de la pista. Sirve para clavar el loop al beat exacto.
    func nudgeLoopPoint(deck: DeckID, edge: LoopEdge, deltaMs: Double) {
        let d = deck == .left ? deckA : deckB
        guard let dur = d.track?.duration else { return }
        let delta = deltaMs / 1000.0
        let minLen = 0.010   // longitud mínima del loop: 10 ms
        switch edge {
        case .loopIn:
            d.loopStart = min(max(0, d.loopStart + delta), d.loopEnd - minLen)
        case .loopOut:
            d.loopEnd = min(max(d.loopStart + minLen, d.loopEnd + delta), dur)
        }
        saveSession()
    }

    // MARK: - Internos

    private func scheduleFromBeginning(file: AVAudioFile, deck: DeckID) {
        scheduleSegment(file: file, from: 0, deck: deck)
    }

    private func scheduleSegment(file: AVAudioFile, from frame: AVAudioFramePosition, deck: DeckID, at avTime: AVAudioTime? = nil) {
        let player = deck == .left ? playerA : playerB
        let d      = deck == .left ? deckA   : deckB
        guard frame < file.length else { return }

        // Incrementar el token: este es ahora el segmento vigente para este deck.
        let myToken: Int
        if deck == .left { segmentTokenA += 1; myToken = segmentTokenA }
        else             { segmentTokenB += 1; myToken = segmentTokenB }

        // ── MODO STEMS: programar los 4 stem players en la MISMA posición temporal ──
        // El frame se recalcula por archivo (el sample rate del stem puede diferir del
        // original). El callback de fin va solo en el stem 0 (vocals): los 4 duran lo mismo.
        if let stems = stemFiles(for: deck) {
            let time = Double(frame) / file.processingFormat.sampleRate
            let players = stemPlayers(for: deck)
            for (i, stemFile) in stems.enumerated() {
                let sFrame = AVAudioFramePosition(time * stemFile.processingFormat.sampleRate)
                guard sFrame < stemFile.length else { continue }
                let sCount = AVAudioFrameCount(stemFile.length - sFrame)
                if i == StemType.vocal.rawValue {
                    players[i].scheduleSegment(stemFile, startingFrame: sFrame, frameCount: sCount,
                                               at: avTime, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, !d.isLooping else { return }
                            let currentToken = deck == .left ? self.segmentTokenA : self.segmentTokenB
                            guard myToken == currentToken else { return }
                            d.isPlaying = false
                            self.stopTimer(deck: deck)
                            if deck == .left { self.pausedAtA = 0; self.playHostTimeA = 0 }
                            else             { self.pausedAtB = 0; self.playHostTimeB = 0 }
                        }
                    }
                } else {
                    players[i].scheduleSegment(stemFile, startingFrame: sFrame, frameCount: sCount,
                                               at: avTime)
                }
            }
            return
        }

        // ── MODO NORMAL: un solo player con el archivo original ──
        let count = AVAudioFrameCount(file.length - frame)
        player.scheduleSegment(file, startingFrame: frame, frameCount: count, at: avTime,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !d.isLooping else { return }
                // Solo actuar si este sigue siendo el segmento vigente. Si otro stop()/schedule
                // lo reemplazó (load/seek/sync), el token cambió y este callback es obsoleto.
                let currentToken = deck == .left ? self.segmentTokenA : self.segmentTokenB
                guard myToken == currentToken else { return }
                d.isPlaying = false
                self.stopTimer(deck: deck)
                if deck == .left { self.pausedAtA = 0; self.playHostTimeA = 0 }
                else             { self.pausedAtB = 0; self.playHostTimeB = 0 }
            }
        }
    }

    /// Tiempo de audio actual en segundos usando CACurrentMediaTime (siempre funciona)
    private func currentAudioTime(deck: DeckID) -> TimeInterval {
        let pausedAt  = deck == .left ? pausedAtA   : pausedAtB
        let hostStart = deck == .left ? playHostTimeA : playHostTimeB
        let tempo     = deck == .left ? playTempoA  : playTempoB
        guard hostStart > 0 else { return pausedAt }
        let elapsed = (CACurrentMediaTime() - hostStart) * tempo
        return pausedAt + elapsed
    }

    private func updateTimePitch(for deck: DeckChannel) {
        let state  = deck == .left ? deckA  : deckB
        let pitch  = deck == .left ? pitchA : pitchB
        let deckID: DeckID = deck == .left ? .left : .right
        let rate   = max(state.tempo, 0.01)

        pitch.rate = Float(rate)
        pitch.pitch = Self.pitchCents(keyLock: state.keyLock, rate: rate, keyShift: state.keyShift)

        // Actualizar base time para que currentAudioTime no salte al cambiar tempo
        if state.isPlaying {
            let currentT = currentAudioTime(deck: deckID)
            if deck == .left {
                pausedAtA    = currentT
                playHostTimeA = CACurrentMediaTime()
                playTempoA   = rate
            } else {
                pausedAtB    = currentT
                playHostTimeB = CACurrentMediaTime()
                playTempoB   = rate
            }
        }
        saveSession()
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
        deck.filter = snapshot.filter ?? 0
        deck.keyShift = snapshot.keyShift ?? 0

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
            hotCues: deck.hotCues,
            filter: deck.filter,
            keyShift: deck.keyShift
        )
    }

    // MARK: - Timer

    private func startTimer(deck: DeckID) {
        stopTimer(deck: deck)
        let timer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let d   = deck == .left ? self.deckA : self.deckB
                guard let dur = d.track?.duration else { return }

                // Posición usando CACurrentMediaTime (siempre avanza)
                let t = self.currentAudioTime(deck: deck)
                d.currentTime = min(t, dur)

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

                // VU meter REAL: RMS del tap post-fader (attack inmediato, release suave).
                let box = deck == .left ? self.vuBoxA : self.vuBoxB
                let prev = deck == .left ? self.vuLevelA : self.vuLevelB
                let scaled = min(box.value * 2.8, 1.0)   // ganancia visual: RMS musical ~0.1-0.35
                let vu = scaled >= prev ? scaled : prev * 0.80 + scaled * 0.20
                if deck == .left { self.vuLevelA = vu } else { self.vuLevelB = vu }
            }
        if deck == .left { timerA = timer } else { timerB = timer }
    }

    private func stopTimer(deck: DeckID) {
        if deck == .left { timerA = nil; vuLevelA = 0 }
        else             { timerB = nil; vuLevelB = 0 }
    }
}

// MARK: - Auxiliares Ola 2 (thread-safe, viven fuera del @MainActor)

/// Caja thread-safe para pasar el RMS del hilo de render de audio al timer de UI.
final class VULevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Float = 0
    var value: Float {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Escritor de la grabación: el tap del limiter (hilo de render) escribe buffers al WAV.
/// AVAudioFile no es Sendable; este wrapper garantiza que SOLO el hilo del tap lo toca
/// tras la creación (el main solo mantiene/rompe la referencia).
final class StreamRecorder: @unchecked Sendable {
    private let file: AVAudioFile
    init(file: AVAudioFile) { self.file = file }
    func write(_ buffer: AVAudioPCMBuffer) {
        do { try file.write(from: buffer) }
        catch { /* buffer perdido; no parar el render thread por un fallo de disco */ }
    }
}

extension DateFormatter {
    /// "2026-07-11 14.35.02" — apto para nombre de archivo (sin dos puntos).
    static let recordingStamp: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
}
