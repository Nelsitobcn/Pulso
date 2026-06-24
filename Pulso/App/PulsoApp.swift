import SwiftUI

@main
struct PulsoApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var libraryService = LibraryService()
    @StateObject private var audioEngine = AudioEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .environmentObject(libraryService)
                .environmentObject(audioEngine)
                .onAppear {
                    #if DEBUG
                    let env = ProcessInfo.processInfo.environment
                    if env["PULSO_AUTO_TEST"] == "1" || env["PULSO_YT_TEST"] == "1" {
                        Task {
                            await autoTestPlayback()
                        }
                    }
                    #endif

                    audioEngine.restoreSession(library: libraryService)
                }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(authService)
        }
        #endif
    }

    #if DEBUG
    private func autoTestPlayback() async {
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Modo test del flujo YouTube end-to-end: baja 2 canciones de YouTube, las carga
        // en ambos decks y las reproduce. Verifica descarga→análisis→biblioteca→deck→play
        // sin depender de clics en la UI.
        if ProcessInfo.processInfo.environment["PULSO_YT_TEST"] == "1" {
            let yt = await YouTubeService()
            for (query, deck) in [("lloraras oscar de leon", DeckID.left),
                                  ("la vida es un carnaval celia cruz", DeckID.right)] {
                do {
                    NSLog("[Pulso-YTTEST] bajando: \(query)")
                    let url = try await yt.download(query: query)
                    let imported = await libraryService.importTracks(urls: [url])
                    NSLog("[Pulso-YTTEST] '\(query)' → importadas=\(imported.count) lib=\(libraryService.tracks.count)")
                    if let track = imported.first {
                        audioEngine.load(track: track, into: deck)
                        NSLog("[Pulso-YTTEST] cargada '\(track.title)' bpm=\(track.bpm ?? -1) en deck \(deck.rawValue)")
                    }
                } catch {
                    NSLog("[Pulso-YTTEST] ERROR '\(query)': \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            audioEngine.togglePlay(deck: .left)
            NSLog("[Pulso-YTTEST] PLAY deck A — isPlaying=\(audioEngine.deckA.isPlaying)")
            return
        }

        if let t1 = libraryService.tracks.first {
            audioEngine.load(track: t1, into: .left)
        }
        if libraryService.tracks.count > 1 {
            audioEngine.load(track: libraryService.tracks[1], into: .right)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        audioEngine.togglePlay(deck: .left)
        audioEngine.togglePlay(deck: .right)
    }
    #endif
}
