import Foundation

public enum LibraryAuthorization: String, Codable, Sendable, CaseIterable {
    case notDetermined, restricted, denied, authorized, limited
    public var canRead: Bool { self == .authorized || self == .limited }
}
public enum DiscoveredMediaType: String, Codable, Sendable { case image, video }
// These are observations only, never backup/upload/protection states.
public enum LocalDiscoveryState: String, Codable, Sendable, CaseIterable { case visible, unavailable }
public enum ResourceAvailability: String, Codable, Sendable { case unknown }

public struct AssetMetadata: Equatable, Sendable {
    // Correlation key scoped to this installation and Photos library. Never a cloud ID.
    public let localAssetID: String
    public let mediaType: DiscoveredMediaType
    public let creationDate: Date?
    public let modificationDate: Date?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let duration: Double?
    public let knownResourceBytes: Int64?
    public let resourceAvailability: ResourceAvailability
    public init(localAssetID: String, mediaType: DiscoveredMediaType,
                creationDate: Date? = nil, modificationDate: Date? = nil,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil, duration: Double? = nil,
                knownResourceBytes: Int64? = nil) {
        self.localAssetID = localAssetID; self.mediaType = mediaType
        self.creationDate = creationDate; self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth.flatMap { $0 > 0 ? $0 : nil }
        self.pixelHeight = pixelHeight.flatMap { $0 > 0 ? $0 : nil }
        self.duration = mediaType == .video ? duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
        self.knownResourceBytes = knownResourceBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.resourceAvailability = .unknown // Byte size cannot establish on-device availability.
    }
}
public struct StoredDiscoveredAsset: Sendable {
    public let metadata: AssetMetadata
    public let state: LocalDiscoveryState
    public let firstSeenAt: Date
    public let lastSeenAt: Date
}
public struct DiscoverySummary: Equatable, Sendable {
    public let images: Int
    public let videos: Int
    public let knownResourceBytes: Int64
    public let knownSizeAssets: Int
    public let unknownSizeAssets: Int
    public let unavailableAssets: Int
    public let isComplete: Bool
    public var observedAssets: Int { images + videos }
}
public struct ScanCheckpoint: Sendable {
    public let generation: String
    public let snapshotKey: String
    public let authorization: LibraryAuthorization
    public let total: Int
    public let nextOffset: Int
    public let newlyDiscovered: Int
}
public struct ScanProgress: Sendable {
    public let processed: Int
    public let total: Int
    public let newlyDiscovered: Int
}
public enum ScanOutcome: Sendable {
    case complete(DiscoverySummary)
    case cancelled(DiscoverySummary)
    case libraryChanged
    case noAccess(LibraryAuthorization)
}
public enum DiscoveryError: Error { case storageUnavailable, unsupportedStoreVersion, inconsistentSnapshot, scanAlreadyRunning }

// A metadata-only size total. A missing component makes the whole asset unknown;
// never silently sum only the photo half of a Live Photo or convert nil to zero.
public enum OriginalResourceSizePolicy {
    public static func total(_ resourceSizes: [Int64?]) -> Int64? {
        guard !resourceSizes.isEmpty else { return nil }
        var total: Int64 = 0
        for size in resourceSizes {
            guard let size, size >= 0 else { return nil }
            let addition = total.addingReportingOverflow(size)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
