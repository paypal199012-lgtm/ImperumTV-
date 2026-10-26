import SwiftUI
import AVKit

final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var errorMessage: String?

    private var statusObserver: NSKeyValueObservation?
    private var currentURL: URL?

    func play(_ url: URL) {
        currentURL = url
        errorMessage = nil

        // Ton auch bei stummgeschaltetem iPhone abspielen
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
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
        if let url = currentURL { play(url) }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObserver = nil
    }
}

struct PlayerScreen: View {
    let channel: Channel
    let onClose: () -> Void

    @StateObject private var model = PlayerModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: model.player)
                .ignoresSafeArea()

            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(1)
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
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.play(channel.url) }
        .onDisappear { model.stop() }
    }
}
