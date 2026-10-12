import Foundation
import DiscoveryCore
public enum BackupDecision: Sendable, Equatable {case intentionallyRemoved,alreadyQueued,alreadyProtected,needsBackup,inaccessible,waitingForResource,excludedByPolicy}
public struct BackupPlanner: Sendable {
 public let queue:SQLiteBackupQueue
 public init(queue:SQLiteBackupQueue){self.queue=queue}
 public func decision(_ asset:StoredDiscoveredAsset,library:UUID,policy:BackupPolicy,network:NetworkSnapshot) async throws -> BackupDecision {
  if let item=try await queue.find(library:library,localID:asset.metadata.localAssetID){
   if item.state == .protected && item.localRemovedAfterProtection==true{return .intentionallyRemoved}
   if item.state == .protected{return .alreadyProtected}
   if item.state == .paused && item.lastErrorCode == "WAITING_FOR_ICLOUD_ORIGINAL"{return .waitingForResource}
   if item.state == .cancelled{return .excludedByPolicy}
   return .alreadyQueued
  }
  guard asset.state == .visible else{return .inaccessible}
  var item=BackupItem(libraryID:library,localAssetIdentifier:asset.metadata.localAssetID,mediaType:asset.metadata.mediaType.rawValue)
  item.expectedSizeBytes=asset.metadata.knownResourceBytes.map(Int.init)
  guard policy.permits(item,network:network) else{return .excludedByPolicy}
  return .needsBackup // Availability remains unknown until original resource request.
 }
 public func enqueueExplicit(_ asset:StoredDiscoveredAsset,library:UUID,developmentEnabled:Bool) async throws -> UUID {
  guard developmentEnabled,asset.state == .visible else{throw BackupFailure.inaccessible}
  return try await queue.enqueue(BackupItem(libraryID:library,localAssetIdentifier:asset.metadata.localAssetID,mediaType:asset.metadata.mediaType.rawValue))
 }
}
