import XCTest
@testable import ARTracker

private final class StubProfileURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ProfileUploaderTests: XCTestCase {
    private var tempDir: URL!
    private var session: URLSession!
    private var store: ProfileStore!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_uploader_\(UUID().uuidString)")
        store = ProfileStore(directory: tempDir)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProfileURLProtocol.self]
        session = URLSession(configuration: config)
        StubProfileURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        StubProfileURLProtocol.requestHandler = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testPostsGzipToProfilesEndpointWithHeaders() throws {
        let endpoint = URL(string: "https://ingest.artracker.io")!
        let appKey = "test_key_123"

        let profile = StartupProfile(
            v: 1,
            startId: "start_test_1",
            platform: "ios",
            intervalMs: 10,
            t0: "2026-11-19T10:00:00.000Z",
            images: [],
            frames: [ProfileFrame(a: "0x1000", i: nil, sym: "test")],
            stacks: [[0]],
            samples: [ProfileSample(t: 10, s: 0)]
        )
        let env = ProfileEnvelope(
            sdk: .current,
            context: ProfileContext(app_version: "1.2.3", build: "45", environment: "staging"),
            profile: profile
        )
        let gzippedData = try ProfileBody.gzip(env)
        try store.save(startId: "start_test_1", body: gzippedData)

        let exp = expectation(description: "Upload completed")
        var capturedRequest: URLRequest?

        StubProfileURLProtocol.requestHandler = { request in
            capturedRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }

        let uploader = ProfileUploader(
            endpoint: endpoint,
            appKey: appKey,
            store: store,
            session: session,
            canUpload: { true }
        )

        uploader.flush {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)

        guard let req = capturedRequest else {
            XCTFail("Request was not sent")
            return
        }

        XCTAssertEqual(req.url?.path, "/api/v1/app-start/profiles")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Artracker-Key"), appKey)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "\(SDKInfo.current.name)/\(SDKInfo.current.version)")

        // Gunzip body and verify JSON structure
        var bodyData = req.httpBody
        if bodyData == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            stream.close()
            bodyData = data
        }

        let decompressed = try Gzip.decompress(data: try XCTUnwrap(bodyData))
        let json = try JSONSerialization.jsonObject(with: decompressed) as? [String: Any]
        XCTAssertNotNil(json?["context"])
        XCTAssertNotNil(json?["profile"])
        XCTAssertNotNil(json?["sdk"])
    }

    func test2xxDeletesFile() throws {
        let endpoint = URL(string: "https://ingest.artracker.io")!
        try store.save(startId: "start_2xx", body: "dummy".data(using: .utf8)!)

        let exp = expectation(description: "Upload completed")
        StubProfileURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }

        let uploader = ProfileUploader(
            endpoint: endpoint,
            appKey: "key",
            store: store,
            session: session,
            canUpload: { true }
        )

        uploader.flush {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(store.pending().count, 0)
    }

    func test413DeletesFile() throws {
        let endpoint = URL(string: "https://ingest.artracker.io")!
        try store.save(startId: "start_413", body: "dummy".data(using: .utf8)!)

        let exp = expectation(description: "Upload completed")
        StubProfileURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }

        let uploader = ProfileUploader(
            endpoint: endpoint,
            appKey: "key",
            store: store,
            session: session,
            canUpload: { true }
        )

        uploader.flush {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(store.pending().count, 0)
    }

    func test503KeepsFileAndIncrementsAttempts() throws {
        let endpoint = URL(string: "https://ingest.artracker.io")!
        try store.save(startId: "start_503", body: "dummy".data(using: .utf8)!)

        let exp = expectation(description: "Upload completed")
        StubProfileURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }

        let uploader = ProfileUploader(
            endpoint: endpoint,
            appKey: "key",
            store: store,
            session: session,
            canUpload: { true }
        )

        uploader.flush {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        let pending = store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attempts, 1)
    }

    func testNetworkErrorKeepsFile() throws {
        let endpoint = URL(string: "https://ingest.artracker.io")!
        try store.save(startId: "start_net_err", body: "dummy".data(using: .utf8)!)

        let exp = expectation(description: "Upload completed")
        StubProfileURLProtocol.requestHandler = { request in
            throw URLError(.notConnectedToInternet)
        }

        let uploader = ProfileUploader(
            endpoint: endpoint,
            appKey: "key",
            store: store,
            session: session,
            canUpload: { true }
        )

        uploader.flush {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        let pending = store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attempts, 1)
    }

    func testSkipsWhenCannotUpload() throws {
        let endpoint = URL(string: "https://ingest.artracker.io")!
        try store.save(startId: "start_skip", body: "dummy".data(using: .utf8)!)

        var requestSent = false
        StubProfileURLProtocol.requestHandler = { request in
            requestSent = true
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }

        let exp = expectation(description: "Upload skipped")
        let uploader = ProfileUploader(
            endpoint: endpoint,
            appKey: "key",
            store: store,
            session: session,
            canUpload: { false }
        )

        uploader.flush {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertFalse(requestSent)
        XCTAssertEqual(store.pending().count, 1)
        XCTAssertEqual(store.pending().first?.attempts, 0)
    }

    func testBodyOver1MBIsRejected() {
        // Create uncompressible ~2MB random bytes in sym array
        var randomBytes = [UInt8](repeating: 0, count: 2_000_000)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let incompressibleString = Data(randomBytes).base64EncodedString()

        let profile = StartupProfile(
            v: 1,
            startId: "start_huge",
            platform: "ios",
            intervalMs: 10,
            t0: "2026-11-19T10:00:00.000Z",
            images: [],
            frames: [ProfileFrame(a: "0x1000", i: nil, sym: incompressibleString)],
            stacks: [[0]],
            samples: [ProfileSample(t: 10, s: 0)]
        )
        let env = ProfileEnvelope(
            sdk: .current,
            context: ProfileContext(app_version: "1.0.0", build: "1", environment: "test"),
            profile: profile
        )

        XCTAssertThrowsError(try ProfileBody.gzip(env)) { error in
            XCTAssertEqual(error as? ProfileBodyError, .tooLarge)
        }
    }
}
