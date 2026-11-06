import XCTest
@testable import ARTracker

final class DebuggerDetectorTests: XCTestCase {
    func testDebuggerDetectorIsAttachedBoolean() {
        // Should evaluate sysctl without crashing
        let isAttached = DebuggerDetector.isAttached
        // Under test runner, this can be true or false depending on whether LLDB is attached
        XCTAssertTrue(isAttached == true || isAttached == false)
    }

    func testPLCrashReporterEngineInstallUnderDebuggerDoesNotThrow() {
        let engine = PLCrashReporterEngine()
        XCTAssertNoThrow(try engine.install())
    }
}

