import SwiftUI
import UIKit

/// Erlaubt in der ganzen App nur das Querformat
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CrashReport.install()          // Abstürze an den Admin melden
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }
}

@main
struct IPTVPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Dieselbe Oberfläche wie auf Android/Fire TV (WebApp.swift). Die frühere SwiftUI-Oberfläche (RootView) bleibt im Code.
    var body: some Scene {
        WindowGroup {
            WebRootView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)   // Tippen am oberen Rand (Zurück-Knopf) zuerst an die App
        }
    }
}
