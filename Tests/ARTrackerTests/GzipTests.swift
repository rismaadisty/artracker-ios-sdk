import XCTest
@testable import ARTracker

final class GzipTests: XCTestCase {
    func testGzipCompressionProducesRFC1952MagicBytes() throws {
        let sample = "The quick brown fox jumps over the lazy dog. Repeats for testing compression. ".data(using: .utf8)!
        var payload = Data()
        for _ in 0..<50 {
            payload.append(sample)
        }

        let compressed = try Gzip.compress(data: payload)
        XCTAssertTrue(compressed.count < payload.count)

        // RFC 1952 Magic bytes: 0x1F, 0x8B (checked strictly by Go backend)
        XCTAssertGreaterThanOrEqual(compressed.count, 2)
        XCTAssertEqual(compressed[0], 0x1F, "First byte of gzip stream must be 0x1F")
        XCTAssertEqual(compressed[1], 0x8B, "Second byte of gzip stream must be 0x8B")
        XCTAssertTrue(Gzip.isGzip(data: compressed))
    }

    func testCRC32Checksum() {
        let data = "123456789".data(using: .utf8)!
        let checksum = CRC32.checksum(data: data)
        // Standard CRC32 of "123456789" is 0xCBF43926
        XCTAssertEqual(checksum, 0xCBF43926)
    }
}

