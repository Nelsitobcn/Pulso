import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.pulso.dj", category: "HotCue")

/// Vista de un deck individual (A o B)
struct DeckView: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var libraryService: LibraryService

    @State private var isDragTarget = false

    var body: some View {
        VStack(spacing: 12) {
            // Cabecera del deck
            DeckHeaderView(deck: deck)

            // Waveform — tap o drag para seek
            WaveformView(deck: deck) { progress in
                let time = (deck.track?.duration ?? 0) * progress
                audioEngine.seek(to: time, deck: deck.id)
            }
            .frame(height: 80)

            HotCuePadsView(deck: deck)

            // Beatgrid: fijar el "1" a mano cuando la heurística falla (salsa/funk)
            DownbeatControlView(deck: deck)

            // Plato giratorio (visual)
            TurntableView(isSpinning: deck.isPlaying)
                .frame(width: 140, height: 140)

            // Controles de transporte
            TransportControlsView(deck: deck)

            // EQ
            EQView(deck: deck)

            // Loop controls
            LoopControlsView(deck: deck)

            // Pitch/tempo
            TempoSliderView(deck: deck)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color("BGDeck"))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            isDragTarget ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
        )
        // Drag & drop: desde biblioteca (UUID como texto) o desde Finder (fileURL/audio)
        .onDrop(of: [.text, .audio, .fileURL], isTargeted: $isDragTarget) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        logger.info("[DROP] deck=\(self.deck.id.rawValue) tipos=\(provider.registeredTypeIdentifiers)")

        // Caso 1: desde la biblioteca — llega el UUID del track como texto plano
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { str, _ in
                guard let idString = str as? String,
                      let uuid = UUID(uuidString: idString) else { return }
                Task { @MainActor in
                    if let track = libraryService.tracks.first(where: { $0.id == uuid }) {
                        logger.info("[DROP] cargando por id: \(track.title)")
                        audioEngine.load(track: track, into: deck.id)
                    }
                }
            }
            return true
        }

        // Caso 2: desde Finder — llega un NSURL
        if provider.canLoadObject(ofClass: NSURL.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { nsurl, _ in
                guard let url = nsurl as? URL else { return }
                Task { @MainActor in
                    if let existingTrack = libraryService.tracks.first(where: { $0.url == url }) {
                        audioEngine.load(track: existingTrack, into: deck.id)
                    } else {
                        let imported = await libraryService.importTracks(urls: [url])
                        if let track = imported.first {
                            audioEngine.load(track: track, into: deck.id)
                        }
                    }
                }
            }
            return true
        }
        // Fallback: fileURL como Data (desde Finder)
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                // Búsqueda similar para Data URLs
                if let existingTrack = libraryService.tracks.first(where: { $0.url == url }) {
                    audioEngine.load(track: existingTrack, into: deck.id)
                } else {
                    let imported = await libraryService.importTracks(urls: [url])
                    if let track = imported.first {
                        audioEngine.load(track: track, into: deck.id)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Subvistas del deck

struct DeckHeaderView: View {
    @ObservedObject var deck: DeckState

    var body: some View {
        HStack {
            // Indicador de deck
            Text("Deck \(deck.id.rawValue)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Spacer()

            // BPM
            VStack(alignment: .center, spacing: 2) {
                Text(deck.bpmDisplay)
                    .font(.system(.title2, design: .monospaced).bold())
                    .foregroundStyle(Color.accentColor)
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Key
            VStack(alignment: .center, spacing: 2) {
                Text(deck.keyDisplay)
                    .font(.system(.title3, design: .monospaced).bold())
                Text("KEY")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        // Título y artista
        if let track = deck.track {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Arrastra una canción aquí")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// Control del downbeat ("1" del compás). El beatgrid lo detecta por heurística
/// sub-bass, que falla en salsa/funk → devuelve `nil`. Aquí el DJ pone el playhead
/// en el "1" real y lo fija a mano; se persiste en la biblioteca y alimenta el SYNC.
struct DownbeatControlView: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var libraryService: LibraryService

    private var grid: BeatGrid? { deck.track?.beatGrid }

    private var statusLabel: String {
        guard let grid else { return "sin analizar" }
        if grid.beats.isEmpty { return "sin beats" }
        if grid.firstDownbeat != nil {
            return grid.confidence >= 1.0 ? "fijado a mano" : "auto"
        }
        return "sin 1"
    }

    private var statusColor: Color {
        guard let grid, !grid.beats.isEmpty else { return .secondary }
        if grid.firstDownbeat == nil { return .orange }
        return grid.confidence >= 1.0 ? .green : .yellow
    }

    var body: some View {
        HStack(spacing: 8) {
            // Fijar el downbeat en la posición actual del playhead
            Button {
                guard let track = deck.track else { return }
                if let updated = libraryService.setDownbeat(trackID: track.id,
                                                            atTime: deck.currentTime) {
                    deck.track = updated  // refresco inmediato del waveform
                }
            } label: {
                Label("SET 1", systemImage: "1.circle.fill")
                    .font(.caption.bold())
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.1))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(grid?.beats.isEmpty ?? true)
            .help("Fijar el \"1\" del compás en la posición actual del playhead")

            // Saltar al downbeat fijado
            Button {
                guard let db = grid?.firstDownbeat else { return }
                audioEngine.seek(to: db, deck: deck.id)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.caption)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.1))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(grid?.firstDownbeat == nil)
            .help("Saltar al \"1\" fijado")

            Spacer()

            // Estado del downbeat
            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(statusColor)
                .monospacedDigit()
        }
    }
}

struct TransportControlsView: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        HStack(spacing: 16) {
            // CUE: reproduciendo → marca; pausado → salta; shift+click → salta y play
            let hasCue = (deck.id == .left ? audioEngine.deckA : audioEngine.deckB)
                .hotCues.contains(where: { $0.index == 0 })
            Button {
                #if os(macOS)
                if NSEvent.modifierFlags.contains(.shift) {
                    audioEngine.jumpToCue(deck: deck.id)
                } else {
                    audioEngine.setCue(deck: deck.id)
                }
                #else
                audioEngine.setCue(deck: deck.id)
                #endif
            } label: {
                Text("CUE")
                    .font(.caption.bold())
                    .frame(width: 48, height: 36)
                    .background(hasCue ? Color.yellow.opacity(0.85) : Color("ButtonCue"))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Play → marca aquí | Pausa → salta al cue | Shift → salta y play")

            Button {
                deck.keyLock.toggle()
            } label: {
                Text("KEY")
                    .font(.caption.bold())
                    .frame(width: 48, height: 36)
                    .background(deck.keyLock ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Bloquear o liberar la tonalidad al cambiar tempo")

            // PLAY / PAUSE
            Button {
                audioEngine.togglePlay(deck: deck.id)
            } label: {
                Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 56, height: 48)
                    .background(deck.isPlaying ? Color.orange : Color.accentColor)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(deck.id == .left ? KeyEquivalent("q") : KeyEquivalent("p"),
                              modifiers: [])

            // SYNC
            Button {
                audioEngine.sync(slave: deck.id)
            } label: {
                Text("SYNC")
                    .font(.caption.bold())
                    .frame(width: 48, height: 36)
                    .background(Color("ButtonSync"))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }
}

struct HotCuePadsView: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                HotCuePad(deck: deck, index: index)
            }
        }
    }
}

struct HotCuePad: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine
    let index: Int

    var cue: HotCue? { deck.hotCues.first(where: { $0.index == index }) }

    var body: some View {
        Button {
            #if os(macOS)
            if NSEvent.modifierFlags.contains(.shift) {
                logger.info("DELETE deck=\(self.deck.id.rawValue) index=\(self.index)")
                audioEngine.deleteHotCue(deck: deck.id, index: index)
            } else if cue != nil {
                logger.info("JUMP deck=\(self.deck.id.rawValue) index=\(self.index) time=\(self.cue!.time)")
                audioEngine.jumpToHotCue(deck: deck.id, index: index)
            } else {
                logger.info("SET deck=\(self.deck.id.rawValue) index=\(self.index) currentTime=\(self.deck.currentTime)")
                audioEngine.setHotCue(deck: deck.id, index: index)
            }
            #else
            if cue != nil {
                audioEngine.jumpToHotCue(deck: deck.id, index: index)
            } else {
                audioEngine.setHotCue(deck: deck.id, index: index)
            }
            #endif
        } label: {
            Text("C\(index + 1)")
                .font(.caption.bold())
                .frame(width: 42, height: 28)
                .background(cue != nil ? cue!.color.swiftUIColor : Color.white.opacity(0.08))
                .foregroundStyle(cue != nil ? Color.white : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(cue != nil ? "Click: saltar | Shift+Click: borrar" : "Click: marcar cue aquí")
    }
}

// MARK: - Loop Controls

struct LoopControlsView: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        HStack(spacing: 8) {
            // Botón LOOP on/off
            Button {
                audioEngine.toggleLoop(deck: deck.id)
            } label: {
                Text("LOOP")
                    .font(.caption.bold())
                    .frame(width: 48, height: 28)
                    .background(deck.isLooping ? Color.accentColor : Color.white.opacity(0.1))
                    .foregroundStyle(deck.isLooping ? .white : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Activar/desactivar loop de 4 beats")

            // Reducir loop a la mitad
            Button {
                audioEngine.scaleLoop(deck: deck.id, factor: 0.5)
            } label: {
                Text("½")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.1))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!deck.isLooping)
            .help("Reducir loop a la mitad")

            // Duplicar loop
            Button {
                audioEngine.scaleLoop(deck: deck.id, factor: 2.0)
            } label: {
                Text("×2")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.1))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!deck.isLooping)
            .help("Doblar duración del loop")

            Spacer()

            // Duración del loop activo
            if deck.isLooping {
                let length = deck.loopEnd - deck.loopStart
                Text(String(format: "%.2fs", length))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct TempoSliderView: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine

    private let range = 0.85...1.15  // ±15% tempo

    var body: some View {
        HStack(spacing: 8) {
            Text("-15%")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Slider(value: $deck.tempo, in: range)
                .tint(Color.accentColor)
                .onChange(of: deck.tempo) { _, newRate in
                    audioEngine.applyTempo(newRate, deck: deck.id)
                }

            Text("+15%")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
