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
            // Bajar varias canciones de salsa para probar BPM (fix x2), SYNC y sugerencias IA.
            let queries = ["lloraras oscar de leon", "vivir mi vida marc anthony",
                           "la vida es un carnaval celia cruz", "suavemente elvis crespo"]
            var loaded: [Track] = []
            for query in queries {
                do {
                    let url = try await yt.download(query: query)
                    let imported = await libraryService.importTracks(urls: [url])
                    if let t = imported.first {
                        loaded.append(t)
                        NSLog("[Pulso-YTTEST] '\(t.title)' bpm=\(t.bpm ?? -1) key=\(t.key?.rawValue ?? "?")")
                    }
                } catch {
                    NSLog("[Pulso-YTTEST] ERROR '\(query)': \(error.localizedDescription)")
                }
            }
            // Cargar las 2 primeras y probar SYNC enlazándolas.
            if loaded.count >= 2 {
                audioEngine.load(track: loaded[0], into: .left)
                audioEngine.load(track: loaded[1], into: .right)
                try? await Task.sleep(nanoseconds: 800_000_000)
                audioEngine.togglePlay(deck: .left)
                audioEngine.togglePlay(deck: .right)
                try? await Task.sleep(nanoseconds: 500_000_000)
                audioEngine.sync(slave: .right)
                NSLog("[Pulso-YTTEST] SYNC: A bpm=\(loaded[0].bpm ?? -1) B bpm=\(loaded[1].bpm ?? -1) B.tempo=\(audioEngine.deckB.tempo)")
            }
            // Probar la sugerencia IA con la canción del deck A.
            if let current = audioEngine.deckA.track {
                let dj = DJAssistantService()
                await dj.suggest(current: current, library: libraryService.tracks)
                for (i, s) in dj.suggestions.enumerated() {
                    NSLog("[Pulso-YTTEST] IA #\(i+1): '\(s.track.title)' — \(s.reason)")
                }
            }
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
