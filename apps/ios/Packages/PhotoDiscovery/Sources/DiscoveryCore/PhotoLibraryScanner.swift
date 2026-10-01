import Foundation

public actor PhotoLibraryScanner {
    private let library: any PhotoLibraryProvider
    private let store: any DiscoveredAssetStore
    private let batchSize: Int
    private var running = false
    public init(library: any PhotoLibraryProvider, store: any DiscoveredAssetStore, batchSize: Int = 250) {
        self.library = library; self.store = store; self.batchSize = max(1, min(batchSize, 1000))
    }
    public func run(progress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }) async throws -> ScanOutcome {
        guard !running else { throw DiscoveryError.scanAlreadyRunning }
        running = true; defer { running = false }
        let authorization = await library.authorization()
        guard authorization.canRead else {
            try await store.invalidateVisibility()
            return .noAccess(authorization)
        }
        let snapshot = try await library.openSnapshot()
        var checkpoint = try await store.begin(snapshotKey: snapshot.key, total: snapshot.total, authorization: authorization)
        do {
            await progress(ScanProgress(processed: checkpoint.nextOffset, total: checkpoint.total, newlyDiscovered: checkpoint.newlyDiscovered))
            while checkpoint.nextOffset < snapshot.total {
                try Task.checkCancellation()
                guard await library.snapshotIsCurrent(snapshot.key) else {
                    try await store.invalidateVisibility(); return .libraryChanged
                }
                let assets = try await snapshot.batch(offset: checkpoint.nextOffset, limit: batchSize)
                try Task.checkCancellation()
                guard assets.count == min(batchSize, snapshot.total - checkpoint.nextOffset) else { throw DiscoveryError.inconsistentSnapshot }
                guard await library.snapshotIsCurrent(snapshot.key) else {
                    try await store.invalidateVisibility(); return .libraryChanged
                }
                checkpoint = try await store.writeBatch(assets, checkpoint: checkpoint, nextOffset: checkpoint.nextOffset + assets.count)
                // Progress is O(1); do not re-aggregate the whole table for every batch.
                await progress(ScanProgress(processed: checkpoint.nextOffset, total: checkpoint.total, newlyDiscovered: checkpoint.newlyDiscovered))
            }
            try Task.checkCancellation()
            guard await library.snapshotIsCurrent(snapshot.key), await library.authorization() == authorization else {
                try await store.invalidateVisibility(); return .libraryChanged
            }
            try await store.finish(checkpoint)
            guard await library.snapshotIsCurrent(snapshot.key) else {
                try await store.invalidateVisibility(); return .libraryChanged
            }
            return .complete(try await store.summary())
        } catch is CancellationError {
            let currentAuthorization = await library.authorization()
            guard currentAuthorization == authorization, await library.snapshotIsCurrent(snapshot.key) else {
                try await store.invalidateVisibility()
                return currentAuthorization.canRead ? .libraryChanged : .noAccess(currentAuthorization)
            }
            try await store.pause(checkpoint)
            return .cancelled(try await store.summary())
        } catch {
            try await store.pause(checkpoint)
            throw error
        }
    }
    // Call only after the UI has cancelled/awaited any active scan.
    public func invalidateAccess() async throws { try await store.invalidateVisibility() }
}
