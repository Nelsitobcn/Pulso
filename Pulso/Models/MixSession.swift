import Foundation

/// Representa una sesión de mezcla grabada
struct MixSession: Identifiable, Codable {
    let id: UUID
    var name: String
    var date: Date
    var duration: TimeInterval
    var tracklist: [MixEntry]
    var audioFileURL: URL?
    var isExported: Bool = false

    struct MixEntry: Codable, Identifiable {
        let id: UUID
        let trackTitle: String
        let trackArtist: String
        let startTime: TimeInterval // tiempo en la mezcla donde entró esta canción
        let bpm: Double?
        let key: String?
    }
}
