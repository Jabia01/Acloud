import Foundation
import MediaPreservation
public actor CompoundRestoreCoordinator{
 private let queue:CompoundRestoreQueue,files:RestoreFiles,api:any CompoundRestoreAPI,downloader:any RestoreDownloader,photos:any CompoundPhotoLibraryRestorer,capacity:any DeviceCapacity
 private var account:UUID?,library:UUID?,active:Task<Void,Error>?,activeID:UUID?
 public init(queue:CompoundRestoreQueue,files:RestoreFiles,api:any CompoundRestoreAPI,downloader:any RestoreDownloader,photos:any CompoundPhotoLibraryRestorer,capacity:any DeviceCapacity=SystemDeviceCapacity()){self.queue=queue;self.files=files;self.api=api;self.downloader=downloader;self.photos=photos;self.capacity=capacity}
 public func activate(account:UUID,library:UUID)async throws{if self.account != account||self.library != library{await deactivate();self.account=account;self.library=library};try await reconcile()}
 public func deactivate()async{account=nil;library=nil;if let id=activeID,(try? await queue.read(id))?.state != .saving{active?.cancel()};await downloader.cancel();_=try? await active?.value;active=nil;activeID=nil}
 private func bound(_ r:CompoundRestoreRecord)throws{try Task.checkCancellation();guard account==r.account,library==r.library else{throw RestoreFailure.authorization}}
 private func latest(_ id:UUID)async throws->CompoundRestoreRecord{guard let r=try await queue.read(id) else{throw RestoreFailure.missing};try bound(r);return r}
 private func move(_ id:UUID,_ state:RestoreState)async throws->CompoundRestoreRecord{var r=try await latest(id);r.state=state;return try await queue.save(r)}
 private func verifier(_ r:CompoundRestoreRecord,_ resource:CompoundPlanResource)throws{guard let id=r.fileIDs[resource.id] else{throw RestoreFailure.missing};let item=RestoreItem(accountID:r.account,libraryID:r.library,evidence:resource.evidence,id:id);try files.verify(item)}
 private func downloadResource(_ record:CompoundRestoreRecord,_ resource:CompoundPlanResource)async throws {
  try bound(record)
  let authorization=try await api.compoundAuthorization(manifest:record.plan.manifest.id,resource:resource,fingerprint:record.plan.manifest.manifestFingerprint)
  guard authorization.evidence==resource.evidence,let fileID=record.fileIDs[resource.id] else{throw RestoreFailure.versionChanged}
  try bound(record)
  // Reuse completed resources only after fresh admission and a new checksum check.
  if (try? verifier(record,resource)) != nil{return}
  try files.remove(fileID,includingPartial:false)
  try await downloader.download(authorization.authorization,to:files.url(fileID),expectedSize:resource.evidence.expectedSize,progress:{_ in})
 }
 private func remove(_ r:CompoundRestoreRecord)throws{for id in r.fileIDs.values{try files.remove(id)}}
 public func runDue()async{guard active==nil,let account,let library else{return};var cursor:UUID?;while let page=try? await queue.page(account:account,library:library,after:cursor,limit:50),!page.isEmpty{for r in page where r.state == .queued || r.state == .retryable || r.state == .ready{guard self.account==account,self.library==library,!Task.isCancelled else{return};try? await run(r.id)};cursor=page.last?.id}}
 public func run(_ id:UUID)async throws{guard active==nil else{return};let task=Task{try await self.execute(id)};active=task;activeID=id;defer{active=nil;activeID=nil};try await task.value}
 private func execute(_ id:UUID)async throws{var r=try await latest(id);guard [.queued,.retryable,.ready].contains(r.state),r.plan.valid,r.plan.reconstructable else{return};do{
   let bytes=r.plan.resources.reduce(Int64(0)){$0+Int64($1.evidence.expectedSize)};if let free=try capacity.available(at:files.directory),free<StorageSpace.required(bytes:bytes,copies:r.state == .ready ? 1:2){r.state = .paused;r.lastErrorCode="DEVICE_SPACE_REQUIRED";_=try await queue.save(r);return}
   if r.state != .ready{r=try await move(id,.authorizing);let plan=try await api.compoundPlan(r.plan.manifest.id,fingerprint:r.plan.manifest.manifestFingerprint,choice:r.plan.choice);guard plan==r.plan,plan.valid else{throw RestoreFailure.versionChanged};r=try await move(id,.downloading)
    let record=r
    for start in stride(from:0,to:r.plan.resources.count,by:2){
     let resources=Array(r.plan.resources[start..<min(start+2,r.plan.resources.count)])
     try await withThrowingTaskGroup(of:Void.self){group in
      for resource in resources{group.addTask{try await self.downloadResource(record,resource)}}
      try await group.waitForAll()
     }
    }
    r=try await move(id,.verifying);for resource in r.plan.resources{try verifier(r,resource)};r=try await move(id,.ready)
   }
   if let free=try capacity.available(at:files.directory),free<StorageSpace.required(bytes:bytes,copies:1){throw RestoreFailure.deviceSpace}
   for resource in r.plan.resources{try verifier(r,resource)};guard await photos.canSave() else{throw RestoreFailure.permission};let resources=r.plan.resources.map{CompoundSaveResource(role:$0.role,resourceType:$0.resourceType,uti:$0.uti,file:files.url(r.fileIDs[$0.id]!))};try await photos.validate(resources);let final=try await api.compoundPlan(r.plan.manifest.id,fingerprint:r.plan.manifest.manifestFingerprint,choice:r.plan.choice);guard final.valid,final==r.plan else{throw RestoreFailure.versionChanged};r=try await move(id,.saving);try bound(r)
   let local=try await photos.save(resources);guard var saved=try await queue.read(id) else{throw RestoreFailure.ambiguousSave};saved.localIdentifier=local;saved=try await queue.save(saved);_=try await queue.save(saved,completedIdentifier:local);try remove(saved)
  }catch{guard var failed=try await queue.read(id),![.restored,.cancelled].contains(failed.state) else{throw error};if failed.state == .saving{failed.state = .reconcile;failed.lastErrorCode="SAVE_RESULT_UNCERTAIN"}else if error as? RestoreFailure == .deviceSpace || StorageSpace.isFull(error){failed.state = .paused;failed.lastErrorCode="DEVICE_SPACE_REQUIRED"}else if error is CancellationError||account==nil||error as? RestoreFailure == .permission{failed.state = .paused}else{failed.state = .permanent;failed.lastErrorCode="COMPLETE_RESTORE_FAILED"};_=try await queue.save(failed);throw error}}
 public func pause(_ id:UUID)async throws{var r=try await latest(id);guard ![.saving,.reconcile,.restored,.cancelled].contains(r.state) else{return};r.state = .paused;_=try await queue.save(r);if activeID==id{active?.cancel();_=try? await active?.value}}
 public func resume(_ id:UUID)async throws{var r=try await latest(id);guard [.paused,.retryable,.permanent].contains(r.state) else{throw RestoreFailure.ambiguousSave};r.state = .queued;_=try await queue.save(r)}
 public func cancel(_ id:UUID)async throws{try await pause(id);var r=try await latest(id);guard r.state == .paused else{throw RestoreFailure.ambiguousSave};r.state = .cancelled;r=try await queue.save(r);try remove(r)}
 public func reconcile()async throws{guard active==nil,let account,let library else{return};var cursor:UUID?;while true{let page=try await queue.page(account:account,library:library,after:cursor);if page.isEmpty{break};for var r in page{if [.restored,.cancelled].contains(r.state){try? remove(r)}else if [.saving,.reconcile].contains(r.state){if let local=r.localIdentifier,await photos.presence(local) == .exists{_=try await queue.save(r,completedIdentifier:local);try? remove(r)}else if r.state == .saving{r.state = .reconcile;_=try await queue.save(r)}}else if [.authorizing,.downloading,.verifying].contains(r.state){r.state = .queued;_=try await queue.save(r)}};cursor=page.last?.id}}
}
