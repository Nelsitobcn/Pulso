import Foundation
import Combine

/// Estado observable de un deck de DJ
@MainActor
final class DeckState: ObservableObject, Identifiable {
    let id: DeckID

    @Published var track: Track?
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var tempo: Double = 1.0          // pitch/tempo multiplicador (1.0 = original)
    @Published var volume: Double = 1.0          // 0.0 – 1.0
    @Published var eqLow: Double = 0.0           // -1.0 a +1.0 (kill = -1.0)
    @Published var eqMid: Double = 0.0
    @Published var eqHigh: Double = 0.0
    @Published var isLooping: Bool = false
    @Published var loopStart: TimeInterval = 0
    @Published var loopEnd: TimeInterval = 0
    @Published var cuePoint: TimeInterval?

    // Stems
    @Published var stemVocalMuted: Bool = false
    @Published var stemBassMuted: Bool = false
    @Published var stemDrumsMuted: Bool = false
    @Published var stemMelodyMuted: Bool = false

    var bpmDisplay: String {
        guard let bpm = track?.bpm else { return "---" }
        return String(format: "%.1f", bpm * tempo)
    }

    var keyDisplay: String {
        track?.key?.rawValue ?? "---"
    }

    var progress: Double {
        guard let duration = track?.duration, duration > 0 else { return 0 }
        return currentTime / duration
    }

    init(id: DeckID) {
        self.id = id
    }
}

enum DeckID: String, CaseIterable {
    case left = "A"
    case right = "B"
}
