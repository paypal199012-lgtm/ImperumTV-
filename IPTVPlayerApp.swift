import SwiftUI

@main
struct IPTVPlayerApp: App {
    @StateObject private var store = PlaylistStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        if store.channels.isEmpty || store.showSetup {
            SetupView()
        } else {
            ChannelListView()
        }
    }
}
