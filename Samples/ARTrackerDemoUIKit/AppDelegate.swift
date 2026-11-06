import UIKit
import ARTracker
#if canImport(Wormholy)
import Wormholy
#endif

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Fase A: fast bootstrap <= 2ms
        ARTracker.configure(
            endpoint: "https://artracker.exlm.my.id",
            appKey: "art_live_sniFnfk-QqxQVTcv3fBWWdjZ4XvAohgpgkohADwJA1Q",
            config: ARTrackerConfig(
                environment: "development",
                enableNetworkCapture: true,
                enableViewCapture: true,
                maskAllText: false,
                wifiOnly: false,
                flushInterval: 5,
                debugLogging: true
            )
        )

        window = UIWindow(frame: UIScreen.main.bounds)
        let rootVC = HomeViewController()
        let navController = UINavigationController(rootViewController: rootVC)
        window?.rootViewController = navController
        window?.makeKeyAndVisible()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        ARTracker.handleBackgroundEvents(completionHandler)
    }
}
