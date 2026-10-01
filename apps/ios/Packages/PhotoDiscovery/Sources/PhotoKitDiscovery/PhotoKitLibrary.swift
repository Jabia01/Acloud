#if os(iOS)
import Foundation
@preconcurrency import Photos
import UIKit
import DiscoveryCore

private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let changed: @Sendable (PHChange) -> Void
    init(changed: @escaping @Sendable (PHChange) -> Void) { self.changed = changed }
    func photoLibraryDidChange(_ changeInstance: PHChange) { changed(changeInstance) }
}

private actor MetadataSnapshot: PhotoLibrarySnapshot {
    nonisolated let key: String
    nonisolated let total: Int
    private let result: PHFetchResult<PHAsset>
    init(key: String, result: PHFetchResult<PHAsset>) { self.key = key; self.total = result.count; self.result = result }
    func batch(offset: Int, limit: Int) throws -> [AssetMetadata] {
        guard offset >= 0, offset <= total, limit > 0, limit <= 1000 else { throw DiscoveryError.inconsistentSnapshot }
        return try autoreleasepool {
            var metadata: [AssetMetadata] = []
            metadata.reserveCapacity(min(limit,total-offset))
            for index in offset..<min(total,offset+limit) {
                try Task.checkCancellation()
                let asset = result.object(at:index)
                let type: DiscoveredMediaType = asset.mediaType == .video ? .video : .image
                metadata.append(AssetMetadata(localAssetID:asset.localIdentifier,mediaType:type,
                    creationDate:asset.creationDate,modificationDate:asset.modificationDate,
                    pixelWidth:asset.pixelWidth,pixelHeight:asset.pixelHeight,
                    duration:type == .video ? asset.duration : nil,knownResourceBytes:Self.originalSize(asset)))
            }
            return metadata
        }
    }
    private static func originalSize(_ asset: PHAsset) -> Int64? {
        // OFF by default: this public metadata property requires an iOS 27 SDK.
        // Older SDKs must not use KVC/private fileSize or fetch content to fill nil.
        #if PHOTOKIT_RESOURCE_SIZE_METADATA
        if #available(iOS 27.0, *) {
            let originals = PHAssetResource.assetResources(for:asset).filter {
                $0.type == .photo || $0.type == .video || $0.type == .pairedVideo || $0.type == .alternatePhoto
            }
            return OriginalResourceSizePolicy.total(originals.map { $0.dataSize.map(Int64.init) })
        }
        #endif
        return nil
    }
}

public actor PhotoKitLibrary: PhotoLibraryProvider {
    private let sessionID = UUID().uuidString
    private var revision = 0
    private var fetch: PHFetchResult<PHAsset>?
    private var observer: LibraryObserver?
    private var handler: (@Sendable () -> Void)?
    private var permissionRequest: Task<LibraryAuthorization,Never>?
    public init() {}
    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .restricted
        }
    }
    public func authorization() -> LibraryAuthorization { Self.map(PHPhotoLibrary.authorizationStatus(for:.readWrite)) }
    public func requestAccess() async -> LibraryAuthorization {
        if let permissionRequest { return await permissionRequest.value }
        let current = authorization()
        guard current == .notDetermined else { return current }
        let request = Task { Self.map(await PHPhotoLibrary.requestAuthorization(for:.readWrite)) }
        permissionRequest = request
        let state = await request.value
        permissionRequest = nil
        revision += 1; fetch = nil
        return state
    }
    private var snapshotKey: String { "\(sessionID):\(revision):\(authorization().rawValue)" }
    public func openSnapshot() throws -> any PhotoLibrarySnapshot {
        guard authorization().canRead else { throw DiscoveryError.inconsistentSnapshot }
        if observer == nil {
            let observer = LibraryObserver { [weak self] change in Task { await self?.changed(change) } }
            self.observer = observer; PHPhotoLibrary.shared().register(observer)
        }
        if fetch == nil {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format:"mediaType == %d OR mediaType == %d",PHAssetMediaType.image.rawValue,PHAssetMediaType.video.rawValue)
            options.includeAllBurstAssets = true
            options.includeHiddenAssets = false
            options.wantsIncrementalChangeDetails = false
            fetch = PHAsset.fetchAssets(with:options)
        }
        guard let fetch else { throw DiscoveryError.inconsistentSnapshot }
        return MetadataSnapshot(key:snapshotKey,result:fetch)
    }
    public func snapshotIsCurrent(_ key: String) -> Bool { authorization().canRead && key == snapshotKey }
    public func invalidateSnapshots() { revision += 1; fetch = nil }
    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        self.handler = handler
        if handler == nil, let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer); self.observer = nil; fetch = nil }
    }
    private func changed(_ change: PHChange) {
        // PhotoKit delivers on an arbitrary queue; actor serialization protects revision.
        if let fetch, let details = change.changeDetails(for:fetch) { self.fetch = details.fetchResultAfterChanges }
        else { fetch = nil }
        revision += 1
        handler?()
    }
    deinit { if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) } }
}

@MainActor public enum PhotoLibraryAccessUI {
    public static func manageLimitedAccess(from controller: UIViewController, completion: @escaping () -> Void) {
        guard PHPhotoLibrary.authorizationStatus(for:.readWrite) == .limited else { completion(); return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from:controller) { _ in completion() }
    }
}
#endif
