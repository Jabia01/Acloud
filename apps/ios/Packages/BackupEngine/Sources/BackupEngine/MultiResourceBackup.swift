import Foundation
import CryptoKit
import MediaPreservation
public protocol MediaResourceSource:Sendable{
 func snapshot(_ localID:String)async throws->MediaSourceSnapshot
 func stream(_ localID:String,descriptor:ResourceDescriptor,to:URL,allowNetwork:Bool,progress:@escaping @Sendable(Double)->Void)async throws
}
public struct MultiResourcePreparer:ResourcePreparer{
 private let invalidate:@Sendable(UUID,String)async->Void
 private let source:any MediaResourceSource,store:ManifestStore,files:ManagedTemporaryFiles,binding:ManifestBinding
 public init(source:any MediaResourceSource,store:ManifestStore,files:ManagedTemporaryFiles,binding:ManifestBinding,invalidate:@escaping @Sendable(UUID,String)async->Void={_,_ in}){self.invalidate=invalidate;self.source=source;self.store=store;self.files=files;self.binding=binding}
 public func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot)async throws->PreparedResource{
  guard let r=item.mediaResourceBinding,r.binding==binding,item.accountID==binding.accountID,item.deviceID==binding.deviceID,item.libraryID==binding.libraryID,var manifest=try await store.read(r.manifestID),manifest.binding==binding else{throw BackupFailure.authorization}
  if manifest.state == .sourceChanged{if let pending=manifest.changedFingerprint{await invalidate(manifest.id,pending)};throw BackupFailure.sourceChanged}
  let before=try await source.snapshot(r.sourceLocalID);guard manifest.matches(before),before.fingerprint==r.sourceFingerprint,manifest.state != .sourceChanged else{manifest.state = .sourceChanged;manifest.changedFingerprint=before.fingerprint;_=try await store.save(manifest);await invalidate(manifest.id,before.fingerprint);throw BackupFailure.sourceChanged}
  guard let index=manifest.resources.firstIndex(where:{$0.id==r.resourceID}),manifest.resources[index].descriptor==r.descriptor else{throw BackupFailure.sourceChanged}
  let target=files.url(item.id);try files.remove(target)
  do{do{try await source.stream(r.sourceLocalID,descriptor:r.descriptor,to:target,allowNetwork:false,progress:{_ in})}catch BackupFailure.waitingForOriginal{
    manifest.resources[index].waitingForNetwork=true;manifest.state = .partial;_=try await store.save(manifest)
    guard policy.allowICloudOriginals,network.connected,network.wifi,!network.cellular,!network.constrained else{throw BackupFailure.waitingForOriginal}
    try files.remove(target);try await source.stream(r.sourceLocalID,descriptor:r.descriptor,to:target,allowNetwork:true,progress:{_ in})
   }
   try files.secure(target);let file=try StreamingIntegrity.inspect(target);guard manifest.matches(try await source.snapshot(r.sourceLocalID)) else{manifest.state = .sourceChanged;manifest.changedFingerprint=before.fingerprint;_=try await store.save(manifest);throw BackupFailure.sourceChanged}
   // Re-read after suspended PhotoKit requests; never overwrite another resource's captured evidence.
   guard var latest=try await store.read(manifest.id),latest.source==manifest.source,latest.state != .sourceChanged else{throw BackupFailure.sourceChanged}
   if let old=latest.resources[index].expectedSha256,old != file.checksum||latest.resources[index].expectedSize != file.sizeBytes{latest.state = .sourceChanged;let changed=SHA256.hash(data:Data((r.sourceFingerprint+":"+file.checksum).utf8)).map{String(format:"%02x",$0)}.joined();latest.changedFingerprint=changed;_=try await store.save(latest);await invalidate(latest.id,changed);throw BackupFailure.sourceChanged}
   latest.resources[index].expectedSize=file.sizeBytes;latest.resources[index].expectedSha256=file.checksum;latest.resources[index].waitingForNetwork=false;latest.state=latest.completeLocal ? .completeLocal:.partial;_=try await store.save(latest)
   return file
  }catch{if error as? BackupFailure == .sourceChanged,let fresh=try? await source.snapshot(r.sourceLocalID){await invalidate(manifest.id,fresh.fingerprint)};try? files.remove(target);throw error}
 }
 public func cleanup(_ item:BackupItem)async throws{try files.cleanup(item.id)}
}
public struct MultiResourceBackupPlanner:Sendable{
 public let store:ManifestStore,queue:SQLiteBackupQueue
 public init(store:ManifestStore,queue:SQLiteBackupQueue){self.store=store;self.queue=queue}
 // Prefer the current live/protected version over matching cancelled history.
 public func existing(source:MediaSourceSnapshot,binding:ManifestBinding)async throws->MediaManifest? {
  var cursor:UUID?,cancelled:MediaManifest?
  while true {
   let page=try await store.page(binding:binding,after:cursor,limit:100)
   for manifest in page where manifest.source.localID==source.localID && manifest.matches(source) && manifest.state != .sourceChanged {
    var hasCancelled=false
    for resource in manifest.resources {if try await queue.read(resource.id)?.state == .cancelled{hasCancelled=true;break}}
    if !hasCancelled{return manifest}
    if cancelled==nil{cancelled=manifest}
   }
   if page.count<100{return cancelled};cursor=page.last?.id
  }
 }
 public func captureExplicit(source:MediaSourceSnapshot,binding:ManifestBinding)async throws->MediaManifest{let manifest=MediaManifest(binding:binding,source:source);try await store.insert(manifest);return manifest}
 public func enqueue(_ manifest:MediaManifest,binding:ManifestBinding)async throws->[UUID]{guard manifest.binding==binding,manifest.manifestVersion==1,manifest.source.enumerationValid,manifest.state != .sourceChanged else{throw BackupFailure.unsupported};var ids:[UUID]=[];for r in manifest.resources{if r.status=="PROTECTED"{continue};var item=BackupItem(libraryID:binding.libraryID,localAssetIdentifier:r.id.uuidString,mediaType:[2,6,9,10,11,12].contains(r.descriptor.resourceType) ? "video":[1,4,5,8,19].contains(r.descriptor.resourceType) ? "image":"test",id:r.id);item.accountID=binding.accountID;item.deviceID=binding.deviceID;item.mediaResourceBinding=ManifestResourceBinding(manifest:manifest,resource:r);ids.append(try await queue.enqueue(item))};return ids}
}

public struct PreservationResourcePreparer:ResourcePreparer{private let ordinary:any ResourcePreparer,multiple:any ResourcePreparer;public init(ordinary:any ResourcePreparer,multiple:any ResourcePreparer){self.ordinary=ordinary;self.multiple=multiple};public func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot)async throws->PreparedResource{try await (item.mediaResourceBinding==nil ? ordinary:multiple).prepare(item,policy:policy,network:network)};public func cleanup(_ item:BackupItem)async throws{try await (item.mediaResourceBinding==nil ? ordinary:multiple).cleanup(item)}}
