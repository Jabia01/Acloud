import XCTest
@testable import HealthClient

final class StubProtocol: URLProtocol {
    static var status = 200
    static var body = ""
    static var fails = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HealthAPITests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        StubProtocol.status = 200
        StubProtocol.fails = false
        StubProtocol.body = #"{"status":"ok","checks":{"api":"up","database":"up"}}"#
    }
    override func tearDown() { session.invalidateAndCancel() }
    private func connected() async -> Bool {
        await HealthAPI(baseURL: URL(string: "http://localhost:3001")!, session: session).isConnected()
    }
    func testHealthy() async { let result = await connected(); XCTAssertTrue(result) }
    func testUnavailableDatabase() async {
        StubProtocol.body = #"{"status":"degraded","checks":{"api":"up","database":"down"}}"#
        let result = await connected(); XCTAssertFalse(result)
    }
    func testHTTPFailure() async { StubProtocol.status = 503; let result = await connected(); XCTAssertFalse(result) }
    func testMalformedResponse() async { StubProtocol.body = "{}"; let result = await connected(); XCTAssertFalse(result) }
    func testNetworkFailure() async { StubProtocol.fails = true; let result = await connected(); XCTAssertFalse(result) }
}
