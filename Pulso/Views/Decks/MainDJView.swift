import SwiftUI

/// Vista principal — layout de dos decks + crossfader + biblioteca
struct MainDJView: View {
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var libraryService: LibraryService

    @State private var showLibrary = true
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            // Barra superior
            TopBarView()
                .padding(.horizontal)
                .padding(.top, 8)

            Divider()

            // Decks
            HStack(alignment: .top, spacing: 0) {
                // Deck A
                DeckView(deck: audioEngine.deckA)
                    .frame(maxWidth: .infinity)

                // Centro: crossfader + controles master
                CenterControlsView()
                    .frame(width: 180)

                // Deck B
                DeckView(deck: audioEngine.deckB)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)

            Divider()

            // Biblioteca (colapsable)
            if showLibrary {
                LibraryView()
                    .frame(maxHeight: 280)
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Color("BGPrimary").ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: showLibrary)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation { showLibrary.toggle() }
                } label: {
                    Label("Biblioteca", systemImage: "music.note.list")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    isImporting = true
                } label: {
                    Label("Importar", systemImage: "plus.circle")
                }
            }
            #endif
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await libraryService.importTracks(urls: urls) }
            }
        }
    }
}
