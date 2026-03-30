import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    func importTracks(urls: [URL]) async {
        isAnalyzing = true
        analysisProgress = 0

        var newTracks: [Track] = []

        for (index, url) in urls.enumerated() {
            // Evitar duplicados por URL
            guard !tracks.contains(where: { $0.url == url }) else { continue }

            // Solicitar acceso al archivo si está fuera del sandbox
            _ = url.startAccessingSecurityScopedResource()

            var track = Track.from(url: url)

            // Leer metadatos ID3/M4A
            await enrichMetadata(track: &track)

            // Analizar BPM y waveform
            await TrackAnalyzer.shared.analyze(track: &track)

            newTracks.append(track)
            url.stopAccessingSecurityScopedResource()

            analysisProgress = Double(index + 1) / Double(urls.count)
        }

        tracks.append(contentsOf: newTracks)
        saveToDisk()
        isAnalyzing = false
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

    // MARK: - Metadatos

    private func enrichMetadata(track: inout Track) async {
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

    // MARK: - Persistencia local (JSON en Application Support)

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pulso", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    private func saveToDisk() {
        // No guardar waveformData en disco para ahorrar espacio (se recalcula)
        let slim = tracks.map { t -> Track in
            var copy = t
            copy.waveformData = nil
            return copy
        }
        if let data = try? JSONEncoder().encode(slim) {
            try? data.write(to: storageURL)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = loaded
    }
}

import AVFoundation
