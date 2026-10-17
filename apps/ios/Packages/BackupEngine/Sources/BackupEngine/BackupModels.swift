import Foundation
import MediaPreservation
import UploadFoundation

public enum BackupState: String, Codable, Sendable, CaseIterable {
 case discovered = "DISCOVERED", queued = "QUEUED", preparing = "PREPARING", uploading = "UPLOADING", paused = "PAUSED"
 case uploaded = "UPLOADED", verifying = "VERIFYING", protected = "PROTECTED"
 case failedRetryable = "FAILED_RETRYABLE", failedPermanent = "FAILED_PERMANENT", cancelled = "CANCELLED"
 public func allows(_ next: Self) -> Bool {
  if self == next { return true }
  if self == .protected { return false }
  if next == .protected { return false } // Separate server-proof transition only.
  if self == .cancelled { return false }
  if next == .cancelled || next == .paused { return true }
  switch self {
  case .discovered: return next == .queued
  case .queued, .failedRetryable, .paused: return [.queued,.preparing,.uploading,.uploaded,.verifying,.failedRetryable,.failedPermanent].contains(next)
  case .preparing: return [.uploading,.failedRetryable,.failedPermanent,.queued].contains(next)
  case .uploading: return [.uploaded,.verifying,.failedRetryable,.failedPermanent,.preparing,.queued].contains(next)
  case .uploaded: return [.verifying,.failedRetryable,.failedPermanent].contains(next)
  case .verifying: return [.failedRetryable,.failedPermanent,.uploaded].contains(next)
  case .failedPermanent: return next == .queued // Explicit user retry only.
  case .protected, .cancelled: return false
  }
 }
}
public enum BackupFailure: Error, Equatable { case storage, staleWrite, illegalTransition, missing, sourceChanged, waitingForOriginal, inaccessible, unsupported, policy, authorization, http(Int), retryLimit }
public struct BackupItem: Codable, Sendable, Identifiable {
 public let id: UUID
 public let libraryID: UUID
 public let localAssetIdentifier: String
 public let mediaType: String
 public var accountID:UUID?
 public var deviceID:UUID?
 public var mediaResourceBinding:ManifestResourceBinding?
 public var originalManifest:OriginalManifest?
 public var state: BackupState = .queued
 public var expectedSizeBytes: Int?
 public var expectedChecksum: String?
 public var uploadKey = UUID()
 public var sessionID: UUID?
 public var assetID: UUID?
 public var bytesUploaded = 0
 public var retryCount = 0
 public var nextRetryAt: Date?
 public var lastErrorCode: String?
 public var localRemovedAfterProtection:Bool?
 public var cancellationPending = false
 public var revision = 0
 public let createdAt: Date
 public var updatedAt: Date
 public init(libraryID: UUID, localAssetIdentifier: String, mediaType: String, id: UUID = UUID()) {
  self.id=id; self.libraryID=libraryID; self.localAssetIdentifier=localAssetIdentifier; self.mediaType=mediaType
  createdAt=Date(); updatedAt=createdAt
 }
}
public struct PreparedResource: Sendable {
 public let fileURL: URL
 public let sizeBytes: Int
 public let checksum: String
 public let manifest:OriginalManifest?
 public init(fileURL: URL, sizeBytes: Int, checksum: String,manifest:OriginalManifest?=nil) { self.fileURL=fileURL; self.sizeBytes=sizeBytes; self.checksum=checksum;self.manifest=manifest }
}
public protocol ResourcePreparer: Sendable {
 func prepare(_ item: BackupItem, policy: BackupPolicy, network: NetworkSnapshot) async throws -> PreparedResource
 func cleanup(_ item: BackupItem) async throws
}
public struct NetworkSnapshot: Sendable {
 public var connected: Bool; public var cellular: Bool; public var wifi: Bool; public var constrained: Bool
 public init(connected: Bool = true, cellular: Bool = false, wifi: Bool = true, constrained: Bool = false) {
  self.connected=connected; self.cellular=cellular; self.wifi=wifi; self.constrained=constrained
 }
}
public struct BackupPolicy: Sendable {
 public var wifiOnly = true
 public var allowCellular = false
 public var allowLargeVideosOnCellular = false
 public var maxCellularFileBytes = 10 * 1024 * 1024
 public var pauseOnConstrained = true
 public var allowICloudOriginals = false
 public init() {}
 public func permits(_ item: BackupItem, network: NetworkSnapshot) -> Bool {
  guard network.connected, !(pauseOnConstrained && network.constrained) else { return false }
  if wifiOnly && !network.wifi { return false }
  if network.cellular {
   guard allowCellular, let size=item.expectedSizeBytes, size<=maxCellularFileBytes else { return false }
   if item.mediaType == "video" && size>5*1024*1024 && !allowLargeVideosOnCellular { return false }
  }
  return true
 }
}
public struct RetryPolicy: Sendable {
 public let maximumAttempts: Int
 public init(maximumAttempts: Int = 8) { self.maximumAttempts=maximumAttempts }
 public func delay(attempt: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval {
  min(3600, 2 * pow(2, Double(max(0,min(attempt-1,20))))) * (0.5 + min(1,max(0,random))*0.5)
 }
 public func retryable(_ error: Error) -> Bool {
  if let e=error as? BackupFailure {
   switch e { case .http(let s): return s == 408 || s == 429 || s>=500
    case .authorization: return true
    default: return false }
  }
  if let e=error as? URLError { return [.timedOut,.cannotFindHost,.cannotConnectToHost,.networkConnectionLost,.notConnectedToInternet,.dnsLookupFailed,.resourceUnavailable].contains(e.code) }
  return false
 }
}
public struct MultipartSession: Decodable, Sendable {
 public let id: UUID; public let assetId: UUID; public let status: RemoteAssetStatus
 public let partSizeBytes: Int?; public let errorCode: String?
 public init(id: UUID, assetId: UUID, status: RemoteAssetStatus, partSizeBytes: Int? = 8*1024*1024, errorCode: String? = nil) {
  self.id=id; self.assetId=assetId; self.status=status; self.partSizeBytes=partSizeBytes; self.errorCode=errorCode
 }
}
public struct CompletedPart: Codable, Sendable, Equatable {
 public let partNumber: Int; public let sizeBytes: Int
 public init(partNumber: Int,sizeBytes: Int) { self.partNumber=partNumber; self.sizeBytes=sizeBytes }
}
public struct PartListing: Decodable, Sendable {
 public let completed: Bool; public let parts: [CompletedPart]
 public init(completed: Bool,parts: [CompletedPart]) { self.completed=completed; self.parts=parts }
}
public protocol MultipartAPI: Sendable {
 func create(_ item: BackupItem) async throws -> MultipartSession
 func status(_ id: UUID) async throws -> MultipartSession
 func start(_ id: UUID) async throws -> MultipartSession
 func parts(_ id: UUID) async throws -> PartListing
 func authorize(_ id: UUID, number: Int, size: Int, checksum: String) async throws -> UploadAuthorization
 func complete(_ id: UUID) async throws -> MultipartSession
 func verify(_ id: UUID) async throws -> MultipartSession
 func asset(_ id: UUID) async throws -> ServerAsset
 func cancel(_ id: UUID) async throws
 func integrity(_ id:UUID) async throws -> OriginalServerProof?
}
public extension MultipartAPI{func integrity(_ id:UUID) async throws -> OriginalServerProof?{nil}}
public protocol PartTransport: Sendable {
 var keepsTransfersDuringConnectionLoss:Bool {get}
 func upload(item: UUID, number: Int, resource: PreparedResource, authorization: UploadAuthorization, policy: BackupPolicy) async throws
 func cancel(item: UUID) async
 func activeItemIDs() async -> Set<UUID>
}
public extension PartTransport { func activeItemIDs() async -> Set<UUID> { [] } }

public extension BackupFailure {
 var diagnosticCode:String {
  switch self {
  case .http(410): return "SESSION_EXPIRED"
  case .http(let status): return (100...599).contains(status) ? "HTTP_\(status)" : "HTTP_ERROR"
  case .authorization: return "AUTHORIZATION_UNAVAILABLE"
  case .sourceChanged: return "SOURCE_CHANGED"
  case .unsupported: return "UNSUPPORTED_MEDIA"
  case .storage: return "LOCAL_STORAGE_UNAVAILABLE"
  case .missing: return "REQUIRED_STATE_MISSING"
  case .policy: return "POLICY_BLOCKED"
  case .waitingForOriginal: return "WAITING_FOR_ICLOUD_ORIGINAL"
  case .inaccessible: return "LOCAL_ACCESS_UNAVAILABLE"
  case .staleWrite: return "QUEUE_UPDATE_CONFLICT"
  case .illegalTransition: return "QUEUE_STATE_CONFLICT"
  case .retryLimit: return "RETRY_LIMIT"
  }
 }
}

public extension PartTransport {var keepsTransfersDuringConnectionLoss:Bool {false}}
