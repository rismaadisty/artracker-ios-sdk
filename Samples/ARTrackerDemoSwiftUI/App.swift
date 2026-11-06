import SwiftUI
import ARTracker
#if canImport(Wormholy)
import Wormholy
#endif

@main
struct ARTrackerDemoSwiftUIApp: App {
    init() {
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
