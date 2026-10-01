import XCTest
@testable import DiscoveryCore

private actor MockSnapshot: PhotoLibrarySnapshot {
    nonisolated let key: String
    nonisolated let total: Int
    private let make: @Sendable (Int) -> AssetMetadata
    private(set) var offsets: [Int] = [] // One entry per batch, never one per asset.
    private(set) var maxBatch = 0
    init(key: String, total: Int, make: @escaping @Sendable (Int) -> AssetMetadata) { self.key=key; self.total=total; self.make=make }
    func batch(offset: Int, limit: Int) -> [AssetMetadata] {
        offsets.append(offset); maxBatch = max(maxBatch,min(limit,total-offset))
        return (offset..<min(total,offset+limit)).map(make)
    }
}
private actor MockLibrary: PhotoLibraryProvider {
    var state: LibraryAuthorization
    var snapshot: MockSnapshot
    private(set) var opens = 0
    private(set) var requests = 0
    var current = true
    init(_ state: LibraryAuthorization = .authorized, count: Int = 3,
         make: @escaping @Sendable (Int) -> AssetMetadata = { AssetMetadata(localAssetID:"device-local-\($0)",mediaType:.image) }) {
        self.state=state; snapshot=MockSnapshot(key:"snapshot-1",total:count,make:make)
    }
    func authorization() -> LibraryAuthorization { state }
    func requestAccess() -> LibraryAuthorization { requests += 1; return state }
    func openSnapshot() -> any PhotoLibrarySnapshot { opens += 1; return snapshot }
    func snapshotIsCurrent(_ key: String) -> Bool { current && state.canRead && key == snapshot.key }
    func invalidateSnapshots() { current = false }
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) {}
    func replace(count: Int, make: @escaping @Sendable (Int) -> AssetMetadata) {
        snapshot=MockSnapshot(key:UUID().uuidString,total:count,make:make); current=true
    }
    func deny() { state = .denied; current = false }
}

