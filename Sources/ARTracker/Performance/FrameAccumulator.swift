import Foundation
import CoreFoundation

struct FrameWindow: Equatable, Sendable {
    let frames: Int
    let jank: Int
    let frozen: Int
    let refreshHz: Double
}

extension FrameWindow {
    func fps(elapsedMs: Double) -> Double? {
        guard frames >= 2, elapsedMs > 0 else { return nil }
        return Double(frames) / (elapsedMs / 1000.0)
    }
}

final class FrameAccumulator: @unchecked Sendable {
    private let lock = UnfairLock()
    private var frames: Int = 0
    private var jank: Int = 0
    private var frozen: Int = 0
    private var lastTimestamp: CFTimeInterval?
    private var lastExpectedInterval: CFTimeInterval?
    private var lastRefreshHz: Double = 0

    func record(timestamp: CFTimeInterval, expectedInterval: CFTimeInterval, refreshHz: Double) {
        lock.withLock {
            lastRefreshHz = refreshHz
            guard let prevTimestamp = lastTimestamp, let prevExpected = lastExpectedInterval else {
                lastTimestamp = timestamp
                lastExpectedInterval = expectedInterval
                return
            }

            let dt = timestamp - prevTimestamp
            lastTimestamp = timestamp
            lastExpectedInterval = expectedInterval

            guard dt >= 0 else { return }

            frames += 1
            let effectiveExpected = max(prevExpected, expectedInterval)
            if effectiveExpected > 0 && dt > 2.0 * effectiveExpected {
                jank += 1
            }
            if dt > 0.7 {
                frozen += 1
            }
        }
    }

    func reset() {
        lock.withLock {
            lastTimestamp = nil
            lastExpectedInterval = nil
        }
    }

    func drain() -> FrameWindow {
        lock.withLock {
            let window = FrameWindow(
                frames: frames,
                jank: jank,
                frozen: frozen,
                refreshHz: lastRefreshHz
            )
            frames = 0
            jank = 0
            frozen = 0
            return window
        }
    }
}

