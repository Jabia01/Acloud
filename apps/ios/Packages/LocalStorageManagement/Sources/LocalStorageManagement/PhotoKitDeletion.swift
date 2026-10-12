#if os(iOS)
import Foundation
import Photos
import UIKit
// No automatic capture/selection. Only an explicitly provisioned disposable fixture library may enter this adapter.
public actor PhotoKitDeletionAdapter:LocalPhotoLibrary {
 private let gate:CleanupGate,context:CleanupContext
 private let disposable:[String:LocalSnapshot]
 public init(gate:CleanupGate,context:CleanupContext,disposableSnapshots:[String:LocalSnapshot]=[:]){self.gate=gate;self.context=context;disposable=disposableSnapshots}
 private func permission()->CleanupPermission{switch PHPhotoLibrary.authorizationStatus(for:.readWrite){case .authorized:return .authorized;case .limited:return .limited;case .restricted:return .restricted;case .denied:return .denied;default:return .unknown}}
 public func read(_ ids:[String]) async throws -> LibraryRead{
  let access=permission();guard access == .authorized || access == .limited else{return LibraryRead(permission:access,snapshots:[:],presence:Dictionary(uniqueKeysWithValues:ids.map{($0,.inaccessible)}))}
  var snapshots:[String:LocalSnapshot]=[:],presence:[String:LocalPresence]=[:]
  let fetch=PHAsset.fetchAssets(withLocalIdentifiers:ids,options:nil);var assets:[String:PHAsset]=[:];fetch.enumerateObjects{asset,_,_ in assets[asset.localIdentifier]=asset}
  for id in ids{
   guard let a=assets[id] else{presence[id]=access == .authorized ? .absentConfirmed:.inaccessible;continue};presence[id] = .present
   let resources=PHAssetResource.assetResources(for:a)
   // Existing discovery/backup has no full destructive-cleanup manifest. Never infer it from metadata.
   var s=LocalSnapshot(localID:id,mediaType:a.mediaType == .video ? "video":"image",width:a.pixelWidth,height:a.pixelHeight,duration:a.mediaType == .video ? a.duration:nil,creation:a.creationDate,modification:a.modificationDate,resourceCount:resources.count)
   if let known=disposable[id],resources.count==1,let resource=resources.first,[.photo,.video].contains(resource.type),!resource.uniformTypeIdentifier.lowercased().contains("raw"),!a.mediaSubtypes.contains(.photoLive),known.mediaType==s.mediaType,known.width==s.width,known.height==s.height,known.duration==s.duration,known.creation==s.creation,known.modification==s.modification,known.manifestComplete,known.availability=="local"{
    s=known // Only a dedicated generated fixture harness can supply this already-captured resource evidence.
   }
   snapshots[id]=s
  }
  return LibraryRead(permission:access,snapshots:snapshots,presence:presence)
 }
 public func requestDeletion(_ candidates:[CleanupCandidate],context:CleanupContext) async throws {
  #if DEBUG
  guard gate.allows,context==self.context,!candidates.isEmpty,candidates.count<=10,candidates.allSatisfy({disposable[$0.backedUp.localID] != nil}),await MainActor.run(body:{UIApplication.shared.applicationState == .active}) else{throw CleanupFailure.disabled}
  let read=try await self.read(candidates.map{$0.backedUp.localID})
  guard FreeUpSpaceEligibilityService().scan(candidates,current:read.snapshots,context:context,permission:read.permission).eligibleCount==candidates.count else{throw CleanupFailure.localEvidence}
  let ids=candidates.map{$0.backedUp.localID};let assets=PHAsset.fetchAssets(withLocalIdentifiers:ids,options:nil)
  guard assets.count==candidates.count,permission()==read.permission,await MainActor.run(body:{UIApplication.shared.applicationState == .active}) else{throw CleanupFailure.localEvidence}
  try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in
   PHPhotoLibrary.shared().performChanges({
    // PhotoKit owns the system confirmation and library mutation. No direct library-file writes.
    PHAssetChangeRequest.deleteAssets(assets)
   },completionHandler:{success,_ in if success{c.resume()}else{c.resume(throwing:CleanupFailure.systemFailed)}})
  }
  #else
  throw CleanupFailure.disabled
  #endif
 }
}
#endif
