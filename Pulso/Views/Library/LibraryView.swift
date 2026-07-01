import SwiftUI

/// Panel de biblioteca — lista de canciones con búsqueda y drag to deck
struct LibraryView: View {
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var audioEngine: AudioEngine
    /// Compartido (creado en MainDJView) para que el panel de resultados pueda dibujarse como
    /// overlay flotante a nivel de ventana, sin que lo confine el maxHeight de la biblioteca.
    @EnvironmentObject var youtube: YouTubeService

    @StateObject private var djAssistant = DJAssistantService()
    @State private var searchQuery = ""
    @State private var youtubeError: String?
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
            // ── Búsqueda en YouTube (panel con lista de resultados) ──
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.red)
                    TextField("Buscar canción en YouTube…", text: $youtube.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(searchYouTube)
                        .disabled(youtube.isSearching || youtube.isDownloading)

                    if youtube.isSearching || youtube.isDownloading {
                        ProgressView().controlSize(.small)
                        Text(youtube.statusText)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                    } else {
                        Button(action: searchYouTube) {
                            Label("Buscar", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(youtube.query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                // Canal de preescucha activo (cue) — con su volumen independiente.
                if audioEngine.isPreviewingCue {
                    HStack(spacing: 8) {
                        Image(systemName: "headphones").foregroundStyle(.green)
                        Text("Preescucha: \(audioEngine.previewingTitle)")
                            .font(.caption).lineLimit(1)
                        Image(systemName: "speaker.wave.1.fill").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $audioEngine.previewVolume, in: 0...1)
                            .controlSize(.mini).frame(width: 80)
                        Button("Detener") { audioEngine.stopCuePreview() }
                            .controlSize(.mini)
                    }
                }

                // NOTA: la lista de resultados NO va aquí en el flujo (empujaría el layout y
                // taparía los controles de los decks). Se muestra como overlay flotante — ver
                // `.overlay` al final del body. Así NUNCA altera la escala ni tapa el Play/CUE.

                if let youtubeError {
                    Text(youtubeError)
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.10))

            Divider()

            // Barra de búsqueda local y ordenación
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Filtrar biblioteca local…", text: $searchQuery)
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

            // Caja "Mauri-Bot": cola sugerida por IA local + tendencias globales
            DJAssistantBox(assistant: djAssistant, onSearchTrending: { query in
                youtube.query = query
                searchYouTube()
            }) {
                let deck = audioEngine.deckA.track ?? audioEngine.deckB.track
                guard let current = deck else { return }
                Task { await djAssistant.suggestHybrid(current: current, library: libraryService.tracks) }
            }
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

    /// Pre-escuchar: stream instantáneo de YouTube (sin descargar) para auriculares.
    /// Busca en YouTube y despliega la lista de resultados en el panel.
    private func searchYouTube() {
        let query = youtube.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        youtubeError = nil
        Task {
            do { _ = try await youtube.search(query: query, limit: 8) }
            catch { youtubeError = error.localizedDescription }
        }
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

/// Panel desplegable con la lista de resultados de YouTube. Cada fila: título/artista/duración
/// + preescuchar (canal de cue) + cargar a Deck A / Deck B.
/// Autónomo: usa los servicios por environment y hace preview/carga él mismo. Se dibuja como
/// overlay flotante desde MainDJView (a nivel de ventana) → nunca tapa los controles de deck.
struct YouTubeResultsPanel: View {
    @EnvironmentObject var youtube: YouTubeService
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var libraryService: LibraryService

    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.red)
                Text("\(youtube.searchResults.count) resultados de YouTube")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                if youtube.isDownloading {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button { youtube.searchResults = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Cerrar resultados")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)

            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(youtube.searchResults) { r in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).font(.caption).lineLimit(1)
                                Text(r.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(r.durationText)
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)

                            Button { preview(r) } label: { Image(systemName: "headphones") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(youtube.isDownloading)
                                .help("Preescuchar en el canal de cue")
                            Button { load(r, .left) } label: { Text("A").bold() }
                                .buttonStyle(.bordered).controlSize(.small).disabled(youtube.isDownloading)
                                .help("Cargar al Deck A")
                            Button { load(r, .right) } label: { Text("B").bold() }
                                .buttonStyle(.bordered).controlSize(.small).disabled(youtube.isDownloading)
                                .help("Cargar al Deck B")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 240)     // scroll interno: nunca crece más de esto
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func preview(_ r: YouTubeService.SearchResult) {
        errorText = nil
        Task {
            do {
                let url = try await youtube.download(query: r.videoURL)
                audioEngine.startCuePreview(url: url, title: "\(r.artist) — \(r.title)")
            } catch { errorText = error.localizedDescription }
        }
    }

    private func load(_ r: YouTubeService.SearchResult, _ deck: DeckID) {
        errorText = nil
        Task {
            do {
                audioEngine.stopCuePreview()
                let url = try await youtube.download(query: r.videoURL)
                let imported = await libraryService.importTracks(urls: [url])
                if let track = imported.first { audioEngine.load(track: track, into: deck) }
            } catch { errorText = error.localizedDescription }
        }
    }
}

/// Caja "Mauri-Bot": botón que pide a la IA local la cola de próximas canciones,
/// y muestra cada sugerencia con su motivo. Tocar una la carga en el deck B.
struct DJAssistantBox: View {
    @ObservedObject var assistant: DJAssistantService
    @EnvironmentObject var audioEngine: AudioEngine
    /// Callback cuando el DJ pulsa "buscar en YouTube" en una sugerencia de tendencia no-local.
    var onSearchTrending: (String) -> Void = { _ in }
    let onAsk: () -> Void

    /// Track "On Air" en el que se basan las sugerencias (deck master = el que suena; si ambos
    /// o ninguno, prioriza A). Se muestra para que el DJ sepa sobre qué se sugiere (como Rekordbox).
    private var onAirTrack: Track? {
        if audioEngine.deckA.isPlaying { return audioEngine.deckA.track }
        if audioEngine.deckB.isPlaying { return audioEngine.deckB.track }
        return audioEngine.deckA.track ?? audioEngine.deckB.track
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("DJ IA — ¿qué pongo después?")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if assistant.isThinking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sugerir", action: onAsk)
                        .controlSize(.small)
                }
            }

            // Track On Air en el que se basa (BPM + Key). Como Rekordbox Collection Radar.
            if let air = onAirTrack {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 9)).foregroundStyle(.green)
                    Text("Sobre: \(air.artist) — \(air.title)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    if let b = air.bpm { Text("· \(Int(b)) BPM").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    if let k = air.key { Text("· \(k.rawValue)").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
            }

            if let err = assistant.errorText {
                Text(err).font(.caption2).foregroundStyle(.secondary)
            }

            ForEach(Array(assistant.suggestions.enumerated()), id: \.element.id) { idx, s in
                let isTrending: Bool = {
                    if case .trending = s.origin { return true }; return false
                }()
                HStack(spacing: 8) {
                    // Primera columna: icono de origen (Serato/Rekordbox ponen aquí el logo del
                    // servicio). Tendencia = llama 🔥; local = número de orden.
                    if isTrending {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange).frame(width: 16)
                    } else {
                        Text("\(idx + 1)")
                            .font(.caption2.bold()).foregroundStyle(.purple).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(s.track.title).font(.caption.bold()).lineLimit(1)
                            if isTrending {
                                Text("TOP")
                                    .font(.system(size: 7, weight: .heavy))
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.25))
                                    .foregroundStyle(.orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        Text(s.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    // Tendencia no-local → buscar en YouTube. Local → cargar al Deck B.
                    if case let .trending(query) = s.origin {
                        Button {
                            onSearchTrending(query)
                        } label: {
                            Label("YouTube", systemImage: "magnifyingglass")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    } else {
                        Button {
                            audioEngine.load(track: s.track, into: .right)
                        } label: {
                            Image(systemName: "arrow.right.circle").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Cargar al Deck B")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.07))
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
            // Transferir el UUID del track como texto plano (UTI public.plain-text,
            // reconocido de forma universal y fiable). El deck lo recibe y busca la
            // pista por id. Mucho más robusto que NSItemProvider(object: NSURL),
            // que en macOS/SwiftUI resuelve de forma asíncrona y a menudo falla.
            NSItemProvider(object: track.id.uuidString as NSString)
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
