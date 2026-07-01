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

    // Archivo cargado por deck
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?

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
        let nodesA: [AVAudioNode] = [playerA, pitchA, eqA, faderA]
        let nodesB: [AVAudioNode] = [playerB, pitchB, eqB, faderB]
        let nodesPreview: [AVAudioNode] = [previewPlayer, previewMixer]
        (nodesA + nodesB + nodesPreview).forEach { engine.attach($0) }

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
        if deck == .left { pausedAtA = 0 } else { pausedAtB = 0 }

        do {
            let file = try AVAudioFile(forReading: track.url)
            if deck == .left { fileA = file } else { fileB = file }

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
            player.stop()
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
        let player = deck == .left ? playerA : playerB
        player.stop()
        stopTimer(deck: deck)
        if deck == .left { pausedAtA = time } else { pausedAtB = time }
        deckState.currentTime = time
        if wasPlaying {
            startPlayback(from: time, deck: deck)
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

        player.stop()
        scheduleSegment(file: file, from: targetFrame, deck: deck)

        // Reaplicar rate/pitch antes de play para asegurar que está activo
        let rate = max(deckState.tempo, 0.01)
        pitch.rate  = Float(rate)
        pitch.pitch = deckState.keyLock ? 0 : Float(-1200.0 * log2(rate))

        player.play()

        // Registrar el momento de inicio para el timer
        let tempo = deckState.tempo
        if deck == .left {
            pausedAtA    = time
            playHostTimeA = CACurrentMediaTime()
            playTempoA   = tempo
        } else {
            pausedAtB    = time
            playHostTimeB = CACurrentMediaTime()
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
        pitch.pitch = deckState.keyLock ? 0 : Float(-1200.0 * log2(rate))

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
        slavePitch.pitch = slaveDeck.keyLock ? 0 : Float(-1200.0 * log2(newRate))

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

    // MARK: - Preescucha (cue) por canal propio

    /// Reproduce un archivo de audio LOCAL por el canal de preescucha, con volumen propio,
    /// sin mezclarse con los decks. Sustituye la preescucha vieja (AVPlayer suelto que sonaba
    /// mezclado con todo). Pensado para escuchar un candidato antes de cargarlo a un deck.
    func startCuePreview(url: URL, title: String) {
        stopCuePreview()
        guard let file = try? AVAudioFile(forReading: url) else { return }
        previewFile = file
        previewPlayer.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in self?.finishCuePreview() }
        }
        if !engine.isRunning { try? engine.start() }
        previewPlayer.play()
        isPreviewingCue = true
        previewingTitle = title
    }

    /// Detiene la preescucha del canal de cue.
    func stopCuePreview() {
        if previewPlayer.isPlaying { previewPlayer.stop() }
        previewFile = nil
        isPreviewingCue = false
        previewingTitle = ""
    }

    /// Callback al terminar el archivo de preview de forma natural.
    private func finishCuePreview() {
        isPreviewingCue = false
        previewingTitle = ""
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

        let count = AVAudioFrameCount(file.length - frame)
        // Incrementar el token: este es ahora el segmento vigente para este deck.
        let myToken: Int
        if deck == .left { segmentTokenA += 1; myToken = segmentTokenA }
        else             { segmentTokenB += 1; myToken = segmentTokenB }

        // Usar AVAudioTime proporcionado (para sincronización en fase) o nil (inicio inmediato)
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
        pitch.pitch = state.keyLock ? 0 : Float(-1200.0 * log2(rate))

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

                // VU meter: leer outputVolume del fader como proxy de nivel
                let fader = deck == .left ? self.faderA : self.faderB
                let vu = fader.outputVolume
                if deck == .left { self.vuLevelA = vu } else { self.vuLevelB = vu }
            }
        if deck == .left { timerA = timer } else { timerB = timer }
    }

    private func stopTimer(deck: DeckID) {
        if deck == .left { timerA = nil; vuLevelA = 0 }
        else             { timerB = nil; vuLevelB = 0 }
    }
}
