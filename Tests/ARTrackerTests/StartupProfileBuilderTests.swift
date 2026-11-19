import XCTest
@testable import ARTracker
import ARTrackerNative

final class StartupProfileBuilderTests: XCTestCase {
    private func makeImageTable() -> ImageTable {
        let imgA = LoadedImage(
            load: 0x1000,
            textStart: 0x1000,
            textEnd: 0x2000,
            uuid: "AAAA-AAAA-AAAA-AAAA",
            name: "AppLib",
            path: "/private/var/containers/Bundle/Application/123/MyApp.app/Frameworks/AppLib.framework/AppLib",
            isApp: true
        )
        let imgB = LoadedImage(
            load: 0x9000,
            textStart: 0x9000,
            textEnd: 0xA000,
            uuid: "BBBB-BBBB-BBBB-BBBB",
            name: "libsystem_kernel.dylib",
            path: "/usr/lib/system/libsystem_kernel.dylib",
            isApp: false
        )
        let imgC = LoadedImage(
            load: 0xF000,
            textStart: 0xF000,
            textEnd: 0x10000,
            uuid: "CCCC-CCCC-CCCC-CCCC",
            name: "UnusedLib",
            path: "/usr/lib/libunused.dylib",
            isApp: false
        )
        return ImageTable(images: [imgA, imgB, imgC])
    }

    private func build(
        samples: [(UInt64, [UInt])],
        anchor: UInt64 = 1_000_000_000,
        finalIntervalUs: Int = 10_000,
        symbolName: @escaping (UInt) -> String? = { _ in nil }
    ) -> StartupProfile {
        let rawSamples = samples.map { RawSample(tNs: $0.0, framesLeafFirst: $0.1) }
        let raw = RawProfile(finalIntervalUs: finalIntervalUs, meanCostNs: 100_000, samples: rawSamples)
        return StartupProfileBuilder.build(
            raw: raw,
            images: makeImageTable(),
            anchorNs: anchor,
            startId: "start_test_123",
            symbolName: symbolName
        )
    }

    func testDedupesFramesAndStacksRootFirst() {
        // two samples, same leaf-first frames [0x1100, 0x9100, 0x1010]
        let p = build(samples: [(1_010_000_000, [0x1100, 0x9100, 0x1010]), (1_020_000_000, [0x1100, 0x9100, 0x1010])], anchor: 1_000_000_000)
        XCTAssertEqual(p.frames.count, 3)
        XCTAssertEqual(p.stacks, [[0, 1, 2]]) // indexes refer to frames in root-first order: 0x1010, 0x9100, 0x1100
        XCTAssertEqual(p.frames[0].a, "0x1010")
        XCTAssertEqual(p.frames[1].a, "0x9100")
        XCTAssertEqual(p.frames[2].a, "0x1100")
        XCTAssertEqual(p.samples.map(\.t), [10, 20]) // ms since anchor
        XCTAssertEqual(p.samples.map(\.s), [0, 0])
    }

    func testSymOnlyForNonAppImages() {
        let p = build(
            samples: [(1_010_000_000, [0x1100, 0x9100])],
            symbolName: { addr in
                if addr == 0x1100 { return "appSymbol" }
                if addr == 0x9100 { return "sysSymbol" }
                return nil
            }
        )
        // Root-first: 0x9100 (non-app), then 0x1100 (app)
        let frame9100 = p.frames.first(where: { $0.a == "0x9100" })
        let frame1100 = p.frames.first(where: { $0.a == "0x1100" })
        XCTAssertEqual(frame9100?.sym, "sysSymbol")
        XCTAssertNil(frame1100?.sym)
    }

    func testImagesOnlyThoseReferenced() {
        // 0x1100 is in imgA, 0x9100 is in imgB. imgC is not referenced.
        let p = build(samples: [(1_010_000_000, [0x1100, 0x9100])])
        XCTAssertEqual(p.images.count, 2)
        XCTAssertEqual(p.images.map(\.name).sorted(), ["AppLib", "libsystem_kernel.dylib"])
        for frame in p.frames {
            if let idx = frame.i {
                XCTAssertLessThan(idx, p.images.count)
            }
        }
    }

    func testAddressOutsideAnyImageHasNoIndex() {
        let p = build(samples: [(1_010_000_000, [0x5000])])
        XCTAssertEqual(p.frames.count, 1)
        XCTAssertEqual(p.frames[0].a, "0x5000")
        XCTAssertNil(p.frames[0].i)
        XCTAssertEqual(p.images.count, 0)
    }

    func testIntervalMsFromFinalInterval() {
        let p = build(samples: [(1_010_000_000, [0x1100])], finalIntervalUs: 20_000)
        XCTAssertEqual(p.intervalMs, 20)
    }

    func testJSONKeysMatchWireContract() throws {
        let p = build(samples: [(1_010_000_000, [0x1100])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(p)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Not a json object")
            return
        }
        let keys = Array(json.keys).sorted()
        XCTAssertEqual(keys, ["frames", "images", "interval_ms", "platform", "samples", "stacks", "start_id", "t0", "v"])
    }

    func testRealImageTableFindsTestFunction() {
        let table = ImageTable.current(bundlePath: "/")
        let cFunc: @convention(c) () -> Void = {}
        let testFuncPtr = unsafeBitCast(cFunc, to: UInt.self)
        let idx = table.index(of: testFuncPtr)
        XCTAssertNotNil(idx)
        if let i = idx {
            let img = table.images[i]
            XCTAssertNotNil(img.uuid)
            XCTAssertFalse(img.uuid!.isEmpty)
        }
    }
}
