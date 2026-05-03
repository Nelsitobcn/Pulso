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

            // FX rows estilo VirtualDJ (visual only — preparado para Fase 2)
            FXRowsView()

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
        // Intentar primero como NSURL (viene de onDrag con NSItemProvider(object: NSURL))
        if provider.canLoadObject(ofClass: NSURL.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { nsurl, _ in
                guard let url = nsurl as? URL else { return }
                Task { @MainActor in
                    let imported = await libraryService.importTracks(urls: [url])
                    if let track = imported.first {
                        audioEngine.load(track: track, into: deck.id)
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

            // TEST TEMPO — pulsa para oír si AVAudioUnitTimePitch funciona
            Button {
                Task {
                    audioEngine.testSetRate(1.5, deck: deck.id)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    audioEngine.testSetRate(1.0, deck: deck.id)
                }
            } label: {
                Text("T")
                    .font(.caption.bold())
                    .frame(width: 28, height: 36)
                    .background(Color.red.opacity(0.7))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("TEST: acelera 2s y vuelve — confirma si TimePitch funciona")
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

// MARK: - FX Rows estilo VirtualDJ

/// 3 filas de FX (ECHO / STEMS / BRAKESTART) cada una con dropdown + 3 mini-knobs
struct FXRowsView: View {
    @State private var fxEcho1: Double = 0
    @State private var fxEcho2: Double = 0
    @State private var fxEcho3: Double = 0
    @State private var fxStems1: Double = 0
    @State private var fxStems2: Double = 0
    @State private var fxStems3: Double = 0
    @State private var fxBrake1: Double = 0
    @State private var fxBrake2: Double = 0
    @State private var fxBrake3: Double = 0

    @State private var selectedFX1 = "ECHO"
    @State private var selectedFX2 = "STEMS"
    @State private var selectedFX3 = "BRAKE"

    var body: some View {
        VStack(spacing: 4) {
            fxRow(label: selectedFX1, options: ["ECHO", "REVERB", "FILTER", "FLANGER"], onSelect: { selectedFX1 = $0 },
                  k1: $fxEcho1, k2: $fxEcho2, k3: $fxEcho3, color: .cyan)

            fxRow(label: selectedFX2, options: ["STEMS", "PITCH", "BEAT"], onSelect: { selectedFX2 = $0 },
                  k1: $fxStems1, k2: $fxStems2, k3: $fxStems3, color: .mint)

            fxRow(label: selectedFX3, options: ["BRAKE", "BRAKESTART", "LOOP", "ROLL"], onSelect: { selectedFX3 = $0 },
                  k1: $fxBrake1, k2: $fxBrake2, k3: $fxBrake3, color: .purple)
        }
    }

    private func fxRow(label: String, options: [String], onSelect: @escaping (String) -> Void,
                       k1: Binding<Double>, k2: Binding<Double>, k3: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button(opt) { onSelect(opt) }
                }
            } label: {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
                    .frame(width: 56, height: 22)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .menuStyle(.borderlessButton)

            MiniKnob(value: k1, color: color)
            MiniKnob(value: k2, color: color)
            MiniKnob(value: k3, color: color)
        }
    }
}

/// Mini knob 24x24 para FX (sin label)
struct MiniKnob: View {
    @Binding var value: Double  // -1.0 a +1.0
    let color: Color

    @State private var lastDragY: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 2)
                .frame(width: 24, height: 24)

            Circle()
                .trim(from: 0.1, to: max(0.105, 0.1 + 0.8 * ((value + 1) / 2)))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(-225))

            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5, height: 7)
                .offset(y: -6)
                .rotationEffect(.degrees(value * 135))
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        lastDragY = drag.location.y
                        return
                    }
                    let delta = Double(lastDragY - drag.location.y) / 60.0
                    lastDragY = drag.location.y
                    value = max(-1.0, min(1.0, value + delta))
                }
                .onEnded { _ in
                    isDragging = false
                    lastDragY = 0
                }
        )
        .onLongPressGesture(minimumDuration: 0.5) {
            value = 0
        }
    }
}
