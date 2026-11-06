import Foundation

public final class TerminationDetector: @unchecked Sendable {
    public static let shared = TerminationDetector()

    private let cleanShutdownKey = "id.art.tracker.was_clean_shutdown"
    private let inForegroundKey = "id.art.tracker.was_in_foreground"
    private let hasRunBeforeKey = "id.art.tracker.has_run_before"

    public func markStarted() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: hasRunBeforeKey)
        defaults.set(false, forKey: cleanShutdownKey)
        defaults.set(true, forKey: inForegroundKey)
    }

    public func setInForeground(_ inForeground: Bool) {
        UserDefaults.standard.set(inForeground, forKey: inForegroundKey)
    }

    public func markCleanShutdown() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: cleanShutdownKey)
        defaults.set(false, forKey: inForegroundKey)
    }

    /// Evaluates if the previous process run terminated abnormally while active in foreground.
    /// Returns false on very first launch.
    public func didAbnormallyTerminateInForeground() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: hasRunBeforeKey) else {
            return false
        }
        let clean = defaults.bool(forKey: cleanShutdownKey)
        let wasInForeground = defaults.bool(forKey: inForegroundKey)
        return wasInForeground && !clean
    }
}
