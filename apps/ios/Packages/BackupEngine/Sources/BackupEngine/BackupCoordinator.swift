import Foundation
import OSLog
import MediaPreservation
import UploadFoundation

public actor BackupCoordinator {
 public let queue:SQLiteBackupQueue
 private let api:any MultipartAPI
 private let transport:any PartTransport
 private let preparer:any ResourcePreparer
 private let files:ManagedTemporaryFiles
 private let onProtected:@Sendable() async->Void
 private let availableSpace:@Sendable(URL)throws->Int64?
 private let retry:RetryPolicy
 private let performance=Logger(subsystem:"com.acloud.transfers",category:"backup-performance")
 private let fileConcurrency:Int,partConcurrency:Int
 private var runningDue=false
 private var policy:BackupPolicy
 private var network=NetworkSnapshot(connected:false)
 private var active:[UUID:Task<Void,Error>]=[:]
 private var failureStages:[UUID:String]=[:]
 public init(queue:SQLiteBackupQueue,api:any MultipartAPI,transport:any PartTransport,preparer:any ResourcePreparer,files:ManagedTemporaryFiles,policy:BackupPolicy=BackupPolicy(),retry:RetryPolicy=RetryPolicy(),fileConcurrency:Int=2,partConcurrency:Int=2,availableSpace:@escaping @Sendable(URL)throws->Int64?={try $0.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage},onProtected:@escaping @Sendable() async->Void={}) {
  self.fileConcurrency=max(1,min(2,fileConcurrency));self.partConcurrency=max(1,min(2,partConcurrency))
  self.availableSpace=availableSpace
  self.queue=queue;self.api=api;self.transport=transport;self.preparer=preparer;self.files=files;self.policy=policy;self.retry=retry;self.onProtected=onProtected
 }
 public func setNetwork(_ value:NetworkSnapshot) async throws {
  network=value
  if !value.connected,transport.keepsTransfersDuringConnectionLoss{return}
  for id in Array(active.keys){if let item=try await queue.read(id),item.state != .paused,!policy.permits(item,network:value){try await pause(id,reason:"NETWORK_POLICY")}}
 }
 public func setPolicy(_ value:BackupPolicy) async throws {policy=value;try await setNetwork(network)}
 public func run(_ id:UUID) async throws {
  guard active[id]==nil else{return}
  guard !(await transport.activeItemIDs()).contains(id),active[id]==nil else{return}
  let task=Task{try await self.execute(id)};active[id]=task;defer{active[id]=nil;failureStages[id]=nil}
  try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
 }
 private func current(_ id:UUID) async throws -> BackupItem {
  try Task.checkCancellation();guard let item=try await queue.read(id) else{throw BackupFailure.missing}
  if item.state == .paused || item.state == .cancelled{throw CancellationError()};return item
 }
 private func transition(_ id:UUID,_ state:BackupState) async throws -> BackupItem {
  var item=try await current(id);item.state=state;return try await queue.save(item)
 }
 private func proof(_ id:UUID) async throws -> Bool {
  guard var item=try await queue.read(id),let assetID=item.assetID else{return false}
  let asset=try await api.asset(assetID)
  guard asset.status == .protected else{return false}
  // Re-read after network suspension. Do not overwrite a newer control operation.
  guard let latest=try await queue.read(id) else{throw BackupFailure.missing};item=latest;item.state = .protected;item.cancellationPending=false;item.lastErrorCode=nil;item.lastFailureStage=nil;item.nextRetryAt=nil
  var originalProof:OriginalServerProof?
  if var manifest=item.originalManifest {
   guard let verified=try await api.integrity(assetID),verified.id==assetID,manifest.matches(verified) else{throw BackupFailure.sourceChanged}
   originalProof=verified;manifest.cloudAssetID=verified.id;manifest.verificationID=verified.verificationId;item.originalManifest=manifest
  }
  if item.mediaResourceBinding != nil{guard let verified=try await api.integrity(assetID),verified.id==assetID,verified.checksum==item.expectedChecksum,verified.sizeBytes==item.expectedSizeBytes else{throw BackupFailure.sourceChanged};originalProof=verified}
  _=try await queue.protect(item,proof:asset,integrity:originalProof);await onProtected();try await preparer.cleanup(item);return true
 }
 private func execute(_ id:UUID) async throws {
  guard var item=try await queue.read(id) else{throw BackupFailure.missing}
  if item.state == .protected{try await preparer.cleanup(item);return}
  do {
   failureStages[id]="Checking saved backup"
   if try await proof(id){return}
   if item.state == .cancelled {
    if item.cancellationPending {
     // Stable queue ID is the idempotency key, including a lost create response.
     if item.sessionID==nil,item.expectedChecksum != nil {
      let session=try await api.create(item);item.sessionID=session.id;item.assetID=session.assetId;item=try await queue.save(item)
     }
     if let session=item.sessionID{try await api.cancel(session)}
     item.cancellationPending=false;_=try await queue.save(item)
    }
    try await preparer.cleanup(item);return
   }
   guard item.state != .paused,item.state != .failedPermanent else{return}
   if let due=item.nextRetryAt,due>Date(){return}
   // Reconcile completed server work before requesting the local original.
   if let sessionID=item.sessionID {
    failureStages[id]="Checking upload session"
    let remote=try await api.status(sessionID)
    if remote.status == .cancelled || remote.status == .expired{throw BackupFailure.http(410)}
    failureStages[id]="Reconciling interrupted transfer"
    let listing=try await api.parts(sessionID)
    if listing.completed {
     _=try await transition(id,.uploaded);_=try await transition(id,.verifying)
     try await verify(id,sessionID:sessionID);return
    }
   }
   guard policy.permits(item,network:network) else{try await pause(id,reason:"NETWORK_POLICY");return}
   let required=StorageSpace.required(bytes:Int64(item.expectedSizeBytes ?? 0),copies:1)
   if !StorageSpace.permits(available:try availableSpace(files.directory),required:required){throw BackupFailure.deviceSpace}
   _=try await transition(id,.preparing)
   failureStages[id]="Preparing original"
   let preparationStarted=Date()
   let resource=try await preparer.prepare(item,policy:policy,network:network)
   performance.info("phase=prepare durationMs=\(Int(Date().timeIntervalSince(preparationStarted)*1000)) bytes=\(resource.sizeBytes)")
   item=try await current(id)
   if let checksum=item.expectedChecksum,checksum != resource.checksum{throw BackupFailure.sourceChanged}
   if let size=item.expectedSizeBytes,size != resource.sizeBytes{throw BackupFailure.sourceChanged}
   item.originalManifest=resource.manifest ?? item.originalManifest;item.expectedSizeBytes=resource.sizeBytes;item.expectedChecksum=resource.checksum;item=try await queue.save(item)
   guard policy.permits(item,network:network) else{try await pause(id,reason:"NETWORK_POLICY");return}
   failureStages[id]="Starting upload session"
   let session=try await api.create(item)
   item=try await queue.read(id) ?? item;item.sessionID=session.id;item.assetID=session.assetId;item=try await queue.save(item)
   if try await proof(id){return}
   _=try await current(id)
   if session.status == .expired || session.status == .cancelled{throw BackupFailure.http(410)}
   failureStages[id]="Starting multipart upload"
   _=try await api.start(session.id)
   var listing=try await api.parts(session.id)
   if !listing.completed {
    guard let size=session.partSizeBytes,size>=5*1024*1024,size<=64*1024*1024 else{throw BackupFailure.unsupported}
    let count=(resource.sizeBytes+size-1)/size;guard count<=10000 else{throw BackupFailure.unsupported}
    try await queue.replaceParts(id,parts:listing.parts)
    _=try await transition(id,.uploading)
    let missing=(1...count).filter{number in !listing.parts.contains(where:{$0.partNumber==number})}
    // Reconcile once per bounded batch. Never persist competing, stale listings
    // from parallel requests, or prepare an unbounded number of temporary parts.
    for start in stride(from:0,to:missing.count,by:partConcurrency) {
     let batch=Array(missing[start..<min(start+partConcurrency,missing.count)])
     try await withThrowingTaskGroup(of:Void.self){group in
      for number in batch{group.addTask{try await self.transferPart(id,sessionID:session.id,resource:resource,number:number,size:size)}}
      try await group.waitForAll()
     }
     failureStages[id]="Checking received parts"
     listing=try await api.parts(session.id)
     try await queue.replaceParts(id,parts:listing.parts)
     item=try await current(id);item.bytesUploaded=listing.parts.reduce(0){$0+$1.sizeBytes};item=try await queue.save(item)
    }
    failureStages[id]="Completing uploaded parts"
    _=try await api.complete(session.id)
   }
   _=try await transition(id,.uploaded);_=try await transition(id,.verifying)
   try await verify(id,sessionID:session.id)
  } catch {
   guard var latest=try await queue.read(id) else{throw error}
   if [.paused,.cancelled,.protected].contains(latest.state){try await preparer.cleanup(latest);return}
   if error is CancellationError{return}
   if error as? BackupFailure == .cloudQuota || error as? BackupFailure == .deviceSpace || StorageSpace.isFull(error) {
    latest.state = .paused;latest.lastErrorCode=error as? BackupFailure == .cloudQuota ? "CLOUD_QUOTA_REQUIRED":"DEVICE_SPACE_REQUIRED";latest.nextRetryAt=nil
   } else if error as? BackupFailure == .waitingForOriginal || error as? BackupFailure == .inaccessible {
    latest.state = .paused;latest.lastErrorCode=error as? BackupFailure == .waitingForOriginal ? "WAITING_FOR_ICLOUD_ORIGINAL" : "LOCAL_ACCESS_UNAVAILABLE"
   } else {
    latest.retryCount+=1;let canRetry=retry.retryable(error) && latest.retryCount<retry.maximumAttempts
    latest.state=canRetry ? .failedRetryable : .failedPermanent
    latest.nextRetryAt=canRetry ? Date().addingTimeInterval(retry.delay(attempt:latest.retryCount)) : nil
    // Persist only bounded diagnostic codes, never server bodies or local media details.
    if let failure=error as? BackupFailure { latest.lastErrorCode=failure.diagnosticCode }
    else if let failure=error as? URLError { latest.lastErrorCode="NETWORK_\(failure.code.rawValue)" }
    else if error is DecodingError { latest.lastErrorCode="SERVER_RESPONSE_INVALID" }
    else { latest.lastErrorCode=canRetry ? "TRANSFER_RETRY" : "TRANSFER_REQUIRES_ACTION" }
   }
   latest.lastFailureStage=failureStages[id]
   _=try await queue.save(latest);try await preparer.cleanup(latest);throw error
  }
 }
 private func transferPart(_ id:UUID,sessionID:UUID,resource:PreparedResource,number:Int,size:Int)async throws {
  let item=try await current(id)
  guard policy.permits(item,network:network) else{try await pause(id,reason:"NETWORK_POLICY");throw CancellationError()}
  failureStages[id]="Preparing upload part"
  if !StorageSpace.permits(available:try availableSpace(files.directory),required:StorageSpace.required(bytes:Int64(size),copies:1)){throw BackupFailure.deviceSpace}
  let part=try files.part(resource,id:id,number:number,size:size)
  defer{try? files.remove(part.fileURL)}
  try await uploadPart(id,sessionID:sessionID,number:number,part:part)
 }
 // A background callback is a limited execution opportunity. Recover a dropped
 // connection here instead of relying solely on a foreground retry timer.
 private func uploadPart(_ id:UUID,sessionID:UUID,number:Int,part:PreparedResource)async throws {
  var recoveries=0
  while true {
   let item=try await current(id)
   guard policy.permits(item,network:network) else{try await pause(id,reason:"NETWORK_POLICY");throw CancellationError()}
   do {
    failureStages[id]="Getting upload permission"
    let auth=try await api.authorize(sessionID,number:number,size:part.sizeBytes,checksum:part.checksum)
    _=try await current(id)
    failureStages[id]="Transferring file bytes"
    let uploadStarted=Date()
    try await transport.upload(item:id,number:number,resource:part,authorization:auth,policy:policy)
    performance.info("phase=upload-part durationMs=\(Int(Date().timeIntervalSince(uploadStarted)*1000)) bytes=\(part.sizeBytes)")
    _=try await current(id)
    failureStages[id]="Checking received parts"
    return
   } catch {
    guard transport.keepsTransfersDuringConnectionLoss,
          let failure=error as? URLError,failure.code == .networkConnectionLost,
          recoveries<2 else{throw error}
    recoveries+=1
    try await Task.sleep(for:.seconds(recoveries))
    _=try await current(id)
    // A lost response may mean storage accepted the bytes. Never blindly resend.
    failureStages[id]="Reconciling interrupted transfer"
    let listing=try await api.parts(sessionID)
    _=try await current(id)
    if listing.completed || listing.parts.contains(where:{$0.partNumber==number}){return}
    // Missing parts receive a new short-lived authorization on the next pass.
   }
  }
 }
 private func verify(_ id:UUID,sessionID:UUID) async throws {
  failureStages[id]="Verifying saved backup"
  let verificationStarted=Date()
  defer{performance.info("phase=verify durationMs=\(Int(Date().timeIntervalSince(verificationStarted)*1000))")}
  let result=try await api.verify(sessionID)
  if try await proof(id){return}
  if result.status == .failed {
   if result.errorCode == "STORAGE_UNAVAILABLE"{throw BackupFailure.http(503)}
   throw BackupFailure.sourceChanged
  }
  if result.status == .cancelled || result.status == .expired{throw BackupFailure.http(410)}
  // Lease may be owned by another verifier. Schedule a bounded later poll.
  var item=try await current(id);item.retryCount+=1
  if item.retryCount>=retry.maximumAttempts{throw BackupFailure.retryLimit}
  item.nextRetryAt=Date().addingTimeInterval(retry.delay(attempt:item.retryCount));_=try await queue.save(item)
 }
 public func pause(_ id:UUID,reason:String="USER_PAUSED") async throws {
  guard var item=try await queue.read(id),![.protected,.cancelled].contains(item.state) else{return}
  item.state = .paused;item.lastErrorCode=reason;_=try await queue.save(item);active[id]?.cancel();await transport.cancel(item:id)
 }
 public func resume(_ id:UUID) async throws {
  guard var item=try await queue.read(id),item.state == .paused else{return}
  item.state = .queued;item.nextRetryAt=nil;item.lastErrorCode=nil;item.lastFailureStage=nil;_=try await queue.save(item)
 }
 public func retryFailed(_ id:UUID) async throws {
  guard var item=try await queue.read(id),[.failedPermanent,.failedRetryable].contains(item.state) else{return}
  if item.lastErrorCode == "SESSION_EXPIRED" {
   if try await proof(id){return}
   item.uploadKey=UUID();item.sessionID=nil;item.assetID=nil;item.bytesUploaded=0;try await queue.replaceParts(id,parts:[])
  }
  item.state = .queued;item.retryCount=0;item.nextRetryAt=nil;item.lastErrorCode=nil;item.lastFailureStage=nil;_=try await queue.save(item)
 }
 public func settleCancellation(_ id:UUID)async throws->BackupItem {
  guard let old=try await queue.read(id),old.state == .cancelled else{throw BackupFailure.illegalTransition}
  await transport.cancel(item:id)
  if let running=active[id]{_=try? await running.value}
  // Resolve a lost create/cancel response, or a verification that already won.
  try await run(id)
  guard let settled=try await queue.read(id),settled.state == .protected || settled.state == .cancelled && !settled.cancellationPending else{throw BackupFailure.http(503)}
  return settled
 }
 public func restartCancelled(_ id:UUID)async throws->UUID {
  let settled=try await settleCancellation(id)
  if settled.state == .protected{return settled.id}
  if let latest=try await queue.find(library:settled.libraryID,localID:settled.localAssetIdentifier),latest.id != id {
   if latest.state == .cancelled{return try await restartCancelled(latest.id)}
   return latest.id
  }
  return try await queue.enqueueAgain(afterCancelled:id)
 }
 public func cancel(_ id:UUID) async throws {
  guard var item=try await queue.read(id),item.state != .protected else{return}
  item.state = .cancelled;item.cancellationPending=true;_=try await queue.save(item);let running=active[id];running?.cancel();await transport.cancel(item:id)
  // Cancel response races are reconciled on startup, never overwrite newer state.
  if let session=item.sessionID{try await api.cancel(session);if var latest=try await queue.read(id),latest.state == .cancelled{latest.cancellationPending=false;_=try await queue.save(latest)}}
  // Let the worker finish any PhotoKit write and its cleanup before final deletion.
  if let running{_=try? await running.value}
  try await preparer.cleanup(item)
 }
 public func pauseAll() async throws {try await each{try await self.pause($0.id)}}
 public func resumeAll() async throws {try await each{try await self.resume($0.id)}}
 public func retryAllFailed() async throws {try await each{try await self.retryFailed($0.id)}}
 private func each(_ work:(BackupItem) async throws -> Void) async throws {
  var cursor:UUID?;while true{let page=try await queue.page(after:cursor);if page.isEmpty{return};for item in page{try await work(item)};cursor=page.last?.id}
 }
 public func reconcileStartup() async throws {
  // Preserve daemon-owned files and transfers. Explicit paused/cancelled states still stop them.
  let transferring=await transport.activeItemIDs()
  for id in transferring {
   let item=try await queue.read(id)
   if item == nil || item?.state == .paused || item?.state == .cancelled {await transport.cancel(item:id)}
  }
  try await each { item in
   if self.active[item.id] != nil{return}
   if (await self.transport.activeItemIDs()).contains(item.id){return}
   if item.state == .protected{try await self.preparer.cleanup(item);return}
   do {if try await self.proof(item.id){return}} catch {/* Retain remote identities on outage; next run retries. */}
   if item.state == .cancelled{try await self.run(item.id);return}
   if [.preparing,.uploading].contains(item.state){var latest=try await self.queue.read(item.id) ?? item;latest.state = .queued;_=try await self.queue.save(latest)}
   // The foreground scheduler rechecks storage parts and completion before retransmission.
   if [.paused,.failedPermanent,.failedRetryable,.cancelled].contains(item.state){try await self.preparer.cleanup(item)}
  }
  // Crash before queue commit may leave an opaque managed file with no queue record.
  for url in try FileManager.default.contentsOfDirectory(at:files.directory,includingPropertiesForKeys:nil) {
   let name=url.lastPathComponent
   guard name.hasSuffix(".bin"),let id=UUID(uuidString:String(name.prefix(36))) else{continue}
   if try await queue.read(id)==nil{try files.remove(url)}
  }
 }
 private func resumeNetworkPauses() async throws {
  try await each { snapshot in
   guard snapshot.state == .paused,snapshot.lastErrorCode == "NETWORK_POLICY",self.active[snapshot.id] == nil else{return}
   guard !(await self.transport.activeItemIDs()).contains(snapshot.id),self.active[snapshot.id] == nil else{return}
   // Recheck after suspension: a user pause or cancellation must win.
   guard let latest=try await self.queue.read(snapshot.id),latest.state == .paused,
         latest.lastErrorCode == "NETWORK_POLICY",self.active[snapshot.id] == nil,
         self.policy.permits(latest,network:self.network) else{return}
   var ready=latest;ready.state = .queued;ready.nextRetryAt=nil;ready.lastErrorCode=nil
   _=try await self.queue.save(ready)
  }
 }
 public func runDue() async throws {
  guard !runningDue else{return};runningDue=true;defer{runningDue=false}
  // Recovery waits until the cancelled worker/daemon transfer has drained.
  try await resumeNetworkPauses()
  let items=try await queue.due()
  await withTaskGroup(of:Void.self){group in
   var index=0
   func next(){guard index<items.count else{return};let id=items[index].id;index+=1;group.addTask{do{try await self.run(id)}catch{/* Durable sanitized error already recorded. */}}}
   for _ in 0..<fileConcurrency{next()}
   while await group.next() != nil{if !Task.isCancelled{next()}}
  }
 }
}
