import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - QR-Code

enum QRCodeImage {
    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct QRCodeView: View {
    let text: String
    var size: CGFloat = 130

    var body: some View {
        Group {
            if let image = QRCodeImage.make(text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.black)
            }
        }
        .frame(width: size, height: size)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }
}

// MARK: - Rechte Spalte: QR-Code, MAC-Adresse, Geräte-Schlüssel

struct DevicePanel: View {
    @EnvironmentObject private var store: AppStore
    let headline: String
    var showLicense = true

    var body: some View {
        VStack(spacing: 8) {
            if let link = store.deviceLink {
                QRCodeView(text: link.absoluteString)
            }
            Text(headline)
                .font(.footnote)
                .foregroundStyle(Theme.goldLight)
                .multilineTextAlignment(.center)
            if showLicense {
                Text(store.licenseText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(store.isTrial ? Theme.goldLight : .white)
                    .multilineTextAlignment(.center)
                if store.isTrial {
                    Text("Danach \(RemoteConfig.price) einmalig auf der Website aktivieren.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
            }
            Text(RemoteConfig.websiteHost)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.goldLight)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(spacing: 2) {
                Text("MAC-Adresse").font(.caption).foregroundStyle(.white)
                Text(store.macText)
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.goldLight)
                    .textSelection(.enabled)
                Text("Geräte-Schlüssel").font(.caption).foregroundStyle(.white).padding(.top, 4)
                Text(store.deviceKey)
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.goldLight)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Kurzer Startbildschirm

struct StartingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "crown.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.gold)
            ProgressView("Wiedergabelisten werden geladen …")
                .tint(Theme.gold)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GoldBackground(dim: 0.45))
    }
}

// MARK: - Wiedergabelisten (Listen links, QR-Code und Gerätedaten rechts)

struct PlaylistsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var refreshing = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                listSide
                    .frame(width: geo.size.width * 0.62)
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1)
                ScrollView {
                    VStack(spacing: 10) {
                        DevicePanel(headline: "Scanne den QR-Code oder öffne die Website, um eine Wiedergabeliste hinzuzufügen.")
                        buttons
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.black.opacity(0.45))
            }
        }
        .background(GoldBackground(dim: 0.35))
        .task {
            // Neue Listen von der Website erscheinen von selbst
            await store.loadRemote()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await store.loadRemote()
            }
        }
    }

    private var listSide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if !store.channels.isEmpty {
                        Button {
                            store.showSetup = false
                        } label: {
                            Image(systemName: "arrow.left")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Wiedergabelisten")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "crown.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.gold)
                }

                content

                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 0.95, green: 0.6, blue: 0.54))
                        .textSelection(.enabled)
                }

                VStack(spacing: 4) {
                    Text("ImperumTV ist ein Player für deine eigenen Wiedergabelisten")
                        .font(.footnote.weight(.semibold))
                    Text("ImperumTV verkauft keine Inhalte. Bitte frage nicht nach Inhalten.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var content: some View {
        let lists = store.remoteLists ?? []
        if store.remoteLists == nil {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.gold)
                Text("Wiedergabelisten werden geladen …").foregroundStyle(.white)
            }
            .padding(.vertical, 20)
        } else if lists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.remoteError == nil ? "Noch keine Wiedergabeliste" : "Keine Verbindung zur Website")
                    .font(.headline)
                    .foregroundStyle(Theme.goldLight)
                Text(store.remoteError ?? "Öffne die Website (Knopf rechts) oder scanne den QR-Code mit einem anderen Handy. Dort gibst du deine Zugangsdaten ein. Die Wiedergabeliste erscheint danach hier von selbst.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.vertical, 10)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(lists) { playlist in
                    card(playlist)
                }
            }
        }
    }

    private func card(_ playlist: RemotePlaylist) -> some View {
        let connected = playlist.id == store.playlistId && !store.channels.isEmpty
        return Button {
            Task { await store.connect(playlist) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(playlist.address)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack {
                    if connected {
                        Text("Verbunden")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 0.1, green: 0.08, blue: 0.03))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.gold))
                    }
                    Spacer()
                    if store.connectingId == playlist.id {
                        ProgressView().tint(Theme.goldLight)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(connected ? 0.24 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(connected ? Theme.gold : Color.white.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.connectingId != nil || store.isLoading)
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            if let link = store.deviceLink {
                Link(destination: link) {
                    Text("Website öffnen")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                Task {
                    refreshing = true
                    await store.loadRemote()
                    refreshing = false
                }
            } label: {
                HStack(spacing: 6) {
                    if refreshing { ProgressView().controlSize(.small) }
                    Text("Aktualisieren").font(.subheadline)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(refreshing)
        }
    }
}

// MARK: - Testphase abgelaufen

struct LockView: View {
    @EnvironmentObject private var store: AppStore
    @State private var checking = false
    @State private var note: String?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.gold)
                        Text("Deine Testphase ist abgelaufen")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Aktiviere ImperumTV für \(RemoteConfig.price) einmalig. Danach kannst du die App auf diesem Gerät unbegrenzt nutzen, ohne Abo.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                        VStack(alignment: .leading, spacing: 6) {
                            step(1, "Tippe auf „Jetzt aktivieren“. Die Website öffnet sich mit deinen Gerätedaten.")
                            step(2, "Bestätige das Kästchen und bezahle sicher über Stripe.")
                            step(3, "Komm zurück in die App. Nach wenigen Sekunden geht es von selbst weiter.")
                        }
                        Text("Deine Wiedergabelisten bleiben gespeichert.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                        if let note = note {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(Theme.goldLight)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: geo.size.width * 0.6)

                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1)

                ScrollView {
                    VStack(spacing: 10) {
                        DevicePanel(headline: "Oder scanne den QR-Code mit einem anderen Handy.", showLicense: false)
                        if let link = store.deviceLink {
                            Link(destination: link) {
                                Text("Jetzt aktivieren – \(RemoteConfig.price)")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button {
                            Task { await check(manual: true) }
                        } label: {
                            HStack(spacing: 6) {
                                if checking { ProgressView().controlSize(.small) }
                                Text("Ich habe bezahlt").font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(checking)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.black.opacity(0.45))
            }
        }
        .background(GoldBackground(dim: 0.35))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await check(manual: false)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.gold)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.goldLight)
        }
    }

    private func check(manual: Bool) async {
        if manual { checking = true }
        let online = await store.loadRemote()
        if manual {
            checking = false
            if !online {
                note = store.remoteError
            } else if !store.isLicenseActive {
                note = "Noch keine Zahlung angekommen. Das dauert meist nur wenige Sekunden."
            }
        }
    }
}
