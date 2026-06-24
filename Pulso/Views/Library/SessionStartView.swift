import SwiftUI

/// Panel de bienvenida "¿Qué sesión hoy?" — al abrir la app, el DJ elige un estilo/mood
/// (o escribe el suyo) y la IA local arma la cola de la sesión desde su biblioteca.
struct SessionStartView: View {
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var audioEngine: AudioEngine
    @ObservedObject var assistant: DJAssistantService
    let onClose: () -> Void

    @State private var customMood = ""

    /// Moods rápidos predefinidos.
    private let moods: [(label: String, icon: String, query: String)] = [
        ("Calentamiento", "sunrise", "calentamiento warm-up baja energía chill"),
        ("Salsa / Latino", "music.note", "salsa bachata merengue latino fiesta"),
        ("Peak Time", "flame", "peak time máxima energía pista llena"),
        ("Techno / House", "waveform", "techno house electrónica club"),
        ("Rock / Indie", "guitars", "rock indie alternativo"),
        ("After / Chill", "moon.stars", "after chill downtempo cierre suave")
    ]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("¿Qué sesión montamos hoy?")
                    .font(.title2.bold())
                Text("Elige un estilo y la IA arma la cola desde tu biblioteca")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if libraryService.tracks.isEmpty {
                Label("Tu biblioteca está vacía. Baja canciones de YouTube primero.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            // Moods rápidos en grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(moods, id: \.label) { mood in
                    Button {
                        startSession(mood.query)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: mood.icon).font(.title2)
                            Text(mood.label).font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(assistant.isThinking || libraryService.tracks.isEmpty)
                }
            }

            // Mood libre
            HStack {
                TextField("…o describe tu sesión (ej. 'reggaetón 2024 perreo')", text: $customMood)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !customMood.isEmpty { startSession(customMood) } }
                Button("Montar") { startSession(customMood) }
                    .buttonStyle(.borderedProminent)
                    .disabled(customMood.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isThinking)
            }

            if assistant.isThinking {
                HStack { ProgressView().controlSize(.small); Text("La IA está montando tu sesión…").font(.caption) }
            }

            if let err = assistant.errorText {
                Text(err).font(.caption).foregroundStyle(.orange)
            }

            // Cola generada
            if !assistant.sessionQueue.isEmpty {
                Divider()
                Text("Tu sesión (\(assistant.sessionQueue.count) temas)")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(assistant.sessionQueue.enumerated()), id: \.element.id) { idx, s in
                            HStack(spacing: 8) {
                                Text("\(idx + 1)").font(.caption2.bold()).foregroundStyle(.purple).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.track.title).font(.caption.bold()).lineLimit(1)
                                    Text(s.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)

                Button {
                    // Cargar los 2 primeros en los decks y empezar.
                    if let first = assistant.sessionQueue.first?.track {
                        audioEngine.load(track: first, into: .left)
                    }
                    if assistant.sessionQueue.count > 1 {
                        audioEngine.load(track: assistant.sessionQueue[1].track, into: .right)
                    }
                    onClose()
                } label: {
                    Label("Empezar sesión", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button("Saltar", action: onClose)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func startSession(_ mood: String) {
        let m = mood.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        Task { await assistant.buildSession(mood: m, library: libraryService.tracks) }
    }
}
