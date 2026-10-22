import Foundation

public struct AccountStatus: Decodable, Equatable {
    public let id: String
    public let email: String
    public let emailVerified: Bool
    public let status: String
}
public enum AccountAPIError: Error { case unauthorized, requestFailed, invalidConfiguration }
private final class NoAccountRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct AuthAPI {
    private let baseURL: URL
    private let session: URLSession
    private let store: SessionTokenStore
    public init(baseURL: URL, store: SessionTokenStore, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.store = store
        if let supplied = session { self.session = supplied }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config, delegate: NoAccountRedirects(), delegateQueue: nil)
        }
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = false, credential:String? = nil) async throws -> Data {
        guard let scheme = baseURL.scheme, ["http", "https"].contains(scheme) else { throw AccountAPIError.invalidConfiguration }
        // Plain HTTP permitted only for local development hosts, never remote auth.
        if scheme == "http" && !(baseURL.host == "localhost" || baseURL.host == "127.0.0.1" || baseURL.host?.hasSuffix(".local") == true) { throw AccountAPIError.invalidConfiguration }
        let expected=Bundle.main.object(forInfoDictionaryKey:"BetaDeploymentFingerprint") as? String
        if Bundle.main.object(forInfoDictionaryKey:"BetaRelease") as? Bool == true {guard expected?.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,scheme=="https",baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil,["","/"].contains(baseURL.path) else{throw AccountAPIError.invalidConfiguration}}
        if let expected {
            var probe=URLRequest(url:baseURL.appendingPathComponent("health"));probe.timeoutInterval=10;probe.cachePolicy = .reloadIgnoringLocalCacheData
            let (_,response)=try await session.data(for:probe)
            guard let http=response as? HTTPURLResponse,http.statusCode==200,http.url?.host==baseURL.host,http.value(forHTTPHeaderField:"X-Environment-Fingerprint")==expected else{throw AccountAPIError.invalidConfiguration}
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        if let expected{request.setValue(expected,forHTTPHeaderField:"X-Environment-Fingerprint")}
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var authorizedToken:String?
        if authenticated {
            let current=try credential ?? store.read()
            guard let token = current else { throw AccountAPIError.unauthorized }
            authorizedToken=token
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountAPIError.requestFailed }
        if let expected,http.value(forHTTPHeaderField:"X-Environment-Fingerprint") != expected{throw AccountAPIError.invalidConfiguration}
        if http.statusCode == 401 {
            // A failed login must not delete an unrelated existing session.
            if let authorizedToken { try store.clear(ifMatching:authorizedToken) }
            throw AccountAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else { throw AccountAPIError.requestFailed }
        return data
    }
    public func currentDeviceID() async throws -> UUID {struct BoundSession:Decodable{let current:Bool;let deviceId:UUID?};let data=try await request("sessions",authenticated:true);let sessions=try JSONDecoder().decode([BoundSession].self,from:data);guard let device=sessions.first(where:{$0.current})?.deviceId else{throw AccountAPIError.invalidConfiguration};return device}
    public func ownerDeviceTestRestoreAssets() async throws -> [UUID]? {
        struct Gates: Decodable { let OWNER_DEVICE_TEST: Bool?; let OWNER_DEVICE_TEST_ASSET_IDS: [UUID]? }
        let data = try await request("restore/status", authenticated: true)
        let gates = try JSONDecoder().decode(Gates.self, from: data)
        guard gates.OWNER_DEVICE_TEST == true, let ids = gates.OWNER_DEVICE_TEST_ASSET_IDS, ids.count <= 100, Set(ids).count == ids.count else { return nil }
        return ids
    }
    public func developmentRestoreTestAssetID() async throws -> UUID? {struct Gates:Decodable{let DEVELOPMENT_RESTORE_TEST_ASSET_ID:UUID?};let data=try await request("restore/status",authenticated:true);return try JSONDecoder().decode(Gates.self,from:data).DEVELOPMENT_RESTORE_TEST_ASSET_ID}
    public func restoreAccepted() async throws -> Bool {struct Gates:Decodable{let RESTORE_BETA_ACCEPTED:Bool};let data=try await request("restore/status",authenticated:true);return try JSONDecoder().decode(Gates.self,from:data).RESTORE_BETA_ACCEPTED}
    public func realMediaAccepted() async throws -> Bool {struct Gates:Decodable{let REAL_MEDIA_BETA_ACCEPTED:Bool};let data=try await request("beta/admission",authenticated:true);return try JSONDecoder().decode(Gates.self,from:data).REAL_MEDIA_BETA_ACCEPTED}
    public func register(email: String, password: String) async throws {
        _ = try await request("auth/register", method: "POST", body: JSONSerialization.data(withJSONObject: ["email": email, "password": password]))
    }
    public func login(email: String, password: String, deviceIdentifier: String) async throws -> AccountStatus {
        let device: [String: String] = ["identifier": deviceIdentifier, "displayName": "iPhone", "platform": "ios", "appVersion": "0.1.0", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString]
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password, "device": device])
        let data = try await request("auth/login", method: "POST", body: body)
        struct LoginResponse: Decodable { let sessionToken: String; let user: AccountStatus }
        let login = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard login.sessionToken.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw AccountAPIError.requestFailed }
        do { try store.save(login.sessionToken) }
        catch {
            // Best-effort revoke an issued session if persistence fails; do not expose it.
            var revoke = URLRequest(url: baseURL.appendingPathComponent("auth/logout"))
            revoke.httpMethod = "POST"; revoke.timeoutInterval = 10
            revoke.setValue("Bearer \(login.sessionToken)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: revoke)
            throw SecureStorageError.unavailable
        }
        return login.user
    }
    public func me() async throws -> AccountStatus {
        try JSONDecoder().decode(AccountStatus.self, from: await request("me", authenticated: true))
    }
    public func logout() async throws {
        guard let previous=try store.read() else{return}
        do { _ = try await request("auth/logout", method: "POST", authenticated: true,credential:previous) }
        catch AccountAPIError.unauthorized {try store.clear(ifMatching:previous); return }
        // On network failure retain the credential for retry, instead of claiming server revocation.
        try store.clear(ifMatching:previous)
    }
}
