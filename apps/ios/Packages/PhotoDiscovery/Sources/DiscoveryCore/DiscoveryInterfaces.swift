import Foundation

public protocol PhotoLibrarySnapshot: Sendable {
    var key: String { get }
    var total: Int { get }
    // Implementations must return exactly min(limit, total-offset) metadata rows.
    func batch(offset: Int, limit: Int) async throws -> [AssetMetadata]
}
public protocol PhotoLibraryProvider: Sendable {
    func authorization() async -> LibraryAuthorization
    func requestAccess() async -> LibraryAuthorization
    func openSnapshot() async throws -> any PhotoLibrarySnapshot
    func snapshotIsCurrent(_ key: String) async -> Bool
    func invalidateSnapshots() async
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) async
}
public protocol DiscoveredAssetStore: Sendable {
    func begin(snapshotKey: String, total: Int, authorization: LibraryAuthorization) async throws -> ScanCheckpoint
    func writeBatch(_ assets: [AssetMetadata], checkpoint: ScanCheckpoint, nextOffset: Int) async throws -> ScanCheckpoint
    func finish(_ checkpoint: ScanCheckpoint) async throws
    func pause(_ checkpoint: ScanCheckpoint) async throws
    func invalidateVisibility() async throws
    func summary() async throws -> DiscoverySummary
}
