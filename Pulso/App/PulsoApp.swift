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
                    if env["PULSO_AUTO_TEST"] == "1" || env["PULSO_YT_TEST"] == "1" || env["PULSO_BEATGRID_TEST"] == "1" {
                        Task {
                            await autoTestPlayback()
                        }
                    }
                    #endif

                    audioEngine.restoreSession(library: libraryService)
                    // Migrar waveforms del formato viejo (solo canal L, baja res) al nuevo
                    // (pico-a-pico + color). Background, idempotente.
                    libraryService.migrateWaveformsIfNeeded()
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

        // Modo test del beatgrid (Sesión 1, jul-2026): analiza los kicks de BPM conocido en
        // ~/Music/PulsoTest y vuelca la rejilla. Verifica de forma EJECUTABLE que el motor de
        // beatgrid genera beats en las posiciones correctas (cada 60/BPM s) y detecta el BPM.
        if ProcessInfo.processInfo.environment["PULSO_BEATGRID_TEST"] == "1" {
            let testDir = ("~/Music/PulsoTest" as NSString).expandingTildeInPath
            let cases: [(String, Double)] = [("Kick - 120 BPM.wav", 120), ("Kick - 128 BPM.wav", 128)]
            for (file, expected) in cases {
                let url = URL(fileURLWithPath: testDir).appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    NSLog("[Pulso-BEATGRID] FALTA \(file)"); continue
                }
                var track = Track.from(url: url)
                await TrackAnalyzer.shared.analyze(track: &track)
                guard let g = track.beatGrid else {
                    NSLog("[Pulso-BEATGRID] '\(file)' SIN beatGrid (bpm=\(track.bpm ?? -1))"); continue
                }
                let intervals = zip(g.beats.dropFirst(), g.beats).map { $0 - $1 }
                let medInterval = intervals.sorted()[max(0, intervals.count / 2)]
                let bpmFromGrid = intervals.isEmpty ? 0 : 60.0 / medInterval
                let first5 = g.beats.prefix(5).map { String(format: "%.3f", $0) }.joined(separator: ", ")
                NSLog("[Pulso-BEATGRID] '\(file)' esperado=\(expected) | grid.bpm=\(g.bpm) beats=\(g.beats.count) medInterval=\(String(format: "%.4f", medInterval))s ⇒ BPM=\(String(format: "%.1f", bpmFromGrid)) downbeatIdx=\(g.downbeatIndex.map(String.init) ?? "nil") conf=\(String(format: "%.2f", g.confidence)) varTempo=\(g.isVariableTempo)")
                NSLog("[Pulso-BEATGRID]   primeros beats(s): [\(first5)]")
            }
            return
        }

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
