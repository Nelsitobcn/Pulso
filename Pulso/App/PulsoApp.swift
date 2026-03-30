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
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(authService)
        }
        #endif
    }
}
