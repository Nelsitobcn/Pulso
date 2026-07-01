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
    @Published var keyLock: Bool = true
    @Published var hotCues: [HotCue] = []

    /// Zoom de la waveform (1× = pista entera; hasta 32× para colocar el cursor en el drop).
    @Published var waveformZoom: Double = 1.0
    /// Centro de la ventana visible de la waveform, en fracción [0,1] de la pista.
    /// Solo se usa cuando `waveformZoom > 1`. Se auto-sigue al playhead salvo que el usuario
    /// haga scroll manual (lo fija hasta el próximo seek).
    @Published var waveformCenter: Double = 0.0
    /// Si el usuario hizo scroll manual en la onda → no auto-seguir el playhead.
    @Published var waveformManualScroll: Bool = false

    /// Rango visible [inicio, fin] en fracción [0,1] de la pista, dado el zoom y el centro.
    /// A zoom 1× es [0,1]. A más zoom, una ventana estrecha centrada en `waveformCenter`.
    var waveformVisibleRange: (start: Double, end: Double) {
        let z = max(1.0, waveformZoom)
        let win = 1.0 / z                              // ancho de la ventana visible
        let center = waveformManualScroll ? waveformCenter : progress
        var start = center - win / 2
        start = min(max(0, start), 1 - win)            // clamp para no salir de la pista
        return (start, start + win)
    }

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

struct HotCue: Identifiable, Codable, Equatable {
    let id: UUID
    var index: Int
    var time: TimeInterval
    var name: String
    var color: HotCueColor

    init(
        id: UUID = UUID(),
        index: Int,
        time: TimeInterval,
        name: String,
        color: HotCueColor = .blue
    ) {
        self.id = id
        self.index = index
        self.time = time
        self.name = name
        self.color = color
    }
}

enum HotCueColor: String, Codable, CaseIterable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
}

enum DeckID: String, CaseIterable {
    case left = "A"
    case right = "B"
}
