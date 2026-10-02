import Foundation
import CryptoKit

public enum UploadPhase: String, Codable, Sendable { case queued, uploading, uploaded, verifying, protected, failed, cancelled }
public enum RemoteAssetStatus: String, Codable, Sendable { case queued = "QUEUED", uploading = "UPLOADING", uploaded = "UPLOADED", verifying = "VERIFYING", protected = "PROTECTED", failed = "FAILED", cancelled = "CANCELLED", expired = "EXPIRED" }
public enum UploadError: Error { case invalidPayload, sourceChanged, invalidAuthorization, unauthorized, requestFailed, expired, queueFull, alreadyRunning, missingRecord }
public struct GeneratedPayload: Codable, Sendable, Equatable {
    public let fileURL: URL
    public let sizeBytes: Int
    public let checksumSHA256: String
    // Only explicitly supplied files within a caller-owned generated-fixture directory.
    // No Photos import, Photos original retrieval or automatic library traversal exists.
    public static func inspect(at url: URL, in directory: URL) throws -> GeneratedPayload {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.isFileURL, file.path.hasPrefix(base.path + "/"),
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw UploadError.invalidPayload }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256(); var size = 0
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            size += data.count
            guard size <= 5 * 1024 * 1024 else { throw UploadError.invalidPayload }
            digest.update(data: data)
        }
        guard size > 0 else { throw UploadError.invalidPayload }
        return GeneratedPayload(fileURL: file, sizeBytes: size, checksumSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
public struct UploadAuthorization: Codable, Sendable {
    public let method: String
    public let url: URL
    public let headers: [String:String]
    public let expiresAt: String
}
public struct UploadSession: Codable, Sendable {
    public let id: UUID
    public let assetId: UUID
    public let status: RemoteAssetStatus
    public let expiresAt: String
    public let errorCode: String?
    public let authorization: UploadAuthorization?
}
public struct ServerAsset: Codable, Sendable {
    public let id: UUID
    public let mediaType: String
    public let status: RemoteAssetStatus
    public let sizeBytes: Int?
}
public struct UploadRecord: Codable, Sendable {
    public let id: UUID
    public let idempotencyKey: UUID
    public let payload: GeneratedPayload
    public var sessionID: UUID?
    public var assetID: UUID?
    public var phase: UploadPhase
    public var cancellationPending: Bool
    public init(payload: GeneratedPayload) {
        id = UUID(); idempotencyKey = UUID(); self.payload = payload
        phase = .queued; cancellationPending = false
    }
}
public protocol UploadSessionClient: Sendable {
    func create(payload: GeneratedPayload, idempotencyKey: UUID) async throws -> UploadSession
    func complete(id: UUID) async throws -> UploadSession
    func start(id: UUID) async throws -> UploadSession
    func asset(id: UUID) async throws -> ServerAsset
    func cancel(id: UUID) async throws -> UploadSession
}
public protocol UploadTransport: Sendable {
    func upload(file: GeneratedPayload, authorization: UploadAuthorization) async throws
}
public protocol UploadStateStore: Sendable {
    func save(_ record: UploadRecord) async throws
    func read(_ id: UUID) async throws -> UploadRecord?
}
