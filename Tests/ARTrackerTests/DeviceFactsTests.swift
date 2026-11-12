import XCTest
@testable import ARTracker

final class DeviceFactsTests: XCTestCase {
    func testFreeRamSumsFreeInactiveAndSpeculative() {
        let mb = DeviceFacts.freeRamMb(
            freePages: 10_000,
            inactivePages: 5_000,
            speculativePages: 1_000,
            pageSize: 16_384
        )
        XCTAssertEqual(mb, 250)
        XCTAssertNil(DeviceFacts.freeRamMb(sample: nil))
    }

    func testOsVersionDropsZeroPatch() {
        XCTAssertEqual(DeviceFacts.osVersionString(major: 26, minor: 4, patch: 0), "26.4")
        XCTAssertEqual(DeviceFacts.osVersionString(major: 17, minor: 4, patch: 1), "17.4.1")
    }

    func testMissingCapacitiesOmitStorage() {
        XCTAssertNil(DeviceFacts.storageMb(bytes: nil))
        XCTAssertNil(DeviceFacts.storageMb(bytes: 0))
        XCTAssertNil(DeviceFacts.storageMb(bytes: -1))
        XCTAssertEqual(DeviceFacts.storageMb(bytes: 107_374_182_400), 102_400)
    }

    func testMetricsSystemReadersReturnSensibleValues() throws {
        let ramSample = try XCTUnwrap(Metrics.freeRamBytesSample())
        XCTAssertGreaterThan(ramSample.pageSize, 0)
        XCTAssertGreaterThan(DeviceFacts.freeRamMb(sample: ramSample) ?? 0, 0)

        let storage = Metrics.storageCapacities()
        let total = try XCTUnwrap(DeviceFacts.storageMb(bytes: storage.totalBytes))
        let free = try XCTUnwrap(DeviceFacts.storageMb(bytes: storage.freeBytes))
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(free, 0)
        XCTAssertLessThanOrEqual(free, total)

        XCTAssertFalse(Metrics.osVersion().isEmpty)
    }
}

