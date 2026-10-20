import Foundation
public actor RestoreCoordinator {
 private let queue:RestoreQueue,files:RestoreFiles,api:any RestoreAPI,downloader:any RestoreDownloader,photos:any PhotoLibraryRestorer,capacity:any DeviceCapacity,concurrency:Int
 private var savingID:UUID?
 private var progressBytes:[UUID:Int]=[:]
 private var account:UUID?,library:UUID?,tasks:[UUID:Task<Void,Error>]=[:]
 public init(queue:RestoreQueue,files:RestoreFiles,api:any RestoreAPI,downloader:any RestoreDownloader,photos:any PhotoLibraryRestorer,capacity:any DeviceCapacity=SystemDeviceCapacity(),concurrency:Int=2){self.queue=queue;self.files=files;self.api=api;self.downloader=downloader;self.photos=photos;self.capacity=capacity;self.concurrency=max(1,min(4,concurrency))}
 public func activate(account:UUID,library:UUID)async throws{if self.account != account || self.library != library{await deactivate();self.account=account;self.library=library};try await reconcile()}
 public func deactivate()async{account=nil;library=nil;for(id,task)in tasks{if (try? await queue.read(id))?.state != .saving{task.cancel()}};await downloader.cancel();for task in tasks.values{_=try? await task.value};tasks.removeAll()}
 private func bound(_ item:RestoreItem)throws{try Task.checkCancellation();guard account == item.accountID,library == item.libraryID else{throw RestoreFailure.authorization}}
 private func current(_ id:UUID)async throws->RestoreItem{guard let item=try await queue.read(id) else{throw RestoreFailure.missing};try bound(item);return item}
 private func transition(_ id:UUID,_ state:RestoreState)async throws->RestoreItem{var item=try await current(id);item.state=state;return try await queue.save(item)}
 public func run(_ id:UUID)async throws{guard tasks[id]==nil,tasks.count<concurrency else{return};let task=Task{try await self.execute(id)};tasks[id]=task;defer{tasks.removeValue(forKey:id);progressBytes.removeValue(forKey:id)};try await task.value}
 public func runDue()async{guard let account,let library else{return};let items=(try? await queue.due(account:account,library:library,limit:concurrency-tasks.count)) ?? [];await withTaskGroup(of:Void.self){group in for item in items{group.addTask{_=try? await self.run(item.id)}}}}
 private func execute(_ id:UUID)async throws {
  var item=try await current(id);guard [.queued,.retryable,.ready].contains(item.state),item.evidence.supported else{return}
  let started=Date()
  await api.report("REQUESTED",retry:item.retryCount,durationMs:nil)
  do{
   if let available=try capacity.available(at:files.directory),available<Int64(item.evidence.expectedSize)*2+64*1024*1024{item.state = .paused;item.lastErrorCode="DEVICE_SPACE_REQUIRED";_=try await queue.save(item);return}
   if item.state != .ready{
    item=try await transition(id,.authorizing);let authorization=try await api.authorize(item.evidence);try bound(item);guard authorization.evidence == item.evidence else{throw RestoreFailure.versionChanged};item=try await transition(id,.downloading);try files.remove(id,includingPartial:false)
    try await downloader.download(authorization.authorization,to:files.url(id),expectedSize:item.evidence.expectedSize,progress:{[weak self] count in Task{await self?.progress(id,count)}})
    await api.report("DOWNLOAD_OK",retry:item.retryCount,durationMs:Int(Date().timeIntervalSince(started)*1000))
    item=try await transition(id,.verifying);try files.verify(item);item=try await current(id);item.bytesDownloaded=item.evidence.expectedSize;item.state = .ready;item=try await queue.save(item)
   }
   try files.verify(item);if let available=try capacity.available(at:files.directory),available<Int64(item.evidence.expectedSize)+64*1024*1024{throw RestoreFailure.storage};while savingID != nil{try bound(item);try await Task.sleep(for:.milliseconds(20))};savingID=id;defer{if savingID==id{savingID=nil}};guard await photos.canSave() else{throw RestoreFailure.permission};try await photos.validate(files.url(id),mediaType:item.evidence.mediaType);let evidence=try await api.recheck(item.evidence);item=try await current(id);guard item.state == .ready,evidence == item.evidence else{throw RestoreFailure.versionChanged};try bound(item)
   item.state = .saving;item=try await queue.save(item);try bound(item)
   // Once submitted, Apple creation is not cancellable. Account changes wait for this callback.
   let identifier=try await photos.save(files.url(id),mediaType:item.evidence.mediaType)
   guard var saved=try await queue.read(id),saved.accountID == item.accountID,saved.evidence == item.evidence else{throw RestoreFailure.ambiguousSave};saved.localIdentifier=identifier;saved=try await queue.save(saved);_=try await queue.completed(saved,localIdentifier:identifier);if account==saved.accountID{await api.report("COMPLETED",retry:saved.retryCount,durationMs:Int(Date().timeIntervalSince(started)*1000))};do{try files.remove(id)}catch{await api.report("CLEANUP_FAILED",retry:saved.retryCount,durationMs:nil);throw error}
  }catch{
   guard var latest=try await queue.read(id),![.restored,.cancelled].contains(latest.state) else{throw error}
   if latest.state == .ready,Self.retryable(error),latest.retryCount<8{latest.retryCount+=1;latest.nextRetryAt=Date().addingTimeInterval(min(3600,pow(2,Double(latest.retryCount))))}
   else if latest.state == .saving{latest.state = .reconcile;latest.lastErrorCode="SAVE_RESULT_UNCERTAIN";if case let RestoreFailure.photosSave(code)=error{latest.lastErrorCode="PHOTOS_SAVE_ERROR_\(code)"}}
   else if latest.state == .paused{}else if error is CancellationError || account==nil{latest.state = .paused;latest.lastErrorCode="USER_PAUSED"}
   else if error as? RestoreFailure == .permission{latest.state = .paused;latest.lastErrorCode="PHOTOS_PERMISSION_REQUIRED"}
   else{latest.retryCount+=1;let retry=Self.retryable(error)&&latest.retryCount<8;latest.state=retry ? .retryable:.permanent;latest.lastErrorCode=error as? RestoreFailure == .integrity ? "INTEGRITY_FAILED":"RESTORE_REQUIRES_ACTION";latest.nextRetryAt=retry ? Date().addingTimeInterval(min(3600,pow(2,Double(latest.retryCount)))):nil;if error as? RestoreFailure == .integrity{try? files.remove(id)}}
   _=try await queue.save(latest);if account==latest.accountID{await api.report(latest.state == .reconcile ? "SAVE_FAILED":error as? RestoreFailure == .integrity ? "CHECKSUM_FAILED":"DOWNLOAD_FAILED",retry:latest.retryCount,durationMs:nil)};throw error
  }
 }
 private static func retryable(_ error:Error)->Bool{if let e=error as? RestoreFailure,case .http(let code)=e{return code==401||code==403||code==408||code==429||code>=500};return error is URLError}
 public func progressSnapshot()->[UUID:Int]{progressBytes}
 private func progress(_ id:UUID,_ bytes:Int)async{guard let item=try? await queue.read(id),item.state == .downloading,account == item.accountID,bytes>=0,bytes<=item.evidence.expectedSize else{return};progressBytes[id]=max(progressBytes[id] ?? 0,bytes)}

 public func pause(_ id:UUID)async throws{var item=try await current(id);guard item.state != .saving,item.state != .reconcile,item.state != .restored,item.state != .cancelled else{return};item.state = .paused;_=try await queue.save(item);tasks[id]?.cancel();if let task=tasks[id]{_=try? await task.value}}
 public func resume(_ id:UUID)async throws{if let task=tasks[id]{_=try? await task.value};var item=try await current(id);guard [.paused,.retryable,.permanent].contains(item.state) else{throw RestoreFailure.ambiguousSave};item.state = .queued;item.nextRetryAt=nil;item.bytesDownloaded=0;_=try await queue.save(item)}
 public func cancel(_ id:UUID)async throws{var item=try await current(id);guard item.state != .saving,item.state != .reconcile,item.state != .restored else{throw RestoreFailure.ambiguousSave};tasks[id]?.cancel();if let task=tasks[id]{_=try? await task.value};item=try await current(id);item.state = .cancelled;_=try await queue.save(item);try files.remove(id)}
 public func reconcile()async throws{guard tasks.isEmpty else{return};guard let account,let library else{return};var cursor:UUID?;while true{let page=try await queue.page(account:account,library:library,after:cursor);if page.isEmpty{break};for var item in page{if item.state == .restored||item.state == .cancelled{try? files.remove(item.id)}else if [.saving,.reconcile].contains(item.state){if let local=item.localIdentifier,await photos.presence(local) == .exists{_=try await queue.completed(item,localIdentifier:local);try? files.remove(item.id)}else if item.state == .saving{item.state = .reconcile;item.lastErrorCode="SAVE_RESULT_UNCERTAIN";_=try await queue.save(item)}}else if [.authorizing,.downloading,.verifying].contains(item.state){try? files.remove(item.id,includingPartial:false);item.state = .queued;item.bytesDownloaded=0;_=try await queue.save(item)}};cursor=page.last?.id}}
}
