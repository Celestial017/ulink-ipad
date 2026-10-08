import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MirrorViewController()
        window.makeKeyAndVisible()
        self.window = window
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // keep it simple: the stream pauses when the app is backgrounded
    }
}
