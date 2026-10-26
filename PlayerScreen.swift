import SwiftUI
import AVKit

final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var errorMessage: String?

    private var statusObserver: NSKeyValueObservation?
    private var currentURL: URL?
    private var currentUserAgent = "IPTVPlayer/3.0"

    func play(_ url: URL, userAgent: String) {
        currentURL = url
        currentUserAgent = userAgent
        errorMessage = nil

        // Ton auch bei stummgeschaltetem iPhone abspielen
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
        )
        let item = AVPlayerItem(asset: asset)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                let reason = item.error?.localizedDescription ?? ""
                DispatchQueue.main.async {
                    self?.errorMessage = "Wiedergabe fehlgeschlagen. \(reason)"
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func retry() {
        if let url = currentURL { play(url, userAgent: currentUserAgent) }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObserver = nil
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()

    let channels: [Channel]
    let isLive: Bool
    @State private var index: Int
    @State private var nowTitle: String?

    init(channels: [Channel], startIndex: Int, isLive: Bool = false) {
        self.channels = channels
        self.isLive = isLive
        _index = State(initialValue: startIndex)
    }

    private var channel: Channel { channels[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: model.player)
                .ignoresSafeArea()

            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .padding(10)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let nowTitle = nowTitle {
                            Text("Jetzt: \(nowTitle)")
                                .font(.caption)
                                .foregroundStyle(Theme.goldLight)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { store.toggleFavorite(channel) } label: {
                        Image(systemName: store.isFavorite(channel) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(store.isFavorite(channel) ? Theme.gold : Color.white)
                            .padding(10)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                Spacer()
                if channels.count > 1 {
                    HStack {
                        stepButton(systemName: "backward.end.fill", delta: -1)
                        Spacer()
                        stepButton(systemName: "forward.end.fill", delta: 1)
                    }
                    .padding(.bottom, 56)
                }
            }
            .foregroundStyle(.white)
            .padding()

            if let message = model.errorMessage {
                VStack(spacing: 12) {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    Button("Erneut versuchen") { model.retry() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.gold)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { model.play(channel.url, userAgent: store.userAgentValue) }
        .onChange(of: index) { _ in
            model.play(channel.url, userAgent: store.userAgentValue)
        }
        .task(id: index) {
            nowTitle = nil
            if isLive && store.isXtream {
                nowTitle = await store.shortEPG(streamId: channel.id).first?.title
            }
        }
        .onDisappear { model.stop() }
    }

    private func stepButton(systemName: String, delta: Int) -> some View {
        Button {
            index = (index + delta + channels.count) % channels.count
        } label: {
            Image(systemName: systemName)
                .font(.title3)
                .padding(14)
                .background(.black.opacity(0.45), in: Circle())
        }
    }
}
