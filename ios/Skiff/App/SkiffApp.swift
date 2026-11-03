import SwiftUI
import UIKit

@main
struct SkiffApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = SendModel()
    @Environment(\.scenePhase) private var scenePhase

    private func takeAction() {
        guard let action = AppDelegate.pendingAction else { return }
        AppDelegate.pendingAction = nil
        model.openScreen(action)
    }

    var body: some Scene {
        WindowGroup {
            SendView(model: model)
                .onOpenURL { model.open(url: $0) }
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.actionNotification)) { _ in takeAction() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { takeAction() } }
                .task { takeAction() }
        }
    }
}

/**
 * The home screen's quick action ("Remote", a long press on Skiff's icon): iOS's nearest thing to Android's Quick
 * Settings tile. Opening skiff://remote does the same (for Shortcuts, Back Tap…).
 */
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var pendingAction: String?
    static let actionNotification = Notification.Name("dev.skiff.action")

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { AppDelegate.pendingAction = AppDelegate.screen(for: item) }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    static func screen(for item: UIApplicationShortcutItem) -> String? {
        item.type.hasSuffix(".remote") ? "remote" : item.type.hasSuffix(".library") ? "library" : nil
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        AppDelegate.pendingAction = AppDelegate.screen(for: shortcutItem)
        NotificationCenter.default.post(name: AppDelegate.actionNotification, object: nil)
        completionHandler(true)
    }
}
