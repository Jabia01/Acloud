import SwiftUI
import UIKit
import BackupEngine
import MediaPreservation
import HealthClient
import Photos
import PhotosUI

private extension BackupState {
 var displayTitle:String {
  switch self {
  case .discovered: return "Ready to back up"
  case .queued: return "Waiting to start"
  case .preparing: return "Preparing original"
  case .uploading: return "Backing up"
  case .uploaded, .verifying: return "Checking backup"
  case .protected: return "Protected"
  case .paused: return "Paused"
  case .failedRetryable: return "Backup interrupted"
  case .failedPermanent: return "Backup needs attention"
  case .cancelled: return "Cancelled"
  }
 }
}

private func backupGuidance(_ item:BackupItem)->String? {
 if item.lastErrorCode == "NETWORK_POLICY" {return "Waiting for an allowed connection. Backup resumes automatically when Wi-Fi returns and Low Data Mode allows transfers."}
 if item.lastErrorCode == "WAITING_FOR_ICLOUD_ORIGINAL" { return "This original is in iCloud. Allow downloads over Wi-Fi, then resume. Your original stays in Photos." }
 if ["AUTHENTICATION_REQUIRED","HTTP_401"].contains(item.lastErrorCode ?? "") { return "Sign in again from Account, then resume this backup. Your queued items and saved progress are kept." }
 if item.lastErrorCode == "SESSION_EXPIRED" { return "The upload window expired. Retry this backup to start a new upload attempt." }
 if item.lastErrorCode == "HTTP_503" { return "Acloud is temporarily unavailable. Keep your original and retry later." }
 if item.lastErrorCode == "HTTP_403" { return "This backup request was not allowed. Check your account access or contact support." }
 if item.lastErrorCode == "CLOUD_QUOTA_REQUIRED" {return "Your Acloud storage is full for this backup. Review Storage and pending transfers, then resume. Freeing space on this iPad does not increase your Acloud allowance."}
 if item.lastErrorCode == "DEVICE_SPACE_REQUIRED" {return "This iPad needs more free space to prepare the backup. Free some device space, then resume. Your original stays in Photos."}
 if item.lastErrorCode == "HTTP_409" { return "Acloud could not accept this backup in its current state. Retry once; contact support if it continues." }
 switch item.state {
 case .failedRetryable: return "The backup has not been verified. Keep your original and retry when your connection is available."
 case .failedPermanent: return "The backup could not finish. Keep your original. You can retry or contact support."
 case .uploaded, .verifying: return "Upload received. Keep your original while Acloud checks the stored file."
 case .protected: return nil
 case .cancelled: return "This transfer was cancelled. Your original remains in Photos."
 default: return nil
 }
}

@MainActor private final class BackupBackgroundTime {
 private var identifier:UIBackgroundTaskIdentifier = .invalid
 func begin(expiration:(()->Void)?=nil){guard identifier == .invalid else{return};identifier=UIApplication.shared.beginBackgroundTask(withName:"Finish backup step"){[weak self] in expiration?();self?.end()}}
 func end(){guard identifier != .invalid else{return};UIApplication.shared.endBackgroundTask(identifier);identifier = .invalid}
}
#if DEBUG
private struct DevelopmentTestPreparer: ResourcePreparer {
 let generated: GeneratedResourcePreparer
 let photos: PhotoKitResourcePreparer
 func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot) async throws -> PreparedResource {
  if item.mediaType == "test" { return try await generated.prepare(item,policy:policy,network:network) }
  guard ["image","video"].contains(item.mediaType) else { throw BackupFailure.unsupported }
  return try await photos.prepare(item,policy:policy,network:network)
 }
 func cleanup(_ item:BackupItem) async throws {
  if item.mediaType == "test" { try await generated.cleanup(item) }
  else { try await photos.cleanup(item) }
 }
}
#endif

