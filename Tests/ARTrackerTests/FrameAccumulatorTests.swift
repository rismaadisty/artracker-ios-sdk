import XCTest
@testable import ARTracker

final class FrameAccumulatorTests: XCTestCase {
    func testJankAndFrozenAccumulationAt60Hz() {
        let acc = FrameAccumulator()
        let expected = 1.0 / 60.0

        acc.record(timestamp: 0, expectedInterval: expected, refreshHz: 60)
        acc.record(timestamp: expected, expectedInterval: expected, refreshHz: 60)
        acc.record(timestamp: 2 * expected, expectedInterval: expected, refreshHz: 60)
        acc.record(timestamp: 2 * expected + 0.05, expectedInterval: expected, refreshHz: 60)
        acc.record(timestamp: 2 * expected + 0.05 + 0.8, expectedInterval: expected, refreshHz: 60)

        let window = acc.drain()
        XCTAssertEqual(window, FrameWindow(frames: 4, jank: 2, frozen: 1, refreshHz: 60))
    }

    func testFirstIntervalAfterResetIsIgnored() {
        let acc = FrameAccumulator()
        let expected = 1.0 / 60.0

        acc.record(timestamp: 0, expectedInterval: expected, refreshHz: 60)
        acc.reset()
        acc.record(timestamp: 100, expectedInterval: expected, refreshHz: 60)
        acc.record(timestamp: 100 + expected, expectedInterval: expected, refreshHz: 60)

        let window = acc.drain()
        XCTAssertEqual(window.frames, 1)
        XCTAssertEqual(window.jank, 0)
        XCTAssertEqual(window.frozen, 0)
    }

    func testProMotionRampUpFrom10HzTo120HzIsNotJank() {
        let acc = FrameAccumulator()

        acc.record(timestamp: 0, expectedInterval: 0.1, refreshHz: 120)
        acc.record(timestamp: 0.1, expectedInterval: 1.0 / 120.0, refreshHz: 120)

        let window = acc.drain()
        XCTAssertEqual(window.frames, 1)
        XCTAssertEqual(window.jank, 0)
        XCTAssertEqual(window.frozen, 0)
    }

    func testFrameWindowFpsCalculation() {
        let oneFrame = FrameWindow(frames: 1, jank: 0, frozen: 0, refreshHz: 60)
        XCTAssertNil(oneFrame.fps(elapsedMs: 1000))

        let fiftyEightFrames = FrameWindow(frames: 58, jank: 0, frozen: 0, refreshHz: 60)
        XCTAssertEqual(fiftyEightFrames.fps(elapsedMs: 1000), 58.0)
        XCTAssertNil(fiftyEightFrames.fps(elapsedMs: 0))
    }
}

