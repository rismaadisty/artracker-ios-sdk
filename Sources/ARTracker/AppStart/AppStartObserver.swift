#if canImport(UIKit)
import UIKit
import ARTrackerNative

public final class DisplayLinkFirstFrame: FirstFrameHook, @unchecked Sendable {
    private var displayLink: CADisplayLink?
    private var onFrame: (() -> Void)?

    public init() {}

    public func await(_ onFrame: @escaping () -> Void) {
        cancel()
        self.onFrame = onFrame
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    public func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        onFrame = nil
    }

    @objc private func handleTick() {
        let callback = onFrame
        cancel()
        callback?()
    }

    deinit {
        cancel()
    }
}

@MainActor
public final class AppStartObserver {
    private let tracker: AppStartTracker
    private let now: () -> UInt64
    private let frameHook: FirstFrameHook
    private var isInstalled: Bool = false

    public init(
        tracker: AppStartTracker,
        now: @escaping () -> UInt64 = artn_now_ns,
        frameHook: FirstFrameHook = DisplayLinkFirstFrame()
    ) {
        self.tracker = tracker
        self.now = now
        self.frameHook = frameHook
    }

    public func install() {
        guard !isInstalled else { return }
        isInstalled = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidFinishLaunching),
            name: UIApplication.didFinishLaunchingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleDidFinishLaunching() {
        tracker.didFinishLaunching(at: now())
    }

    @objc private func handleDidBecomeActive() {
        tracker.didBecomeActive(at: now())
        if tracker.awaitingFirstFrame {
            frameHook.cancel()
            frameHook.await { [weak self] in
                guard let self = self else { return }
                self.tracker.firstFrame(at: self.now(), screen: Self.topScreenName())
            }
        }
    }

    @objc private func handleWillEnterForeground() {
        tracker.willEnterForeground(at: now())
    }

    @objc private func handleDidEnterBackground() {
        frameHook.cancel()
        tracker.didEnterBackground(at: now())
    }

    public static func topScreenName(window: UIWindow? = nil) -> String? {
        let targetWindow: UIWindow?
        if let w = window {
            targetWindow = w
        } else {
            targetWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }

        guard let root = targetWindow?.rootViewController else { return nil }
        var current: UIViewController = root
        while true {
            if let presented = current.presentedViewController, !presented.isBeingDismissed {
                current = presented
            } else if let nav = current as? UINavigationController, let visible = nav.visibleViewController {
                current = visible
            } else if let tab = current as? UITabBarController, let selected = tab.selectedViewController {
                current = selected
            } else {
                break
            }
        }

        let fullName = NSStringFromClass(type(of: current))
        let parts = fullName.split(separator: ".")
        return parts.last.map(String.init) ?? fullName
    }

    nonisolated public static func launchContext(
        appState: UIApplication.State,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchContext {
        // Priority 1: .active wins over ActivePrewarm=1
        if appState == .active {
            return .activeAlready
        }
        // Priority 2: ActivePrewarm == 1
        if environment["ActivePrewarm"] == "1" {
            return .prewarmed
        }
        // Priority 3: .background
        if appState == .background {
            return .background
        }
        // Priority 4: foreground
        return .foreground
    }
}
#endif