@MainActor final class BackupQueueModel:ObservableObject {
 static let shared=BackupQueueModel()
 @Published var summary:[BackupState:Int]=[:]
 @Published var items:[BackupItem]=[]
 @Published var manifests:[MediaManifest]=[]
 @Published var message="Sign in to start backing up."
 @Published var busy=false
 @Published var canSelectOriginals=false
 @Published private(set) var complexBackupTestAvailable=false
 @Published var originalProgress:Double=0
 @Published var selectionNotice:String?
 @Published var hasOlderTransfers=false
 @Published var showingOlderTransfers=false
 private var scanningAlerts=false
 private var alertsSuspended=false
 private var transferAnchor:BackupItem?
 @Published var allowICloudOriginals=false
 private var deviceID:UUID?
 private var manifestReconcileCursor:UUID?
 private var manifestStore:ManifestStore?
 private var manifestAPI:HTTPMultipartAPI?
 private var preservationBinding:ManifestBinding?
 private var queue:SQLiteBackupQueue?
 private var engine:BackupCoordinator?
 private var transport:PartURLSessionTransport?
 private var monitor:BackupNetworkMonitor?
 private var source:URL?
 private var library:UUID?
 var previewAccount:UUID? {accountID.flatMap(UUID.init(uuidString:))}
 private var accountID:String?
 private var worker:Task<Void,Never>?
 var backgroundCompletion:(@Sendable()->Void)?
 private var connectionGate=ConnectionGeneration()
 var needsSignIn:Bool {items.contains{["AUTHENTICATION_REQUIRED","HTTP_401"].contains($0.lastErrorCode ?? "")}}
 func resumeAfterSignIn(){connectionGate.resume()}
 func connect() async throws {
  while connectionGate.isConnecting{try await Task.sleep(for:.milliseconds(20))}
  let generation=try connectionGate.begin()
  defer{connectionGate.finish(generation)}
  guard BetaReleaseSafety.acceptedConfiguration else{throw BackupFailure.missing}
  guard let baseString=Bundle.main.object(forInfoDictionaryKey:"APIBaseURL") as? String,let base=URL(string:baseString) else{throw BackupFailure.missing}
  let background=Bundle.main.object(forInfoDictionaryKey:"BackgroundUploadsEnabled") as? Bool ?? false
  let tokens=KeychainSessionStore(service:(Bundle.main.bundleIdentifier ?? "com.example.backupclient")+".session",allowsBackgroundAccess:background)
  let accountAPI=AuthAPI(baseURL:base,store:tokens)
  let account=try await accountAPI.me()
  try connectionGate.validate(generation)
  #if !DEBUG
  guard try await accountAPI.realMediaAccepted() else{canSelectOriginals=false;throw BackupFailure.policy}
  let boundDevice=try await accountAPI.currentDeviceID()
  try connectionGate.validate(generation)
  #endif
  #if DEBUG
  let photoTestEnabled=Bundle.main.object(forInfoDictionaryKey:"DevelopmentSinglePhotoBackup") as? Bool ?? false
  let boundDevice:UUID?
  if accountID==account.id,let deviceID {boundDevice=deviceID}
  else {boundDevice=photoTestEnabled ? try? await accountAPI.currentDeviceID() : nil}
  try connectionGate.validate(generation)
  let photoAccessReady=photoTestEnabled && boundDevice != nil
  var complexTestReady=false
  if photoAccessReady,Bundle.main.object(forInfoDictionaryKey:"DevelopmentComplexMediaBackup") as? Bool == true {
   complexTestReady=(try await accountAPI.ownerDeviceTestRestoreAssets()) != nil
  }
  try connectionGate.validate(generation)
  if engine != nil,accountID==account.id,canSelectOriginals==photoAccessReady,complexBackupTestAvailable==complexTestReady{return}
  #else
  if engine != nil,accountID==account.id,deviceID==boundDevice{return}
  #endif
  if let engine{try await engine.pauseAll()}
  try connectionGate.validate(generation)
  await transport?.shutdown()
  try connectionGate.validate(generation)
  guard let user=UUID(uuidString:account.id),let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else{throw BackupFailure.missing}
  var root=support.appendingPathComponent("BackupQueue",isDirectory:true).appendingPathComponent(user.uuidString,isDirectory:true)
  #if !DEBUG
  root=root.appendingPathComponent(boundDevice.uuidString,isDirectory:true)
  #endif
  let q=try SQLiteBackupQueue(url:root.appendingPathComponent("queue.sqlite")),files=try ManagedTemporaryFiles(directory:root.appendingPathComponent("temporary",isDirectory:true))
  #if DEBUG
  let generated=root.appendingPathComponent("generated",isDirectory:true);try FileManager.default.createDirectory(at:generated,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);source=generated
  let key="backup_library_"+user.uuidString
  #else
  let key="backup_library_"+user.uuidString+"_"+boundDevice.uuidString
  deviceID=boundDevice
  #endif
  let lib=UserDefaults.standard.string(forKey:key).flatMap(UUID.init(uuidString:)) ?? UUID();UserDefaults.standard.set(lib.uuidString,forKey:key)
  let storage=URL(string:Bundle.main.object(forInfoDictionaryKey:"StorageOrigin") as? String ?? "http://127.0.0.1:9000")!
  let transfer=try PartURLSessionTransport(origin:storage,background:background,sessionIdentifier:PartURLSessionTransport.sessionIdentifier(bundleIdentifier:Bundle.main.bundleIdentifier ?? "com.example.backupclient.dev"),allowLocalHTTP: _isDebugAssertConfiguration())
  let multipartAPI=try HTTPMultipartAPI(base:base,tokens:tokens,allowLocalHTTP:_isDebugAssertConfiguration());manifestAPI=multipartAPI
  #if DEBUG
  deviceID=boundDevice
  canSelectOriginals=photoAccessReady
  complexBackupTestAvailable=complexTestReady
  let ordinary=DevelopmentTestPreparer(generated:GeneratedResourcePreparer(sourceDirectory:source!,files:files),photos:PhotoKitResourcePreparer(files:files,developmentEnabled:canSelectOriginals))
  let preparer:any ResourcePreparer
  manifestStore=nil;preservationBinding=nil
  if complexTestReady,let boundDevice {
   let binding=ManifestBinding(accountID:user,deviceID:boundDevice,libraryID:lib)
   let store=try ManifestStore(url:root.appendingPathComponent("manifests.sqlite"))
   manifestStore=store;preservationBinding=binding
   preparer=PreservationResourcePreparer(ordinary:ordinary,multiple:MultiResourcePreparer(source:PhotoKitMediaSource(),store:store,files:files,binding:binding,invalidate:{id,fingerprint in try? await multipartAPI.invalidateManifest(id,fingerprint:fingerprint)}))
  }else{preparer=ordinary}
  #else
  let binding=ManifestBinding(accountID:user,deviceID:boundDevice,libraryID:lib),store=try ManifestStore(url:root.appendingPathComponent("manifests.sqlite"))
  manifestStore=store;preservationBinding=binding
  let ordinary=OriginalResourcePreparer(source:PhotoKitOriginalSource(),files:files,binding:OriginalBinding(accountID:user,deviceID:boundDevice,libraryID:lib),progress:{[weak self] value in Task{@MainActor in self?.originalProgress=value}})
  let preparer:any ResourcePreparer=PreservationResourcePreparer(ordinary:ordinary,multiple:MultiResourcePreparer(source:PhotoKitMediaSource(),store:store,files:files,binding:binding,invalidate:{id,fingerprint in try? await multipartAPI.invalidateManifest(id,fingerprint:fingerprint)}))
  canSelectOriginals=true
  #endif
  let e=BackupCoordinator(queue:q,api:multipartAPI,transport:transfer,preparer:AcloudPreviewPreparer(wrapped:preparer,queue:q,files:files),files:files,onProtected:{[weak self] in await self?.verifiedInBackground()})
  queue=q;engine=e;transport=transfer;library=lib;accountID=account.id;monitor=BackupNetworkMonitor(coordinator:e,onChange:{[weak self] in Task{@MainActor in await self?.tick()}})
  if let completion=backgroundCompletion{transfer.reconnect(completion:completion);backgroundCompletion=nil}
  var policy=BackupPolicy();policy.allowICloudOriginals=allowICloudOriginals;try await e.setPolicy(policy)
  try connectionGate.validate(generation)
  alertsSuspended=false
  await observeTransferAlerts()
  try connectionGate.validate(generation)
  try await e.reconcileStartup()
  try connectionGate.validate(generation)
  #if DEBUG
  message=canSelectOriginals ? "" : "Backup access is unavailable. Sign in again or contact support."
  if (try? await accountAPI.ownerDeviceTestRestoreAssets()) != nil {
   try connectionGate.validate(generation)
   message="Up to 32 MB per file."
  }
  #else
  try connectionGate.validate(generation)
  message="Choose photos or videos to back up."
  #endif
 }
 func refresh() async {
  do {
   try await connect()
   let generation=connectionGate.current
   if let queue {
    let counts=try await queue.summary(),requestedAnchor=transferAnchor
    let page=try await queue.recent(before:requestedAnchor,limit:100)
    try connectionGate.validate(generation)
    guard transferAnchor?.id==requestedAnchor?.id else{return}
    summary=counts;items=page;hasOlderTransfers=items.count==100;showingOlderTransfers=transferAnchor != nil
   }
   await reconcileManifests();try connectionGate.validate(generation);await observeTransferAlerts()
   if let account=previewAccount,let queue{AcloudThumbnailPublisher.start(account:account,queue:queue)}
  }catch is CancellationError {}catch AccountAPIError.unauthorized{message="Sign in again from Account. Your queued backups are kept."}catch{message="Could not load backups. Check your connection and try again."}
 }

