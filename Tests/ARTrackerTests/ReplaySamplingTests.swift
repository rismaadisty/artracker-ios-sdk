import XCTest
@testable import ARTracker

final class ReplaySamplingTests: XCTestCase {
    func testFNV1aHashMatchesCrossPlatformVectors() {
        // Empty string -> offset basis 0x811c9dc5 (2166136261)
        XCTAssertEqual(ReplaySampling.hash32(""), 0x811c9dc5)
        // Deterministic across runs and platforms
        let h1 = ReplaySampling.hash32("ses_0123456789abcdef01234567")
        let h2 = ReplaySampling.hash32("ses_0123456789abcdef01234567:on-error")
        XCTAssertNotEqual(h1, h2)
    }

    func testSamplingBoundaryRates() {
        XCTAssertFalse(ReplaySampling.isSampled(sessionId: "ses_1", rate: 0.0))
        XCTAssertFalse(ReplaySampling.isSampled(sessionId: "ses_1", rate: -0.5))
        XCTAssertFalse(ReplaySampling.isSampled(sessionId: "ses_1", rate: .nan))
        XCTAssertTrue(ReplaySampling.isSampled(sessionId: "ses_1", rate: 1.0))
        XCTAssertTrue(ReplaySampling.isSampled(sessionId: "ses_1", rate: 1.5))
    }

    func testModeSelectionPrecedenceAndSaltedOnErrorId() {
        let always: (String, Double) -> Bool = { _, _ in true }
        let never: (String, Double) -> Bool = { _, _ in false }
        let onlyOnError: (String, Double) -> Bool = { id, _ in id.hasSuffix(ReplayRecordingMode.onErrorSalt) }

        XCTAssertEqual(ReplayRecordingMode.select(sessionId: "s", manual: true, sampleRate: 0, onErrorSampleRate: 0, sampler: never), .full)
        XCTAssertEqual(ReplayRecordingMode.select(sessionId: "s", manual: false, sampleRate: 0.1, onErrorSampleRate: 1.0, sampler: always), .full)
        XCTAssertEqual(ReplayRecordingMode.select(sessionId: "s", manual: false, sampleRate: 0.0, onErrorSampleRate: 1.0, sampler: onlyOnError), .buffer)
        XCTAssertNil(ReplayRecordingMode.select(sessionId: "s", manual: false, sampleRate: 0.0, onErrorSampleRate: 0.0, sampler: never))

        var calls: [(String, Double)] = []
        _ = ReplayRecordingMode.select(sessionId: "s", manual: false, sampleRate: 0.2, onErrorSampleRate: 0.7) { id, r in
            calls.append((id, r))
            return false
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, "s")
        XCTAssertEqual(calls[0].1, 0.2)
        XCTAssertEqual(calls[1].0, "s:on-error")
        XCTAssertEqual(calls[1].1, 0.7)
    }
}
