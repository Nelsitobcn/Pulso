import Foundation

/// Rejilla de beats de una pista. Es el resultado de `TrackAnalyzer` y la fuente de verdad
/// para el SYNC de fase real (no contra t=0). Diseño "robusto y barato" decidido por concilio
/// (Gemini + Codex + Claude) + research NotebookLM (deep, 98 fuentes, jul-2026): Swift puro,
/// Dynamic Programming tipo Ellis 2007, SIN librería externa (aubio/BTrack/QM/Essentia son
/// todas GPL/AGPL → veneno para App Store; ése fue el hallazgo crítico del research).
///
/// Se guarda como array de timestamps reales de cada beat (`beats`, en segundos, tiempo de
/// archivo). El SYNC reconstruye la fase buscando el beat más cercano al playhead. `downbeatIndex`
/// marca cuál de los beats es el "1" del compás (heurística sub-bass + cambio armónico; puede
/// fallar en salsa/funk → la UI debe permitir corregirlo a mano en Sesión 2).
struct BeatGrid: Codable, Equatable {
    /// Timestamps de cada beat detectado, en segundos desde el inicio del archivo. Ordenado.
    var beats: [Double]
    /// Índice dentro de `beats` del primer downbeat fiable (el "1"). `nil` si no se pudo resolver.
    var downbeatIndex: Int?
    /// Beats por compás (4 por defecto, 4/4). El downbeat se repite cada `beatsPerBar`.
    var beatsPerBar: Int
    /// BPM global estimado (mediana de los intervalos entre beats). Para UI y time-stretch.
    var bpm: Double
    /// Confianza 0…1 de la detección (fuerza del pico de autocorrelación normalizada).
    var confidence: Double
    /// `true` si el tempo varía > ~1.5% entre ventanas → el beatgrid dinámico importa de verdad.
    var isVariableTempo: Bool

    init(beats: [Double], downbeatIndex: Int? = nil, beatsPerBar: Int = 4,
         bpm: Double, confidence: Double = 0, isVariableTempo: Bool = false) {
        self.beats = beats
        self.downbeatIndex = downbeatIndex
        self.beatsPerBar = beatsPerBar
        self.bpm = bpm
        self.confidence = confidence
        self.isVariableTempo = isVariableTempo
    }

    /// Timestamp del primer downbeat ("1") fiable, o `nil` si no hay downbeat resuelto.
    var firstDownbeat: Double? {
        guard let i = downbeatIndex, beats.indices.contains(i) else { return nil }
        return beats[i]
    }

    /// Índice del beat más cercano al tiempo dado (segundos). `nil` si no hay beats.
    /// Lo usa la UI "Set Downbeat Here": el DJ pone el playhead en el "1" y fijamos
    /// el downbeat al beat detectado más próximo (no al tiempo exacto del clic).
    func nearestBeatIndex(to time: Double) -> Int? {
        guard !beats.isEmpty else { return nil }
        var best = 0
        var bestDist = abs(beats[0] - time)
        for i in 1..<beats.count {
            let d = abs(beats[i] - time)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// Devuelve una copia con el downbeat fijado al beat más cercano a `time`.
    /// Sube la confianza a 1.0 porque es un ajuste manual del DJ (fuente de verdad).
    func settingDownbeat(nearestTo time: Double) -> BeatGrid {
        guard let i = nearestBeatIndex(to: time) else { return self }
        var copy = self
        copy.downbeatIndex = i
        copy.confidence = 1.0
        return copy
    }
}

struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var artist: String
    var url: URL
    var duration: TimeInterval
    var bpm: Double?
    var key: MusicalKey?
    var energy: Double?       // 0.0 – 1.0
    var genre: String?
    var waveformData: [Float]? // muestras normalizadas para dibujar waveform
    /// Rejilla de beats + downbeat. La calcula `TrackAnalyzer`. El SYNC la usará para alinear
    /// fase real (Sesión 2). `bpm` se mantiene aparte por compatibilidad con UI/sugerencias.
    var beatGrid: BeatGrid?
    var addedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        url: URL,
        duration: TimeInterval = 0,
        bpm: Double? = nil,
        key: MusicalKey? = nil,
        energy: Double? = nil,
        genre: String? = nil,
        waveformData: [Float]? = nil,
        beatGrid: BeatGrid? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.url = url
        self.duration = duration
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.genre = genre
        self.waveformData = waveformData
        self.beatGrid = beatGrid
        self.addedAt = addedAt
    }

    /// Extrae título y artista del nombre de archivo si no hay metadatos
    static func from(url: URL) -> Track {
        let filename = url.deletingPathExtension().lastPathComponent
        let parts = filename.components(separatedBy: " - ")
        let artist = parts.count >= 2 ? parts[0] : "Desconocido"
        let title = parts.count >= 2 ? parts[1...].joined(separator: " - ") : filename
        return Track(title: title, artist: artist, url: url)
    }
}

enum MusicalKey: String, Codable, CaseIterable {
    // Camelot wheel — formato estándar para DJs
    case c1A = "1A", c2A = "2A", c3A = "3A", c4A = "4A"
    case c5A = "5A", c6A = "6A", c7A = "7A", c8A = "8A"
    case c9A = "9A", c10A = "10A", c11A = "11A", c12A = "12A"
    case c1B = "1B", c2B = "2B", c3B = "3B", c4B = "4B"
    case c5B = "5B", c6B = "6B", c7B = "7B", c8B = "8B"
    case c9B = "9B", c10B = "10B", c11B = "11B", c12B = "12B"

    /// Devuelve true si esta key es compatible para mezclar con otra
    func isCompatible(with other: MusicalKey) -> Bool {
        let camelotNumber = self.camelotNumber
        let otherNumber = other.camelotNumber
        let sameType = self.rawValue.hasSuffix("A") == other.rawValue.hasSuffix("A")

        if camelotNumber == otherNumber { return true } // misma key
        let diff = abs(camelotNumber - otherNumber)
        let wrappedDiff = min(diff, 12 - diff)
        return wrappedDiff == 1 && sameType // ±1 en el wheel
    }

    private var camelotNumber: Int {
        let raw = rawValue.dropLast()
        return Int(raw) ?? 0
    }
}
