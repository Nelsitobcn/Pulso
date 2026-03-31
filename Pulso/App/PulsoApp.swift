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
                    if ProcessInfo.processInfo.environment["PULSO_AUTO_TEST"] == "1" {
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
