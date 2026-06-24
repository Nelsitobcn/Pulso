import SwiftUI

struct ContentView: View {
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var audioEngine: AudioEngine

    @StateObject private var sessionAssistant = DJAssistantService()
    @State private var showSessionStart = true

    var body: some View {
        MainDJView()
            .preferredColorScheme(.dark)
            .overlay {
                if showSessionStart {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        SessionStartView(assistant: sessionAssistant) {
                            withAnimation { showSessionStart = false }
                        }
                        .environmentObject(libraryService)
                        .environmentObject(audioEngine)
                    }
                    .transition(.opacity)
                }
            }
    }
}
