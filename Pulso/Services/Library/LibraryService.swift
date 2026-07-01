import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Gestiona la biblioteca local de canciones del DJ
@MainActor
final class LibraryService: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var isAnalyzing: Bool = false
    @Published var analysisProgress: Double = 0

    private let storageKey = "pulso_library_tracks"

    init() {
        loadFromDisk()
    }

    // MARK: - Importar canciones

    func importTracks(urls: [URL]) async -> [Track] {
        isAnalyzing = true
        analysisProgress = 0

        guard !urls.isEmpty else {
            isAnalyzing = false
            return []
        }

        let existingTracks = tracks
        var importedTracks: [Track] = []
        var pendingURLs: [URL] = []

        for url in urls {
            if let existing = existingTracks.first(where: { $0.url == url }) {
                importedTracks.append(existing)
            } else {
                pendingURLs.append(url)
            }
        }

        var processedCount = importedTracks.count

        if !pendingURLs.isEmpty {
            var queue = Array(pendingURLs.enumerated())
            await withTaskGroup(of: (Int, Track?).self) { group in
                let initialCount = min(3, queue.count)
                for _ in 0..<initialCount {
                    let (index, url) = queue.removeFirst()
                    group.addTask {
                        (index, await Self.processSingleTrack(url: url))
                    }
                }

                while let (_, track) = await group.next() {
                    if let track {
                        importedTracks.append(track)
                        tracks.append(track)
                    }

                    processedCount += 1
                    analysisProgress = Double(processedCount) / Double(urls.count)

                    if !queue.isEmpty {
                        let (nextIndex, nextURL) = queue.removeFirst()
                        group.addTask {
                            (nextIndex, await Self.processSingleTrack(url: nextURL))
                        }
                    }
                }
            }
            importedTracks.sort { lhs, rhs in
                let lhsIndex = urls.firstIndex(of: lhs.url) ?? .max
                let rhsIndex = urls.firstIndex(of: rhs.url) ?? .max
                return lhsIndex < rhsIndex
            }
        } else {
            analysisProgress = 1
        }

        saveToDisk()
        isAnalyzing = false
        return importedTracks
    }

    func removeTrack(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        saveToDisk()
    }

    // MARK: - Búsqueda y filtrado

    func search(query: String) -> [Track] {
        guard !query.isEmpty else { return tracks }
        let q = query.lowercased()
        return tracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            ($0.genre?.lowercased().contains(q) ?? false)
        }
    }

    func compatibleTracks(with track: Track) -> [Track] {
        guard let key = track.key else { return [] }
        return tracks.filter { t in
            t.id != track.id &&
            (t.key?.isCompatible(with: key) ?? false)
        }
    }

    func suggestions(for track: Track, currentDeckBPM: Double?) -> [Track] {
        let baseBPM = currentDeckBPM ?? track.bpm

        return tracks
            .filter { candidate in
                guard candidate.id != track.id else { return false }

                let harmonicMatch: Bool
                if let trackKey = track.key, let candidateKey = candidate.key {
                    harmonicMatch = candidateKey.isCompatible(with: trackKey)
                } else {
                    harmonicMatch = true
                }

                let bpmMatch: Bool
                if let baseBPM, let candidateBPM = candidate.bpm {
                    let doubled = candidateBPM * 2
                    let halved = candidateBPM / 2
                    let variants = [candidateBPM, doubled, halved]
                    bpmMatch = variants.contains { abs($0 - baseBPM) / max(baseBPM, 1) <= 0.10 }
                } else {
                    bpmMatch = true
                }

                return harmonicMatch && bpmMatch
            }
            .sorted { ($0.energy ?? 0) > ($1.energy ?? 0) }
    }

    // MARK: - Metadatos

    private nonisolated static func enrichMetadata(track: inout Track) async {
        let asset = AVURLAsset(url: track.url)
        let metadata = try? await asset.load(.commonMetadata)

        for item in metadata ?? [] {
            switch item.commonKey {
            case .commonKeyTitle:
                if let title = try? await item.load(.stringValue), !title.isEmpty {
                    track.title = title
                }
            case .commonKeyArtist:
                if let artist = try? await item.load(.stringValue), !artist.isEmpty {
                    track.artist = artist
                }
            default:
                break
            }
        }
    }

    private nonisolated static func processSingleTrack(url: URL) async -> Track? {
        let needsStopAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsStopAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var track = Track.from(url: url)
        await enrichMetadata(track: &track)
        await TrackAnalyzer.shared.analyze(track: &track)
        return track
    }

    // MARK: - Migración de waveform (formato viejo → pico-a-pico + color)

    /// Re-analiza en background las pistas cuyo waveform está en el formato viejo (sin
    /// `waveformDetail`). Rápido en Apple Silicon. Persiste al terminar cada una. Idempotente.
    /// Llamar al arrancar la app.
    func migrateWaveformsIfNeeded() {
        let pending = tracks.filter { $0.waveformDetail == nil }
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            for track in pending {
                guard FileManager.default.fileExists(atPath: track.url.path) else { continue }
                var t = track
                await TrackAnalyzer.shared.analyze(track: &t)
                if let idx = tracks.firstIndex(where: { $0.id == t.id }) {
                    tracks[idx] = t
                }
                saveToDisk()   // persistir tras cada una (no perder progreso si algo falla)
            }
        }
    }

    /// Devuelve la versión más reciente (ya migrada) de un track si existe en la biblioteca.
    func current(_ track: Track) -> Track {
        tracks.first(where: { $0.id == track.id }) ?? track
    }

    // MARK: - Edición del beatgrid (UI "Set Downbeat Here")

    /// Fija el downbeat del track al beat más cercano a `time` (segundos) y persiste.
    /// Devuelve el track actualizado (para refrescar el deck de inmediato) o `nil`
    /// si el track no está en la biblioteca o no tiene beatgrid analizado.
    @discardableResult
    func setDownbeat(trackID: UUID, atTime time: TimeInterval) -> Track? {
        guard let idx = tracks.firstIndex(where: { $0.id == trackID }),
              let grid = tracks[idx].beatGrid else { return nil }
        tracks[idx].beatGrid = grid.settingDownbeat(nearestTo: time)
        saveToDisk()
        return tracks[idx]
    }

    // MARK: - Persistencia local (JSON en Application Support)

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pulso", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(tracks) {
            try? data.write(to: storageURL)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        // Intentar con secondsSince1970 (formato actual) y iso8601 (formato viejo)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let loaded = try? decoder.decode([Track].self, from: data) {
            tracks = loaded
            return
        }
        let decoder2 = JSONDecoder()
        decoder2.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder2.decode([Track].self, from: data) {
            tracks = loaded
            saveToDisk() // re-guardar en formato nuevo
        }
    }
}
