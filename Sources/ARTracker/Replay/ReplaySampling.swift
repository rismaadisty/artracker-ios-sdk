import Foundation

/// Per-session replay sampling matching Android (`Sampling.kt`) and Web (`sampling.ts`):
/// FNV-1a 32-bit hash over UTF-16 code units, divided by 2^32.
public enum ReplaySampling {
    private static let offsetBasis: UInt32 = 0x811c9dc5
    private static let prime: UInt32 = 0x01000193
    private static let twoPow32: Double = 4_294_967_296.0

    public static func isSampled(sessionId: String, rate: Double) -> Bool {
        guard rate.isFinite else { return false }
        if rate >= 1.0 { return true }
        if !(rate > 0.0) { return false }
        return Double(hash32(sessionId)) / twoPow32 < rate
    }

    public static func hash32(_ s: String) -> UInt32 {
        var h = offsetBasis
        for codeUnit in s.utf16 {
            h ^= UInt32(codeUnit)
            h = h &* prime
        }
        return h
    }
}

public enum ReplayRecordingMode: String, Sendable, Equatable {
    case full
    case buffer

    public static let onErrorSalt = ":on-error"

    /// Selects the recording mode for a session, or nil if the session should not be recorded.
    public static func select(
        sessionId: String,
        manual: Bool = false,
        sampleRate: Double,
        onErrorSampleRate: Double,
        sampler: (String, Double) -> Bool = ReplaySampling.isSampled
    ) -> ReplayRecordingMode? {
        if manual { return .full }
        if sampler(sessionId, sampleRate) { return .full }
        if sampler(sessionId + onErrorSalt, onErrorSampleRate) { return .buffer }
        return nil
    }
}
