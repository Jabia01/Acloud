import XCTest
@testable import HealthClient

final class MemoryTokenStore: SessionTokenStore {
    var value: String?
    func read() throws -> String? { value }
    func save(_ token: String) throws { value = token }
    func clear() throws { value = nil }
}
final class AuthProtocol: URLProtocol {
    static var body = ""
    static var status = 200
    static var authorization: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class AuthAPITests: XCTestCase {
    private var session: URLSession!
    private var store: MemoryTokenStore!
    private var api: AuthAPI!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthProtocol.self]
        session = URLSession(configuration: config); store = MemoryTokenStore()
        api = AuthAPI(baseURL: URL(string: "http://localhost:3001")!, store: store, session: session)
        AuthProtocol.status = 200; AuthProtocol.authorization = nil
        AuthProtocol.body = #"{"id":"fixture","email":"fixture@example.invalid","emailVerified":false,"status":"ACTIVE"}"#
    }
    override func tearDown() { session.invalidateAndCancel() }
    func testLoginPersistsCredentialThroughStoreOnly() async throws {
        let raw = String(repeating: "x", count: 43)
        AuthProtocol.body = "{\"sessionToken\":\"\(raw)\",\"user\":\(AuthProtocol.body)}"
        let account = try await api.login(email: "fixture@example.invalid", password: UUID().uuidString, deviceIdentifier: UUID().uuidString)
        XCTAssertEqual(store.value, raw); XCTAssertEqual(account.email, "fixture@example.invalid"); XCTAssertNil(AuthProtocol.authorization)
    }
    func testAuthenticatedMeUsesBearer() async throws {
        store.value = String(repeating: "y", count: 43)
        _ = try await api.me(); XCTAssertEqual(AuthProtocol.authorization, "Bearer \(store.value!)")
    }
    func testUnauthorizedClearsStore() async {
        store.value = String(repeating: "z", count: 43); AuthProtocol.status = 401
        do { _ = try await api.me(); XCTFail("Expected unauthorized") } catch { XCTAssertNil(store.value) }
    }
    func testLogoutRevokesThenClears() async throws {
        store.value = String(repeating: "z", count: 43); try await api.logout(); XCTAssertNil(store.value)
    }
    func testLogoutServerFailureRetainsCredentialForRetry() async {
        store.value = String(repeating: "z", count: 43); AuthProtocol.status = 503
        do { try await api.logout(); XCTFail("Expected failure") } catch { XCTAssertNotNil(store.value) }
    }
    func testKeychainRoundTrip() throws {
        let keychain = KeychainSessionStore(service: "foundation.test.\(UUID().uuidString)")
        defer { try? keychain.clear() }
        XCTAssertNil(try keychain.read()); let raw = UUID().uuidString
        try keychain.save(raw); XCTAssertEqual(try keychain.read(), raw)
        try keychain.save(raw + "updated"); XCTAssertEqual(try keychain.read(), raw + "updated")
        try keychain.clear(); XCTAssertNil(try keychain.read())
    }
}
