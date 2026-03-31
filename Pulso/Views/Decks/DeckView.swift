import SwiftUI
import UniformTypeIdentifiers

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
        // Drag & drop desde Finder o biblioteca
        .onDrop(of: [.audio, .fileURL], isTargeted: $isDragTarget) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                let imported = await libraryService.importTracks(urls: [url])
                if let track = imported.first {
                    audioEngine.load(track: track, into: deck.id)
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

struct TransportControlsView: View {
    @ObservedObject var deck: DeckState
    @EnvironmentObject var audioEngine: AudioEngine

    var body: some View {
        HStack(spacing: 16) {
            // CUE
            Button {
                #if os(macOS)
                if NSEvent.modifierFlags.contains(.shift) {
                    audioEngine.setCue(deck: deck.id)
                } else {
                    audioEngine.jumpToCue(deck: deck.id)
                }
                #else
                audioEngine.jumpToCue(deck: deck.id)
                #endif
            } label: {
                Text("CUE")
                    .font(.caption.bold())
                    .frame(width: 48, height: 36)
                    .background(Color("ButtonCue"))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Click: ir al cue | Shift+Click: marcar cue")

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
                let cue = deck.hotCues.first(where: { $0.index == index })
                Button {
                    if cue != nil {
                        audioEngine.jumpToHotCue(deck: deck.id, index: index)
                    } else {
                        audioEngine.setHotCue(deck: deck.id, index: index)
                    }
                } label: {
                    Text("C\(index + 1)")
                        .font(.caption.bold())
                        .frame(width: 42, height: 28)
                        .background(backgroundColor(for: cue))
                        .foregroundStyle(foregroundColor(for: cue))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onLongPressGesture {
                    audioEngine.setHotCue(deck: deck.id, index: index)
                }
                .help("Click: ir al hot cue | Long press: guardar posición actual")
            }
        }
    }

    private func backgroundColor(for cue: HotCue?) -> Color {
        if let cue {
            return cue.color.swiftUIColor
        }
        return Color.white.opacity(0.08)
    }

    private func foregroundColor(for cue: HotCue?) -> Color {
        cue == nil ? .secondary : .white
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

    private let range = 0.85...1.15  // ±15% tempo

    var body: some View {
        HStack(spacing: 8) {
            Text("-15%")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Slider(value: $deck.tempo, in: range)
                .tint(Color.accentColor)

            Text("+15%")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
