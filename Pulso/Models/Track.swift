import Foundation

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