final class DiscoveryTests: XCTestCase {
    private func permission(_ state: LibraryAuthorization) async throws {
        let library = MockLibrary(state)
        let store = try SQLiteDiscoveredAssetStore(url:nil)
        let outcome = try await PhotoLibraryScanner(library:library,store:store).run()
        if state.canRead {
            guard case .complete(let summary) = outcome else { return XCTFail("Expected readable library") }
            XCTAssertEqual(summary.images,3)
        } else {
            guard case .noAccess(let observed) = outcome else { return XCTFail("Expected no access") }
            XCTAssertEqual(observed,state)
            let opens = await library.opens; XCTAssertEqual(opens,0)
        }
        let requests = await library.requests; XCTAssertEqual(requests,0,"Scanner must never prompt")
    }
    func testNotDeterminedDoesNotPromptOrScan() async throws { try await permission(.notDetermined) }
    func testAuthorizedScans() async throws { try await permission(.authorized) }
    func testLimitedScansOnlyGrantedMockSnapshot() async throws { try await permission(.limited) }
    func testDeniedDoesNotPromptOrScan() async throws { try await permission(.denied) }
    func testRestrictedDoesNotPromptOrScan() async throws { try await permission(.restricted) }
    func testImageMetadataAndNullableVideoDuration() async throws {
        let date = Date(timeIntervalSince1970:100)
        let library = MockLibrary(count:1) { _ in AssetMetadata(localAssetID:"image",mediaType:.image,creationDate:date,pixelWidth:400,pixelHeight:300,duration:9) }
        let store = try SQLiteDiscoveredAssetStore(url:nil)
        _ = try await PhotoLibraryScanner(library:library,store:store).run()
        let asset = try await store.asset(localID:"image")
        XCTAssertEqual(asset?.metadata.creationDate,date); XCTAssertEqual(asset?.metadata.pixelWidth,400)
        XCTAssertEqual(asset?.metadata.pixelHeight,300); XCTAssertNil(asset?.metadata.duration)
    }
    func testVideoDiscoveryAndDuration() async throws {
        let library = MockLibrary(count:2) { i in AssetMetadata(localAssetID:"video-\(i)",mediaType:.video,duration:42.5) }
        let store = try SQLiteDiscoveredAssetStore(url:nil)
        _ = try await PhotoLibraryScanner(library:library,store:store).run()
        let summary = try await store.summary(); let asset = try await store.asset(localID:"video-0")
        XCTAssertEqual(summary.videos,2); XCTAssertEqual(summary.images,0); XCTAssertEqual(asset?.metadata.duration,42.5)
    }
    func testRepeatedScanPreservesRowsAndFirstSeen() async throws {
        let library = MockLibrary(); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store)
        _ = try await scanner.run(); let first = try await store.asset(localID:"device-local-0")
        _ = try await scanner.run(); let repeated = try await store.asset(localID:"device-local-0")
        let count = try await store.rowCount(); let checkpoint = try await store.checkpoint()
        XCTAssertEqual(count,3); XCTAssertEqual(checkpoint?.newlyDiscovered,0)
        XCTAssertEqual(first?.firstSeenAt,repeated?.firstSeenAt)
    }
    func testAddedAssetIsNew() async throws {
        let library = MockLibrary(); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store); _ = try await scanner.run()
        await library.replace(count:4) { AssetMetadata(localAssetID:"device-local-\($0)",mediaType:.image) }
        _ = try await scanner.run(); let checkpoint = try await store.checkpoint(); let count = try await store.rowCount()
        XCTAssertEqual(checkpoint?.newlyDiscovered,1); XCTAssertEqual(count,4)
    }
    func testRemovedAssetBecomesUnavailableWithoutDeletingRecord() async throws {
        let library = MockLibrary(); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store); _ = try await scanner.run()
        await library.replace(count:2) { AssetMetadata(localAssetID:"device-local-\($0)",mediaType:.image) }
        _ = try await scanner.run(); let removed = try await store.asset(localID:"device-local-2")
        let summary = try await store.summary(); let count = try await store.rowCount()
        XCTAssertEqual(removed?.state,.unavailable); XCTAssertEqual(count,3); XCTAssertEqual(summary.images,2)
        XCTAssertEqual(summary.unavailableAssets,1)
    }
    func testUnknownSizeIsNotZeroOrKnown() async throws {
        let library = MockLibrary(); let store = try SQLiteDiscoveredAssetStore(url:nil)
        _ = try await PhotoLibraryScanner(library:library,store:store).run()
        let summary = try await store.summary(); let asset = try await store.asset(localID:"device-local-0")
        XCTAssertNil(asset?.metadata.knownResourceBytes); XCTAssertEqual(summary.unknownSizeAssets,3)
        XCTAssertEqual(summary.knownSizeAssets,0)
    }
    func testAggregateCountsKnownZeroAndMixedUnknown() async throws {
        let sizes: [Int64?] = [100,250,nil,0]
        let library = MockLibrary(count:4) { AssetMetadata(localAssetID:"asset-\($0)",mediaType:.image,knownResourceBytes:sizes[$0]) }
        let store = try SQLiteDiscoveredAssetStore(url:nil); _ = try await PhotoLibraryScanner(library:library,store:store).run()
        let summary = try await store.summary()
        XCTAssertEqual(summary.knownResourceBytes,350); XCTAssertEqual(summary.knownSizeAssets,3); XCTAssertEqual(summary.unknownSizeAssets,1)
    }
    func testCancellationCommitsOnlyCompleteBatches() async throws {
        let library = MockLibrary(count:12); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store,batchSize:5)
        let task = Task { try await scanner.run { p in if p.processed == 5 { withUnsafeCurrentTask { $0?.cancel() } } } }
        let outcome = try await task.value
        guard case .cancelled(let summary) = outcome else { return XCTFail("Expected cancellation") }
        XCTAssertFalse(summary.isComplete); XCTAssertEqual(summary.observedAssets,5)
        let checkpoint = try await store.checkpoint(); XCTAssertEqual(checkpoint?.nextOffset,5)
    }
    func testResumeUsesSameSnapshotCursorAndDoesNotRepeatBatches() async throws {
        let library = MockLibrary(count:12); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store,batchSize:5)
        let task = Task { try await scanner.run { p in if p.processed == 5 { withUnsafeCurrentTask { $0?.cancel() } } } }
        _ = try await task.value; _ = try await scanner.run()
        let snapshot = await library.snapshot; let offsets = await snapshot.offsets
        let count = try await store.rowCount(); let summary = try await store.summary()
        XCTAssertEqual(offsets,[0,5,10]); XCTAssertEqual(count,12); XCTAssertTrue(summary.isComplete)
    }
    func testLargeLibraryUsesBoundedLinearBatches() async throws {
        let library = MockLibrary(count:100_001); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store,batchSize:250)
        _ = try await scanner.run()
        let snapshot = await library.snapshot; let offsets = await snapshot.offsets; let maxBatch = await snapshot.maxBatch
        let count = try await store.rowCount()
        XCTAssertEqual(offsets.count,401); XCTAssertLessThanOrEqual(maxBatch,250); XCTAssertEqual(count,100_001)
    }
    func testStatesCannotExpressProtectedOrBackupStatus() {
        XCTAssertEqual(Set(LocalDiscoveryState.allCases.map(\.rawValue)),Set(["visible","unavailable"]))
    }
    func testLocalIdentifierHasNoCloudIdentityFields() {
        let asset = AssetMetadata(localAssetID:"device-library-only",mediaType:.image)
        let fields = Set(Mirror(reflecting:asset).children.compactMap(\.label))
        XCTAssertTrue(fields.contains("localAssetID")); XCTAssertFalse(fields.contains("cloudObjectKey"))
        XCTAssertFalse(fields.contains("backupAssetID")); XCTAssertFalse(fields.contains("serverAssetID"))
    }
    func testResourceComponentSizingRequiresAllOriginalComponents() {
        XCTAssertEqual(OriginalResourceSizePolicy.total([20,80]),100)
        XCTAssertNil(OriginalResourceSizePolicy.total([20,nil])); XCTAssertNil(OriginalResourceSizePolicy.total([]))
        XCTAssertNil(OriginalResourceSizePolicy.total([Int64.max,1])); XCTAssertNil(OriginalResourceSizePolicy.total([-1]))
    }
    func testPermissionLossInvalidatesCachedVisibility() async throws {
        let library = MockLibrary(); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store); _ = try await scanner.run()
        await library.deny(); _ = try await scanner.run()
        let summary = try await store.summary(); let count = try await store.rowCount()
        XCTAssertEqual(summary.observedAssets,0); XCTAssertEqual(count,3)
    }
    func testChangedSnapshotNeverFinalizesMissingAssets() async throws {
        let library = MockLibrary(count:8); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store,batchSize:4)
        let outcome = try await scanner.run { p in if p.processed == 4 { await library.invalidateSnapshots() } }
        guard case .libraryChanged = outcome else { return XCTFail("Expected invalidation") }
        let checkpoint = try await store.checkpoint(); let summary = try await store.summary()
        XCTAssertNil(checkpoint); XCTAssertFalse(summary.isComplete); XCTAssertEqual(summary.observedAssets,0)
    }
    func testCancelledRescanDoesNotMarkUnseenRecordsUnavailable() async throws {
        let library = MockLibrary(count:8); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store,batchSize:4); _ = try await scanner.run()
        let task = Task { try await scanner.run { p in if p.processed == 4 { withUnsafeCurrentTask { $0?.cancel() } } } }
        _ = try await task.value
        let asset = try await store.asset(localID:"device-local-7"); XCTAssertEqual(asset?.state,.visible)
    }
    func testDiskPersistenceAndNewSessionRescanPreserveMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("metadata.sqlite")
        let library = MockLibrary(count:3)
        let first = try SQLiteDiscoveredAssetStore(url:url)
        _ = try await PhotoLibraryScanner(library:library,store:first).run()
        let original = try await first.asset(localID:"device-local-0")
        let reopened = try SQLiteDiscoveredAssetStore(url:url)
        await library.replace(count:3) { AssetMetadata(localAssetID:"device-local-\($0)",mediaType:.image) }
        _ = try await PhotoLibraryScanner(library:library,store:reopened).run()
        let asset = try await reopened.asset(localID:"device-local-0"); let count = try await reopened.rowCount()
        let checkpoint = try await reopened.checkpoint()
        XCTAssertEqual(asset?.firstSeenAt,original?.firstSeenAt); XCTAssertEqual(count,3); XCTAssertEqual(checkpoint?.newlyDiscovered,0)
    }
    func testEmptyCompletedLibrarySafelyReconcilesAllObservations() async throws {
        let library = MockLibrary(); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store); _ = try await scanner.run()
        await library.replace(count:0) { _ in AssetMetadata(localAssetID:"unused",mediaType:.image) }
        _ = try await scanner.run(); let summary = try await store.summary()
        XCTAssertTrue(summary.isComplete); XCTAssertEqual(summary.observedAssets,0); XCTAssertEqual(summary.unavailableAssets,3)
    }
    func testCancellationAfterPermissionLossCannotReturnCachedCounts() async throws {
        let library = MockLibrary(count:8); let store = try SQLiteDiscoveredAssetStore(url:nil)
        let scanner = PhotoLibraryScanner(library:library,store:store,batchSize:4)
        let task = Task {
            try await scanner.run { p in
                if p.processed == 4 {
                    await library.deny()
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let outcome = try await task.value
        guard case .noAccess(.denied) = outcome else { return XCTFail("Expected denied access instead of cached partial results") }
        let summary = try await store.summary(); XCTAssertEqual(summary.observedAssets,0)
    }
}
