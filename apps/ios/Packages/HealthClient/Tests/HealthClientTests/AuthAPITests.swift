import XCTest
import Security
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
    static var path: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.path = request.url?.path
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
    func testPrivateRestoreScopeRequiresExplicitModeAndBoundedIDs() async throws {
        store.value = String(repeating: "y", count: 43)
        let id = UUID()
        AuthProtocol.body = "{\"RESTORE_BETA_ACCEPTED\":false,\"OWNER_DEVICE_TEST\":true,\"OWNER_DEVICE_TEST_ASSET_IDS\":[\"\(id.uuidString)\"]}"
        let accepted = try await api.ownerDeviceTestRestoreAssets()
        XCTAssertEqual(accepted, [id])
        XCTAssertEqual(AuthProtocol.path, "/restore/status")
        AuthProtocol.body = "{\"OWNER_DEVICE_TEST_ASSET_IDS\":[\"\(id.uuidString)\"]}"
        let missingMode = try await api.ownerDeviceTestRestoreAssets()
        XCTAssertNil(missingMode)
        AuthProtocol.body = "{\"OWNER_DEVICE_TEST\":true,\"OWNER_DEVICE_TEST_ASSET_IDS\":[]}"
        let empty = try await api.ownerDeviceTestRestoreAssets()
        XCTAssertEqual(empty, [])
        AuthProtocol.body = "{\"OWNER_DEVICE_TEST\":true,\"OWNER_DEVICE_TEST_ASSET_IDS\":[\"\(id.uuidString)\",\"\(id.uuidString)\",\"\(id.uuidString)\"]}"
        let tooMany = try await api.ownerDeviceTestRestoreAssets()
        XCTAssertNil(tooMany)
    }
    func testProjectRestoreScopeAccepts100DistinctIDsAndRejects101() async throws {
        store.value=String(repeating:"y",count:43)
        let ids=(0..<100).map{_ in UUID()}
        AuthProtocol.body=String(decoding:try JSONSerialization.data(withJSONObject:["OWNER_DEVICE_TEST":true,"OWNER_DEVICE_TEST_ASSET_IDS":ids.map(\.uuidString)]),as:UTF8.self)
        let accepted=try await api.ownerDeviceTestRestoreAssets();XCTAssertEqual(accepted,ids)
        AuthProtocol.body=String(decoding:try JSONSerialization.data(withJSONObject:["OWNER_DEVICE_TEST":true,"OWNER_DEVICE_TEST_ASSET_IDS":(ids+[UUID()]).map(\.uuidString)]),as:UTF8.self)
        let rejected=try await api.ownerDeviceTestRestoreAssets();XCTAssertNil(rejected)
    }
    func testCurrentDeviceUsesAuthenticatedSessionsRoute() async throws {
        store.value = String(repeating:"y",count:43)
        let device=UUID()
        AuthProtocol.body="[{\"current\":false,\"deviceId\":\"\(UUID().uuidString)\"},{\"current\":true,\"deviceId\":\"\(device.uuidString)\"}]"
        let actual=try await api.currentDeviceID()
        XCTAssertEqual(actual,device)
        XCTAssertEqual(AuthProtocol.path,"/sessions")
        XCTAssertEqual(AuthProtocol.authorization,"Bearer \(store.value!)")
    }
    func testCurrentDeviceRejectsUnboundCurrentSession() async throws {
        store.value = String(repeating:"y",count:43)
        AuthProtocol.body="[{\"current\":false,\"deviceId\":\"\(UUID().uuidString)\"},{\"current\":true,\"deviceId\":null}]"
        do { _ = try await api.currentDeviceID();XCTFail("Unbound session must not use another device") }
        catch { XCTAssertNotNil(store.value) }
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
    func testBackgroundKeychainMigrationRetainsSessionAndDeviceOnlyProtection() throws {
        let service="foundation.background.test.\(UUID().uuidString)",ordinary=KeychainSessionStore(service:service)
        defer{try? ordinary.clear()}
        let token=UUID().uuidString;try ordinary.save(token)
        #if os(iOS)
        func protection() throws -> String {
            let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"server-session",kSecAttrSynchronizable as String:false,kSecReturnAttributes as String:true]
            var value:CFTypeRef?;XCTAssertEqual(SecItemCopyMatching(query as CFDictionary,&value),errSecSuccess)
            return try XCTUnwrap((value as? [String:Any])?[kSecAttrAccessible as String] as? String)
        }
        XCTAssertEqual(try protection(),kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #endif
        XCTAssertEqual(ordinary.accessibility as String,kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let background=KeychainSessionStore(service:service,allowsBackgroundAccess:true)
        XCTAssertEqual(try background.read(),token)
        #if os(iOS)
        XCTAssertEqual(try protection(),kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #endif
        XCTAssertEqual(background.accessibility as String,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        // Ordinary reads never silently downgrade an active background session.
        XCTAssertEqual(try ordinary.read(),token)
        #if os(iOS)
        XCTAssertEqual(try protection(),kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #endif
        XCTAssertEqual(background.accessibility as String,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try background.clear();XCTAssertNil(try ordinary.read())
    }

}
