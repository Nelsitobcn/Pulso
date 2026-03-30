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
        .contextMenu {
            Button("Cargar en Deck A") {
                audioEngine.load(track: track, into: .left)
            }
            Button("Cargar en Deck B") {
                audioEngine.load(track: track, into: .right)
            }
        }
        // Drag para soltar en un deck
        .draggable(track.url.absoluteString)
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
