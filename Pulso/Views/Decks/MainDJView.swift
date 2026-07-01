import SwiftUI

/// Vista principal — layout de dos decks + crossfader + biblioteca
struct MainDJView: View {
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var libraryService: LibraryService

    @State private var showLibrary = true
    @State private var isImporting = false
    /// Servicio de YouTube compartido: el TextField vive en LibraryView, pero el panel de
    /// resultados se dibuja aquí como overlay flotante (nivel ventana) para no tapar controles.
    @StateObject private var youtube = YouTubeService()

    var body: some View {
        VStack(spacing: 0) {
            // Barra superior
            TopBarView()
                .padding(.horizontal)
                .padding(.top, 8)

            // Panel central de combinación de ritmo (ondas gemelas A/B + beatgrid + match bar).
            // Solo visible si al menos un deck tiene pista cargada.
            if audioEngine.deckA.track != nil || audioEngine.deckB.track != nil {
                BeatMatchPanelView()
                    .frame(height: 128)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }

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
                    .environmentObject(youtube)
                    .frame(maxHeight: 280)
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Color("BGPrimary").ignoresSafeArea())
        // Panel de resultados de YouTube: OVERLAY FLOTANTE a nivel de ventana, anclado abajo a
        // la derecha, con altura acotada + scroll interno. Se superpone SIN empujar el layout ni
        // tapar los controles de los decks (Play/CUE/faders siempre operativos). Cierre con la X.
        .overlay(alignment: .bottomTrailing) {
            if !youtube.searchResults.isEmpty {
                YouTubeResultsPanel()
                    .environmentObject(youtube)
                    .frame(width: 440)
                    .padding(14)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showLibrary)
        .animation(.easeInOut(duration: 0.2), value: youtube.searchResults.isEmpty)
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
