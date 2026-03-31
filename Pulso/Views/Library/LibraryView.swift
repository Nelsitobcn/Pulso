import SwiftUI

/// Panel de biblioteca — lista de canciones con búsqueda y drag to deck
struct LibraryView: View {
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var audioEngine: AudioEngine

    @State private var searchQuery = ""
    @State private var sortBy: SortOption = .addedAt

    private var filteredTracks: [Track] {
        let base = libraryService.search(query: searchQuery)
        switch sortBy {
        case .addedAt: return base.sorted { $0.addedAt > $1.addedAt }
        case .title: return base.sorted { $0.title < $1.title }
        case .artist: return base.sorted { $0.artist < $1.artist }
        case .bpm: return base.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        }
    }

    private var suggestions: [Track] {
        if let track = audioEngine.deckA.track {
            return libraryService.suggestions(for: track, currentDeckBPM: track.bpm.map { $0 * audioEngine.deckA.tempo })
        }
        if let track = audioEngine.deckB.track {
            return libraryService.suggestions(for: track, currentDeckBPM: track.bpm.map { $0 * audioEngine.deckB.tempo })
        }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            // Barra de búsqueda y ordenación
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Buscar por título, artista, género...", text: $searchQuery)
                    .textFieldStyle(.plain)

                Divider().frame(height: 16)

                Picker("Ordenar", selection: $sortBy) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Text("\(filteredTracks.count) pistas")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color("BGSecondary"))

            Divider()

            // Cabecera columnas
            LibraryHeaderRow()

            Divider()

            if !suggestions.isEmpty {
                SuggestedTracksView(tracks: Array(suggestions.prefix(5)))
                Divider()
            }

            // Lista de canciones
            if filteredTracks.isEmpty {
                LibraryEmptyView()
            } else {
                List(filteredTracks) { track in
                    LibraryTrackRow(track: track)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color("BGPrimary"))
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case addedAt, title, artist, bpm
        var id: String { rawValue }
        var label: String {
            switch self {
            case .addedAt: return "Reciente"
            case .title: return "Título"
            case .artist: return "Artista"
            case .bpm: return "BPM"
            }
        }
    }
}

struct SuggestedTracksView: View {
    let tracks: [Track]
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sugerencias")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tracks) { track in
                        Button {
                            audioEngine.load(track: track, into: .right)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title)
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(track.bpm.map { String(format: "%.1f BPM", $0) } ?? "Sin BPM")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 180, alignment: .leading)
                            .padding(8)
                            .background(Color("BGSecondary"))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(Color("BGPrimary"))
    }
}

struct LibraryHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("TÍTULO").frame(maxWidth: .infinity, alignment: .leading)
            Text("ARTISTA").frame(width: 140, alignment: .leading)
            Text("BPM").frame(width: 52, alignment: .center)
            Text("KEY").frame(width: 40, alignment: .center)
            Text("DURACIÓN").frame(width: 64, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color("BGSecondary"))
    }
}

struct LibraryTrackRow: View {
    let track: Track
    @EnvironmentObject var audioEngine: AudioEngine
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Título
            Text(track.title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Artista
            Text(track.artist)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            // BPM
            Text(track.bpm.map { String(format: "%.1f", $0) } ?? "—")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, alignment: .center)

            // Key
            Text(track.key?.rawValue ?? "—")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(keyColor(track.key))
                .frame(width: 40, alignment: .center)

            // Duración
            Text(formatDuration(track.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
        // Doble clic → carga en el deck libre (A si vacío, si no B)
        .onTapGesture(count: 2) {
            if audioEngine.deckA.track == nil {
                audioEngine.load(track: track, into: .left)
            } else {
                audioEngine.load(track: track, into: .right)
            }
        }
        .contextMenu {
            Button("Cargar en Deck A") {
                audioEngine.load(track: track, into: .left)
            }
            Button("Cargar en Deck B") {
                audioEngine.load(track: track, into: .right)
            }
        }
        .onDrag {
            NSItemProvider(object: track.url as NSURL)
        }
    }

    private func keyColor(_ key: MusicalKey?) -> Color {
        guard let key else { return .secondary }
        return key.rawValue.hasSuffix("A") ? .cyan : .mint
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "--:--" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct LibraryEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Sin canciones en la biblioteca")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Pulsa + para importar desde tu Mac o arrastra archivos de audio aquí")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
