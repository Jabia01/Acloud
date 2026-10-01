import Foundation

public struct HealthAPI {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func isConnected() async -> Bool {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            return health.status == "ok" && health.checks.api == "up" && health.checks.database == "up"
        } catch {
            return false
        }
    }
}

private struct HealthResponse: Decodable {
    let status: String
    let checks: Checks
    struct Checks: Decodable { let api: String; let database: String }
}