 func verifiedInBackground() async {await reconcileManifests();await observeTransferAlerts();if let account=previewAccount,let queue{AcloudThumbnailPublisher.start(account:account,queue:queue)}}
 // Scan the full durable queue, independently of the visible history page.
 private func observeTransferAlerts() async {
  guard !alertsSuspended,!scanningAlerts,let queue,let accountID,let library else{return}
  scanningAlerts=true;defer{scanningAlerts=false}
  let scope="backup."+accountID+"."+library.uuidString
  TransferNotifications.shared.activate(scope)
  var snapshot:[String:String]=[:],cursor:UUID?
  do {
   while true {
    let page=try await queue.page(after:cursor,limit:100)
    guard self.accountID==accountID,self.library==library else{return}
    for item in page where item.mediaType != "test" {
     // Resource-level protection must not announce a partially protected asset.
     snapshot[item.id.uuidString]=TransferNotificationPolicy.backupOutcome(state:item.state.rawValue,isResource:item.mediaResourceBinding != nil,error:item.lastErrorCode)
    }
    if page.count<100{break};cursor=page.last?.id
   }
   if let store=manifestStore,let binding=preservationBinding {
    cursor=nil
    while true {
     let page=try await store.page(binding:binding,after:cursor,limit:100)
     guard self.accountID==accountID,self.library==library else{return}
     for manifest in page {
      snapshot["manifest."+manifest.id.uuidString]=TransferNotificationPolicy.manifestOutcome(state:manifest.state.rawValue)
     }
     if page.count<100{break};cursor=page.last?.id
    }
   }
   await TransferNotifications.shared.observe(scope:scope,snapshot:snapshot)
  } catch { /* Never alter queue state because an alert snapshot failed. */ }
 }
 func loadOlderTransfers()async{guard let last=items.last else{return};transferAnchor=last;await refresh()}
 func loadLatestTransfers()async{transferAnchor=nil;await refresh()}
 func enqueueGenerated() async {
  #if !DEBUG
  message="This backup option is unavailable. Choose photos or videos instead."
  return
  #else
  await action {
   guard let source=self.source,let library=self.library,let queue=self.queue else{throw BackupFailure.missing}
   let id=UUID(),url=source.appendingPathComponent(id.uuidString+".bin")
   guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw BackupFailure.storage}
   let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()}
   let chunk=Data(repeating:0x65,count:64*1024);for _ in 0..<320{try handle.write(contentsOf:chunk)};try handle.synchronize()
   _=try await queue.enqueue(BackupItem(libraryID:library,localAssetIdentifier:id.uuidString,mediaType:"test"));self.startWorker()
  }
  #endif
 }
 func updateOriginalPolicy() async {await action{var policy=BackupPolicy();policy.allowICloudOriginals=self.allowICloudOriginals;try await self.engine?.setPolicy(policy)}}
 func enqueueSelected(_ ids:[String],unavailableCount:Int=0) async {
  guard !busy else{return}
  transferAnchor=nil
  guard BackupSelectionPolicy.normalized(ids,unavailableCount:unavailableCount) != nil else{
   selectionNotice="Choose up to 10 photos or videos. If Photos could not provide access, check Acloud’s Photos access in Settings.";return
  }
  await action(selection:true) {
   guard self.canSelectOriginals,let queue=self.queue,let account=self.accountID.flatMap(UUID.init(uuidString:)),let device=self.deviceID,let library=self.library else{throw BackupFailure.authorization}
   #if !DEBUG
   guard let store=self.manifestStore,let api=self.manifestAPI else{throw BackupFailure.missing}
   let binding=ManifestBinding(accountID:account,deviceID:device,libraryID:library)
   #endif
   guard let summary=await BackupSelectionPolicy.process(ids,unavailableCount:unavailableCount,operation:{id in
    guard self.accountID?.lowercased()==account.uuidString.lowercased(),self.deviceID==device,self.library==library else{return .failed}
    do {
     #if DEBUG
     let descriptor=try await PhotoKitOriginalSource().describe(id)
     if !descriptor.supported,self.complexBackupTestAvailable {
      let snapshot=try await PhotoKitMediaSource().snapshot(id)
      guard OwnerComplexBackupPolicy.permits(snapshot),let store=self.manifestStore,let api=self.manifestAPI,let binding=self.preservationBinding,
            binding.accountID==account,binding.deviceID==device,binding.libraryID==library else{return .unsupported}
      let planner=MultiResourceBackupPlanner(store:store,queue:queue)
      let existing=try await planner.existing(source:snapshot,binding:binding)
      let manifest:MediaManifest
      var replaceCancelled=false
      if let existing {
       for resource in existing.resources {
        if let queued=try await queue.read(resource.id),queued.state == .cancelled {
         guard let engine=self.engine else{throw BackupFailure.missing}
         if try await engine.settleCancellation(queued.id).state == .cancelled{replaceCancelled=true}
        }
       }
      }
      if let existing,!replaceCancelled{manifest=existing}else{manifest=try await planner.captureExplicit(source:snapshot,binding:binding)}
      _=try await api.createManifest(manifest)
      guard self.accountID?.lowercased()==account.uuidString.lowercased(),self.deviceID==device,self.library==library,self.complexBackupTestAvailable else{return .failed}
      var newResource=false
      for resource in manifest.resources where resource.status != "PROTECTED" {
       if try await queue.read(resource.id)==nil{newResource=true}
      }
      _=try await planner.enqueue(manifest,binding:binding)
      return newResource ? .added:.existing
     }
     guard descriptor.supported,["image","video"].contains(descriptor.mediaType) else{return .unsupported}
     if descriptor.mediaType == "video" {guard let duration=descriptor.duration,duration>0,duration<=30 else{return .unsupported}}
     guard self.accountID?.lowercased()==account.uuidString.lowercased(),self.deviceID==device,self.library==library else{return .failed}
     var item=BackupItem(libraryID:library,localAssetIdentifier:id,mediaType:descriptor.mediaType)
     item.accountID=account;item.deviceID=device
     if let previous=try await queue.find(library:library,localID:id),previous.state == .cancelled {
      guard let engine=self.engine else{throw BackupFailure.missing}
      let fresh=try await engine.restartCancelled(previous.id)
      return fresh==previous.id ? .existing:.added
     }
     let queuedID=try await queue.enqueue(item)
     return queuedID==item.id ? .added:.existing
     #else
     let snapshot=try await PhotoKitMediaSource().snapshot(id)
      let planner=MultiResourceBackupPlanner(store:store,queue:queue)
      let existing=try await planner.existing(source:snapshot,binding:binding)
      let manifest:MediaManifest
      var replaceCancelled=false
      if let existing {
       for resource in existing.resources {
        if let queued=try await queue.read(resource.id),queued.state == .cancelled {
         guard let engine=self.engine else{throw BackupFailure.missing}
         if try await engine.settleCancellation(queued.id).state == .cancelled{replaceCancelled=true}
        }
       }
      }
      if let existing,!replaceCancelled{manifest=existing}else{manifest=try await planner.captureExplicit(source:snapshot,binding:binding)}
     _=try await api.createManifest(manifest)
     guard self.accountID?.lowercased()==account.uuidString.lowercased(),self.deviceID==device,self.library==library else{return .failed}
     var hasNewResource=false
     for resource in manifest.resources where resource.status != "PROTECTED" {
      if try await queue.read(resource.id) == nil{hasNewResource=true}
     }
     _=try await planner.enqueue(manifest,binding:binding)
     return hasNewResource ? .added:.existing
     #endif
    }catch let failure as BackupFailure {
     switch failure {case .inaccessible:return .inaccessible;case .unsupported:return .unsupported;case .http(let code):return .rejected(code);case .authorization:return .rejected(403);default:return .failed}
    }catch let failure as ManifestFailure {
     switch failure {case .unsupported,.fidelityPending:return .unsupported;default:return .failed}
    }catch{return .failed}
   }) else{throw BackupFailure.authorization}
   self.selectionNotice=summary.message
   self.startWorker()
   #if DEBUG
   if summary.unsupported>0{self.selectionNotice=summary.message+" Choose ordinary photos, short unedited videos, or a complete Live Photo/edited-photo test set when experimental backup is available. RAW, edited videos and unknown formats remain excluded."}
   #endif
  }
 }

 func reconcileManifests()async{
  let generation=connectionGate.current
  guard (try? connectionGate.validate(generation)) != nil else{return}
  guard let store=manifestStore,let api=manifestAPI,let binding=preservationBinding else{return}
  guard let page=try? await store.page(binding:binding,after:manifestReconcileCursor,limit:50) else{return}
  guard (try? connectionGate.validate(generation)) != nil else{return}
  manifestReconcileCursor=page.count==50 ? page.last?.id:nil
  for manifest in page{
   guard (try? connectionGate.validate(generation)) != nil else{return}
   // Reconcile server verification first: a finished saved version no longer follows device edits.
   guard let proof=try? await api.manifestProof(manifest.id),let current=try? await store.apply(proof,to:manifest.id) else{continue}
   guard current.requiresSourceRevalidation else{continue}
   if let pending=current.changedFingerprint{try? await api.invalidateManifest(current.id,fingerprint:pending)}
   if let fresh=try? await PhotoKitMediaSource().snapshot(current.source.localID),!current.matches(fresh){try? await api.invalidateManifest(current.id,fingerprint:fresh.fingerprint)}
   if let proof=try? await api.manifestProof(current.id){_=try? await store.apply(proof,to:current.id)}
  }
  let refreshed=(try? await store.page(binding:binding,limit:50)) ?? []
  guard (try? connectionGate.validate(generation)) != nil else{return}
  manifests=refreshed
 }
 func action(selection:Bool=false,_ operation:() async throws -> Void) async {
  busy=true;defer{busy=false}
  do{try await connect();try await operation();await refresh()}catch{
   message="Action paused or failed. The queue retains its state."
   if selection {
    if let failure=error as? BackupFailure,failure == .inaccessible {selectionNotice="Acloud could not access this photo. Check Photos access in Settings, including whether this item is allowed under Limited Access."}
    else {selectionNotice="The selection could not be added. Check your account connection and Photos access, then try again."}
   }
  }
 }
 func pauseAll() async{await action{try await self.engine?.pauseAll()}}
 func resumeAll() async{await action{try await self.engine?.resumeAll();self.startWorker()}}
 func retryFailed() async{await action{try await self.engine?.retryAllFailed();self.startWorker()}}
 func retry(_ id:UUID) async{await action{try await self.engine?.retryFailed(id);self.startWorker()}}
 func pause(_ id:UUID) async{await action{try await self.engine?.pause(id)}}
 func resume(_ id:UUID) async{await action{try await self.engine?.resume(id);self.startWorker()}}
 func restart(_ id:UUID)async {
  if let item=items.first(where:{$0.id==id}),let binding=item.mediaResourceBinding {
   do{try await connect();guard let engine else{throw BackupFailure.missing};let settled=try await engine.settleCancellation(id)
    guard settled.state == .cancelled else{await refresh();return}
    await enqueueSelected([binding.sourceLocalID]);await tick()
   }catch{selectionNotice="Could not start again yet. Check your connection and try again; your original is unchanged."}
   return
  }
  transferAnchor=nil
  await action{guard let engine=self.engine,let queue=self.queue else{throw BackupFailure.missing};let fresh=try await engine.restartCancelled(id);let current=try await queue.read(fresh);self.selectionNotice=current?.state == .protected ? "This item is already verified and protected." : current?.state == .queued ? "Backup queued again. The cancelled attempt remains in your history." : "This item has a newer attempt. Open the latest transfer to continue.";self.startWorker()}
  await tick()
 }
 func cancel(_ id:UUID) async{await action{try await self.engine?.cancel(id)}}
 private var workerRequested=false
 private func startWorker(requestAnotherPass:Bool=true) {
  guard let engine else{return}
  if worker != nil{if requestAnotherPass{workerRequested=true};return}
  // Acquire execution time at the explicit action, before metadata refreshes.
  let allowance=BackupBackgroundTime();allowance.begin()
  worker=Task{
   defer{allowance.end();self.worker=nil}
   repeat {
    self.workerRequested=false
    try? await engine.runDue()
    await self.refresh()
   }while self.workerRequested && !Task.isCancelled
  }
 }
 func tick() async {
  do{try await connect();startWorker(requestAnotherPass:false);await refresh()}catch AccountAPIError.unauthorized{message="Sign in again from Account. Your queued backups are kept."}catch{message="Waiting for a connection. Check Account if this continues."}
 }
 func stopForSignOut() async throws {
  connectionGate.suspend()
  AcloudPreviewRegistry.shared.clear();alertsSuspended=true;TransferNotifications.shared.signOut()
  let previousWorker=worker,previousEngine=engine,previousTransport=transport
  previousWorker?.cancel()
  monitor=nil;engine=nil;transport=nil;queue=nil;manifestStore=nil;manifestAPI=nil;preservationBinding=nil
  manifests=[];accountID=nil;deviceID=nil;canSelectOriginals=false;complexBackupTestAvailable=false
  items=[];summary=[:];transferAnchor=nil;hasOlderTransfers=false;showingOlderTransfers=false
  var pauseError:Error?
  do{try await previousEngine?.pauseAll()}catch{pauseError=error}
  await previousTransport?.shutdown()
  await previousWorker?.value
  worker=nil;workerRequested=false
  if let pauseError{throw pauseError}
 }

 func handleBackground(completion:@escaping @Sendable()->Void) async {
  let allowance=BackupBackgroundTime()
  let receipt=BackgroundEventCompletion{Task{@MainActor in allowance.end();completion()}}
  allowance.begin(expiration:{receipt.finish()})
  // Never hold UIKit's acknowledgement while a later part waits in the daemon.
  Task{@MainActor in try? await Task.sleep(for:.seconds(25));receipt.finish()}
  backgroundCompletion={Task{@MainActor in
   // Drain in-process callbacks before reconciling daemon-completed parts.
   await self.worker?.value
   do{try await self.engine?.reconcileStartup();try await self.engine?.runDue();await self.refresh()}catch{self.message="Background upload will resume when the app is opened."}
   receipt.finish()
  }}
  do{try await connect();if let pending=backgroundCompletion{transport?.reconnect(completion:pending);backgroundCompletion=nil}}catch{receipt.finish();backgroundCompletion=nil}
 }
}
struct BackupQueueView:View {
 @AppStorage("showDeveloperTools") private var showDeveloperTools=false
 @AppStorage("selectedTransferTab") private var selectedAppTab="backup"
 @ObservedObject private var model=BackupQueueModel.shared
 @ObservedObject private var cloudStorage=StorageScreen.model
 @ObservedObject private var thumbnailSync=AcloudThumbnailSyncStatus.shared
 private enum PickerSelection:String,Identifiable {case photo,video,originals;var id:String{rawValue}}
 @State private var pickerSelection:PickerSelection?
 @AppStorage("backupBrowserMode") private var browserMode="gallery"
 @State private var galleryFilter:AcloudGalleryFilter = .all
 @State private var galleryOrder:AcloudGalleryOrder = .newest
 @State private var gallerySize:AcloudGallerySize = .medium
 @State private var galleryViewer:AcloudGalleryPresentation?
 private var savedGallery:[AcloudGalleryEntry] {
  model.items.compactMap{item -> AcloudGalleryEntry? in
   guard item.state == .protected,["image","video"].contains(item.mediaType),let asset=item.assetID else{return nil}
   var date=item.originalManifest?.source.creation ?? item.createdAt,live=false
   if let binding=item.mediaResourceBinding {
    guard let manifest=model.manifests.first(where:{$0.id==binding.manifestID}),[.fullyProtected,.restoreReady].contains(manifest.state),previewResource(manifest)?.id==item.id else{return nil}
    date=manifest.source.creation ?? item.createdAt;live=manifest.source.kind == .livePhoto
   }
   return AcloudGalleryEntry(id:asset.uuidString,type:item.mediaType,date:date,live:live,account:model.previewAccount,asset:asset,checksum:item.expectedChecksum)
  }.filter{galleryFilter.includes($0)}.sorted{a,b in
   if a.date != b.date{if a.date==nil{return false};if b.date==nil{return true};return galleryOrder == .newest ? a.date!>b.date!:a.date!<b.date!}
   return a.id<b.id
  }
 }
 private enum QueueFilter:String,CaseIterable {case all="All transfers",active="In progress",attention="Needs attention",verified="Verified"}
 @State private var queueFilter:QueueFilter = .all
 @State private var transferFilter:AcloudMediaFilter = .all
 private var visibleTransfers:[BackupItem] {model.items.filter {item in
  guard transferFilter.includes(item.mediaType) else{return false}
  switch queueFilter {
  case .all:return true
  case .active:return ![.protected,.cancelled,.paused,.failedRetryable,.failedPermanent].contains(item.state)
  case .attention:return [.paused,.failedRetryable,.failedPermanent].contains(item.state)
  case .verified:return item.state == .protected
  }
 }}
 private var protectedCount:Int {model.summary[.protected] ?? 0}
 private var waitingCount:Int {model.summary.filter{![BackupState.protected,.cancelled,.paused,.failedRetryable,.failedPermanent].contains($0.key)}.values.reduce(0,+)}
 private var attentionCount:Int {[BackupState.paused,.failedRetryable,.failedPermanent].reduce(0){$0+(model.summary[$1] ?? 0)}}
 var body:some View {
  NavigationStack {
   List {
    Section {
     AcloudHero(icon:"icloud.and.arrow.up",eyebrow:"Acloud backup",title:"Back up your memories.",message:"Save photos and videos to Acloud. Your originals stay in Photos.").acloudFeatureRow()
    }
    Section {
     Picker("Browse backups",selection:$browserMode){Text("Recent saves").tag("gallery");Text("Transfers").tag("transfers")}.pickerStyle(.segmented)
    }
    if browserMode == "transfers" {
    Section {
     LazyVGrid(columns:[GridItem(.adaptive(minimum:140),spacing:12)],spacing:12) {
      AcloudMetric(title:"Files protected",value:protectedCount.formatted(),icon:"checkmark.shield")
      AcloudMetric(title:"In progress",value:waitingCount.formatted(),icon:"arrow.triangle.2.circlepath")
      AcloudMetric(title:"Needs attention",value:attentionCount.formatted(),icon:"exclamationmark.circle")
     }.acloudFeatureRow()
    }
    Section("Add a backup") {
     Button {pickerSelection = .originals} label:{Label("Choose photos and videos",systemImage:"plus.circle.fill").frame(maxWidth:.infinity)}
      .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canSelectOriginals || model.busy)
     Text("Choose up to 10 items, then tap Add.").font(.footnote).foregroundStyle(.secondary)
     #if DEBUG
     if showDeveloperTools {
     HStack {
      Button {pickerSelection = .photo} label:{Label("Photos only",systemImage:"photo.badge.plus")}
      Button {pickerSelection = .video} label:{Label("Videos only",systemImage:"video.badge.plus")}
     }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canSelectOriginals || model.busy)
     Text("Videos selected here must be unedited and 30 seconds or shorter.").font(.footnote).foregroundStyle(.secondary)
     if model.complexBackupTestAvailable {
      Label("Live Photos and edited photos supported",systemImage:"livephoto").font(.subheadline)
      Text("A Live Photo includes a photo and video. Edited photos include the original and saved edit.").font(.footnote).foregroundStyle(.secondary)
     }
     }
     #endif
     Toggle("Download iCloud originals on Wi-Fi",isOn:$model.allowICloudOriginals).onChange(of:model.allowICloudOriginals){_,_ in Task{await model.updateOriginalPolicy()}}
     Text("Allow this to back up items stored only in iCloud.").font(.footnote).foregroundStyle(.secondary)
     if model.originalProgress>0 {ProgressView("Preparing original",value:model.originalProgress)}
     if !model.message.isEmpty{Text(model.message).font(.footnote).foregroundStyle(.secondary)}
    }
    } else {
     Section {
      Button{pickerSelection = .originals}label:{Label("Choose photos & videos to back up",systemImage:"plus.circle.fill").frame(maxWidth:.infinity)}
       .buttonStyle(.borderedProminent).disabled(!model.canSelectOriginals || model.busy)
      if let cloud=cloudStorage.cloud {
       Text("Last reported Acloud space: \(acloudCapacity(cloud.remainingBytes)) available").font(.caption).foregroundStyle(.secondary)
       if cloud.remainingBytes==0{Text("Your Acloud allowance is full or reserved for pending transfers. Review Storage before starting another backup.").font(.footnote).foregroundStyle(.orange)}
      }
      if !model.message.isEmpty{Text(model.message).font(.caption).foregroundStyle(.secondary)}
      HStack {
       Text("Choose up to 10 items at a time.").font(.caption).foregroundStyle(.secondary)
       Spacer()
       Button("Backup options"){browserMode="transfers"}.font(.caption)
      }
     }
    }
    if browserMode == "gallery" {
     Section("Recent backups") {
      Button("Browse all saved backups"){selectedAppTab="restore"}.buttonStyle(.borderedProminent)
      AcloudGalleryControls(filter:$galleryFilter,order:$galleryOrder,size:$gallerySize)
      if let account=model.previewAccount{AcloudThumbnailMaintenance(account:account).id(account)}
      if thumbnailSync.pending>0{Text("\(thumbnailSync.pending) small previews waiting to sync over Wi-Fi. Your originals remain protected.").font(.caption).foregroundStyle(.secondary)}
      if thumbnailSync.waitingForAccess>0{Text("Previews are waiting for account access. Check Account.").font(.caption).foregroundStyle(.secondary)}
      if thumbnailSync.waitingForBudget>0{Text("Previews will sync when more capacity is available.").font(.caption).foregroundStyle(.secondary)}
      if thumbnailSync.failed>0{Text("\(thumbnailSync.failed) saved previews need attention. Your protected originals are unchanged.").font(.caption).foregroundStyle(.secondary)}
      Text("Recent completed backups. Open Saved to browse more.").font(.caption).foregroundStyle(.secondary)
      if savedGallery.isEmpty{ContentUnavailableView("No matching saved items on this page",systemImage:"photo.on.rectangle",description:Text("Try another filter or check Transfers for work in progress."))}
      AcloudGalleryGrid(items:savedGallery,order:galleryOrder,size:gallerySize,onSelect:{_ in},onOpen:{entry in galleryViewer=AcloudGalleryPresentation(items:savedGallery,startID:entry.id)})
     }
    } else {
    Section("Your transfers") {
     if waitingCount>0 || attentionCount>0 {
      ViewThatFits(in:.horizontal){
       HStack{transferControls}
       VStack(alignment:.leading){transferControls}
      }.buttonStyle(.bordered).disabled(model.busy)
     }
     Picker("Media type",selection:$transferFilter) {
      ForEach(AcloudMediaFilter.allCases){filter in Text(filter.rawValue).tag(filter)}
     }.pickerStyle(.segmented)
     Picker("Transfer status",selection:$queueFilter) {ForEach(QueueFilter.allCases,id:\.self){filter in Text(filter.rawValue).tag(filter)}}
     Text("Live Photos and edited photos include additional files.").font(.caption).foregroundStyle(.secondary)
     Text("\(visibleTransfers.count) transfers · newest first")
      .font(.caption).foregroundStyle(.secondary)
     if model.items.isEmpty {
      ContentUnavailableView("Your first backup starts here",systemImage:"icloud.and.arrow.up",description:Text("Choose a photo or video above to see its progress here."))
     } else if visibleTransfers.isEmpty {
      Text("No transfers match these filters on this page.").foregroundStyle(.secondary)
     }
    }
    ForEach(acloudMediaGroups(visibleTransfers,type:{$0.mediaType},date:{$0.createdAt})) {group in
     Section {ForEach(group.items){item in transferRow(item)}} header:{AcloudMediaGroupTitle(title:group.title+" · transfers",date:group.day)}
    }
    }
    if model.hasOlderTransfers || model.showingOlderTransfers {Section {
     if model.hasOlderTransfers{Button("Older transfers"){Task{await model.loadOlderTransfers()}}}
     if model.showingOlderTransfers{Button("Latest transfers"){Task{await model.loadLatestTransfers()}}}
    }}
    if browserMode == "transfers",!model.manifests.isEmpty {
     Section("Backup details") {
      ForEach(model.manifests){manifest in
       VStack(alignment:.leading,spacing:10) {
        AcloudMediaHeader(type:manifest.source.mediaType,reference:manifest.id,previewSource:.backupVersion,sourceCaptureDate:manifest.source.creation,previewAccount:manifest.binding.accountID,previewAsset:previewResource(manifest)?.serverAssetID,previewChecksum:previewResource(manifest)?.expectedSha256,dateLabel:"Backup added",date:manifest.createdAt,detail:manifest.source.kind == .livePhoto ? "Live Photo":manifest.source.kind == .rawJPEG ? "RAW + JPEG":manifest.source.kind == .edited ? "Edited media":"Original media")
        Label([.fullyProtected,.restoreReady].contains(manifest.state) ? "Backup complete":manifest.state == .sourceChanged ? "Original changed — select it again":"Finishing backup",systemImage:[.fullyProtected,.restoreReady].contains(manifest.state) ? "checkmark.shield.fill":"square.stack.3d.up")
        ProgressView(value:Double(manifest.required.filter{$0.status=="PROTECTED"}.count),total:Double(max(1,manifest.required.count))).accessibilityLabel("Required files verified")
        Text("\(manifest.required.filter{$0.status=="PROTECTED"}.count) of \(manifest.required.count) files protected").font(.caption)
        DisclosureGroup("Details") {Text("All parts of this item must be saved before its backup is complete.").font(.footnote).foregroundStyle(.secondary)}
       }.padding(.vertical,8)
      }
     }
    }
    #if DEBUG
    if showDeveloperTools {Section {
     DisclosureGroup("Developer tools") {
      Button("Queue generated 20 MiB file"){Task{await model.enqueueGenerated()}}
     }.disabled(model.busy)
    }}
    #endif
   }.acloudCanvas().navigationTitle("Backup")
  }.sheet(item:$pickerSelection){selection in OriginalAssetPicker(filter:selection == .video ? .videos:selection == .photo ? .images:.any(of:[.images,.videos])){result in pickerSelection=nil;guard let result else{return};transferFilter = .all;queueFilter = .all;browserMode="transfers";Task{await model.enqueueSelected(result.identifiers,unavailableCount:result.unavailableCount)}}.id(selection.id)}
   .sheet(item:$galleryViewer){presentation in AcloudGalleryViewer(items:presentation.items,startID:presentation.startID)}
   .alert("Backup selection",isPresented:Binding(get:{model.selectionNotice != nil},set:{if !$0{model.selectionNotice=nil}})){Button("OK",role:.cancel){model.selectionNotice=nil}}message:{Text(model.selectionNotice ?? "")}
   .task{await model.refresh()}
   .task{await StorageScreen.connect()}
 }
 @ViewBuilder private var transferControls:some View {
  if waitingCount>0{Button("Pause all"){Task{await model.pauseAll()}}}
  if (model.summary[.paused] ?? 0)>0{Button("Resume all"){Task{await model.resumeAll()}}}
  if (model.summary[.failedPermanent] ?? 0)+(model.summary[.failedRetryable] ?? 0)>0{Button("Retry failed"){Task{await model.retryFailed()}}}
 }
 private func previewResource(_ manifest:MediaManifest)->ManifestResource? {
  let verified=manifest.required.filter{$0.status=="PROTECTED"}
  return verified.first{$0.descriptor.role == .edited} ?? verified.first{[.still,.jpeg].contains($0.descriptor.role)}
 }
 private func transferRow(_ item:BackupItem)->some View {
  VStack(alignment:.leading,spacing:12) {
   AcloudMediaHeader(type:item.mediaType,reference:item.id,localID:item.state == .protected ? nil:(item.mediaResourceBinding?.sourceLocalID ?? item.originalManifest?.source.localID ?? (item.mediaType == "test" ? nil:item.localAssetIdentifier)),previewSource:item.state == .protected ? .backupVersion:.device,sourceCaptureDate:item.originalManifest?.source.creation,previewAccount:item.state == .protected ? model.previewAccount:nil,previewAsset:item.assetID,previewChecksum:item.expectedChecksum,dateLabel:"Backup added",date:item.createdAt,detail:item.mediaType == "test" ? "Generated or supporting file":nil)
   Label(item.state.displayTitle,systemImage:item.state == .protected ? "checkmark.shield.fill":item.state == .failedPermanent || item.state == .failedRetryable ? "exclamationmark.circle":"arrow.up.circle")
    .font(.subheadline.weight(.semibold)).foregroundStyle(item.state == .protected ? AcloudStyle.accent:Color.primary)
   if item.state != .cancelled {
    AcloudTransferProgress(stages:["Upload","Verify","Protected"],stage:item.state == .protected ? 2:[.uploaded,.verifying].contains(item.state) ? 1:0,bytes:item.bytesUploaded,total:item.expectedSizeBytes ?? 0,activity:item.state.displayTitle,transferring:item.state == .uploading,complete:item.state == .protected,stopped:[.paused,.failedPermanent,.failedRetryable].contains(item.state))
    if item.state == .protected,let size=item.expectedSizeBytes {Text("Verified size · \(Int64(size).formatted(.byteCount(style:.file)))").font(.caption).foregroundStyle(.secondary)}
    if [.uploaded,.verifying].contains(item.state) {Text("Upload finished. Waiting for integrity checks before protection is confirmed.").font(.caption).foregroundStyle(.secondary)}
   }
   if [.paused,.failedPermanent,.failedRetryable].contains(item.state),let guidance=backupGuidance(item) {Text(guidance).font(.subheadline).foregroundStyle(.secondary)}
   if item.state != .protected {
    ViewThatFits(in:.horizontal){HStack{transferActions(item)};VStack(alignment:.leading){transferActions(item)}}
     .buttonStyle(.bordered).controlSize(.regular).disabled(model.busy)
   }
   DisclosureGroup("Details & support") {
    VStack(alignment:.leading,spacing:6) {
     Text("Transfer reference: B-\(item.id.uuidString.prefix(8))").textSelection(.enabled)
     Text("Last updated \(item.updatedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
     if let guidance=backupGuidance(item){Text(guidance)}
     if let stage=item.lastFailureStage,[.failedRetryable,.failedPermanent,.paused].contains(item.state){Text("Stopped while: \(stage)").textSelection(.enabled)}
     if let code=item.lastErrorCode,item.state != .protected {Text(code).textSelection(.enabled)}
    }.font(.caption).foregroundStyle(.secondary)
   }.font(.caption)
  }.padding(.vertical,10)
 }
 @ViewBuilder private func transferActions(_ item:BackupItem)->some View {
  if item.state == .cancelled {Button("Back up again"){Task{await model.restart(item.id)}}}
  else if [.failedPermanent,.failedRetryable].contains(item.state) {Button("Retry"){Task{await model.retry(item.id)}}}
  else if item.state == .paused {Button("Resume"){Task{await model.resume(item.id)}}}
  else {Button("Pause"){Task{await model.pause(item.id)}}}
  if item.state != .cancelled {Button("Cancel",role:.destructive){Task{await model.cancel(item.id)}}}
 }
}

private struct OriginalAssetPicker:UIViewControllerRepresentable {
 let filter:PHPickerFilter
 let selected:(BackupPickerSelection?)->Void
 func makeCoordinator()->Coordinator{Coordinator(selected:selected)}
 func makeUIViewController(context:Context)->PHPickerViewController{
  var config=PHPickerConfiguration(photoLibrary:.shared())
  config.filter=filter;config.selectionLimit=BackupSelectionPolicy.maximum;config.selection = .ordered
  let picker=PHPickerViewController(configuration:config);picker.delegate=context.coordinator;return picker
 }
 func updateUIViewController(_ controller:PHPickerViewController,context:Context){}
 final class Coordinator:NSObject,PHPickerViewControllerDelegate {
  let selected:(BackupPickerSelection?)->Void
  init(selected:@escaping(BackupPickerSelection?)->Void){self.selected=selected}
  func picker(_ picker:PHPickerViewController,didFinishPicking results:[PHPickerResult]) {
   guard !results.isEmpty else{selected(nil);return}
   let identifiers=results.compactMap(\.assetIdentifier)
   selected(BackupPickerSelection(identifiers:identifiers,unavailableCount:results.count-identifiers.count))
  }
 }
}
