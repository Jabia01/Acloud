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
    private func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = false) async throws -> Data {
        guard let scheme = baseURL.scheme, ["http", "https"].contains(scheme) else { throw AccountAPIError.invalidConfiguration }
        // Plain HTTP permitted only for local development hosts, never remote auth.
        if scheme == "http" && !(baseURL.host == "localhost" || baseURL.host == "127.0.0.1" || baseURL.host?.hasSuffix(".local") == true) { throw AccountAPIError.invalidConfiguration }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token = try store.read() else { throw AccountAPIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountAPIError.requestFailed }
        if http.statusCode == 401 {
            // A failed login must not delete an unrelated existing session.
            if authenticated { try store.clear() }
            throw AccountAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else { throw AccountAPIError.requestFailed }
        return data
    }
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
        do { _ = try await request("auth/logout", method: "POST", authenticated: true) }
        catch AccountAPIError.unauthorized { try store.clear(); return }
        // On network failure retain the credential for retry, instead of claiming server revocation.
        try store.clear()
    }
}
