import Capacitor
import UIKit

// iOS 27 SDK 起,没采用 UIScene 生命周期的 App 启动即被系统终止;窗口由 Info.plist 的 UISceneStoryboardFile 自动创建。
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: context.url, options: [:])
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, continue: userActivity, restorationHandler: { _ in })
    }

}
