import Foundation
import HealthClient

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
    return URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
}
private func safeBase(_ url: URL, allowLocalHTTP: Bool) throws {
    let local = ["127.0.0.1","localhost"].contains(url.host ?? "") || url.host?.hasSuffix(".local") == true
    guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.scheme == "https" || (allowLocalHTTP && local && url.scheme == "http") else { throw UploadError.invalidAuthorization }
}
private func expired(_ value: String) -> Bool {
    let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
    guard let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return true }
    return date <= Date()
}
public actor HTTPUploadSessionClient: UploadSessionClient {
    private let baseURL: URL
    private let tokens: any SessionTokenStore
    private let network: URLSession
    public init(baseURL: URL, tokens: any SessionTokenStore, allowLocalHTTP: Bool = false) throws {
        try safeBase(baseURL, allowLocalHTTP: allowLocalHTTP)
        self.baseURL = baseURL; self.tokens = tokens; network = session()
    }
    private func request<T: Decodable>(_ path: String, method: String, body: Data? = nil, key: UUID? = nil) async throws -> T {
        guard let token = try tokens.read() else { throw UploadError.unauthorized }
        var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 30; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue(key.uuidString, forHTTPHeaderField: "Idempotency-Key") }
        let (data,response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.requestFailed }
        if http.statusCode == 401 { try tokens.clear(); throw UploadError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw UploadError.requestFailed }
        return try JSONDecoder().decode(T.self, from: data)
    }
    public func create(payload: GeneratedPayload, idempotencyKey: UUID) async throws -> UploadSession {
        let data = try JSONSerialization.data(withJSONObject: ["media_type":"test","expected_size_bytes":payload.sizeBytes,"checksum_sha256":payload.checksumSHA256])
        return try await request("uploads", method: "POST", body: data, key: idempotencyKey)
    }
    public func complete(id: UUID) async throws -> UploadSession { try await request("uploads/\(id.uuidString)/complete", method: "POST") }
    public func start(id: UUID) async throws -> UploadSession { try await request("uploads/\(id.uuidString)/start", method: "POST") }
    public func asset(id: UUID) async throws -> ServerAsset { try await request("assets/\(id.uuidString)", method: "GET") }
    public func cancel(id: UUID) async throws -> UploadSession { try await request("uploads/\(id.uuidString)", method: "DELETE") }
}
public actor SinglePartUploadTransport: UploadTransport {
    private let allowedOrigin: URL
    private let network: URLSession
    public init(allowedOrigin: URL, allowLocalHTTP: Bool = false) throws {
        try safeBase(allowedOrigin, allowLocalHTTP: allowLocalHTTP)
        self.allowedOrigin = allowedOrigin; network = session()
    }
    public func upload(file: GeneratedPayload, authorization: UploadAuthorization) async throws {
        let url = authorization.url
        guard authorization.method == "PUT", !expired(authorization.expiresAt),
              url.scheme == allowedOrigin.scheme, url.host == allowedOrigin.host, url.port == allowedOrigin.port,
              url.user == nil, url.password == nil, url.fragment == nil else { throw UploadError.invalidAuthorization }
        guard authorization.headers["content-length"] == String(file.sizeBytes),
              authorization.headers["if-none-match"] == "*", authorization.headers["content-type"] == "application/octet-stream",
              authorization.headers["x-amz-checksum-sha256"] == Self.base64Digest(file.checksumSHA256),
              Set(authorization.headers.keys) == Set(["content-length","if-none-match","content-type","x-amz-checksum-sha256"]) else { throw UploadError.invalidAuthorization }
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 30
        for (name,value) in authorization.headers { request.setValue(value, forHTTPHeaderField: name) }
        // No API bearer/cookies or redirect following on the direct storage request.
        let (_,response) = try await network.upload(for: request, fromFile: file.fileURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw UploadError.requestFailed }
    }
    private static func base64Digest(_ value: String) -> String? {
        guard value.count == 64 else { return nil }
        var data = Data(); var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            data.append(byte); index = end
        }
        return data.base64EncodedString()
    }
}
