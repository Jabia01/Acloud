import SwiftUI
import HealthClient
import RestoreEngine
import MediaPreservation
import Photos

private extension RestoreState {
 var displayTitle:String {
  switch self {
  case .queued: return "Waiting to restore"
  case .authorizing: return "Checking access"
  case .downloading: return "Downloading"
  case .verifying: return "Checking downloaded file"
  case .ready: return "Ready to save"
  case .saving: return "Saving to Photos"
  case .restored: return "Restored to Photos"
  case .paused: return "Paused"
  case .retryable: return "Restore interrupted"
  case .permanent: return "Restore needs attention"
  case .cancelled: return "Cancelled"
  case .reconcile: return "Check Photos before retrying"
  }
 }
}
@MainActor final class RestoreModel:ObservableObject {
 static let shared=RestoreModel()
 @Published var assets:[ProtectedRestoreAsset]=[]
 @Published var items:[RestoreItem]=[]
 @Published var compounds:[CompoundRestoreRecord]=[]
 @Published var selected:Set<UUID>=[]
 @Published var message="Sign in to browse protected versions."
 @Published var busy=false
 @Published var canRestore=false
 @Published var availableBytes:Int64?
 @Published var progress:[UUID:Int]=[:]
 private var developmentTestAsset:UUID?
 private var ownerTestAssets:Set<UUID>?
 private var nextCursor:String?,queueCursor:UUID?,account:UUID?,device:UUID?,library:UUID?
 private var worker:Task<Void,Never>?
 private var compoundQueue:CompoundRestoreQueue?,compoundCoordinator:CompoundRestoreCoordinator?
 private var api:HTTPRestoreAPI?,queue:RestoreQueue?,coordinator:RestoreCoordinator?,files:RestoreFiles?
 var selectedPhotos:Int{assets.filter{selected.contains($0.id)&&$0.mediaType=="image"}.count}
 var selectedVideos:Int{assets.filter{selected.contains($0.id)&&$0.mediaType=="video"}.count}
 var selectedBytes:Int64{assets.filter{selected.contains($0.id)}.reduce(0){$0+Int64($1.sizeBytes ?? 0)}}
 private func restoreAllowed(_ auth:AuthAPI)async->Bool{
  #if DEBUG
  guard Bundle.main.object(forInfoDictionaryKey:"DevelopmentSinglePhotoRestore") as? Bool == true else{return false}
  ownerTestAssets=nil
  if let ids=try? await auth.ownerDeviceTestRestoreAssets(){ownerTestAssets=Set(ids);developmentTestAsset=nil;return true}
  developmentTestAsset=try? await auth.developmentRestoreTestAssetID()
  return developmentTestAsset != nil
  #else
  return (try? await auth.restoreAccepted()) ?? false
  #endif
 }
 func connect()async throws{
  guard BetaReleaseSafety.acceptedConfiguration,let value=Bundle.main.object(forInfoDictionaryKey:"APIBaseURL") as? String,let base=URL(string:value) else{throw RestoreFailure.authorization}
  let store=KeychainSessionStore(service:(Bundle.main.bundleIdentifier ?? "com.example.backupclient")+".session"),auth=AuthAPI(baseURL:base,store:store),user=try await auth.me();guard let account=UUID(uuidString:user.id) else{throw RestoreFailure.authorization};let device=try await auth.currentDeviceID()
  canRestore=await restoreAllowed(auth)
  if self.account==account,self.device==device,let coordinator,let library{try await coordinator.activate(account:account,library:library);try await compoundCoordinator?.activate(account:account,library:library);return}
  await invalidate();let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RestoreQueue").appendingPathComponent(account.uuidString).appendingPathComponent(device.uuidString),files=try RestoreFiles(directory:root.appendingPathComponent("temporary")),queue=try RestoreQueue(url:root.appendingPathComponent("restore.sqlite"));let key="restore_library_"+account.uuidString+"_"+device.uuidString,library=UserDefaults.standard.string(forKey:key).flatMap(UUID.init(uuidString:)) ?? UUID();UserDefaults.standard.set(library.uuidString,forKey:key)
  guard let storageValue=Bundle.main.object(forInfoDictionaryKey:"StorageOrigin") as? String,let origin=URL(string:storageValue) else{throw RestoreFailure.authorization};let api=try HTTPRestoreAPI(base:base,tokens:store,allowLocalHTTP:_isDebugAssertConfiguration()),downloader=try FileRestoreDownloader(origin:origin,allowLocalHTTP:_isDebugAssertConfiguration()),coordinator=RestoreCoordinator(queue:queue,files:files,api:api,downloader:downloader,photos:PhotoKitRestorer());let compoundQueue=try CompoundRestoreQueue(url:root.appendingPathComponent("compound.sqlite")),compoundCoordinator=CompoundRestoreCoordinator(queue:compoundQueue,files:files,api:api,downloader:downloader,photos:CompoundPhotoKitRestorer());self.compoundQueue=compoundQueue;self.compoundCoordinator=compoundCoordinator;try await compoundCoordinator.activate(account:account,library:library);self.account=account;self.device=device;self.library=library;self.api=api;self.queue=queue;self.files=files;self.coordinator=coordinator;try await coordinator.activate(account:account,library:library);availableBytes=try? SystemDeviceCapacity().available(at:files.directory);canRestore=await restoreAllowed(auth)
 }
 func invalidate()async{worker?.cancel();await coordinator?.deactivate();await compoundCoordinator?.deactivate();await worker?.value;worker=nil;coordinator=nil;compoundCoordinator=nil;compoundQueue=nil;compounds=[];api=nil;queue=nil;files=nil;account=nil;device=nil;library=nil;assets=[];items=[];selected=[];progress=[:];nextCursor=nil;queueCursor=nil;canRestore=false}
 func loadAssets(next:Bool=false)async{do{try await connect();guard let api else{return};let page=try await api.inventory(cursor:next ? nextCursor:nil);assets=page.items;
 #if DEBUG
 assets=assets.filter{(ownerTestAssets?.contains($0.id) ?? ($0.id==developmentTestAsset)) && ["image","video"].contains($0.mediaType)};nextCursor=nil
 #else
 nextCursor=page.nextCursor
 #endif
selected=[];message=canRestore ? (ownerTestAssets != nil ? "Private staging test: restore one disposable item at a time. This creates a new Photos copy; keep originals." : "Select protected versions explicitly. Restoring creates new Photos items."):"Real restore is disabled until server and physical-device acceptance."}catch{message="Protected library unavailable. Sign in or retry when connected."}}
 var hasNextAssets:Bool{nextCursor != nil}
 func refresh(next:Bool=false)async{do{try await connect();if let queue,let account,let library{items=try await queue.page(account:account,library:library,after:next ? queueCursor:nil,limit:100);queueCursor=items.last?.id;if let compoundQueue{compounds=try await compoundQueue.page(account:account,library:library,limit:100)}};progress=await coordinator?.progressSnapshot() ?? [:]}catch{message="Restore is paused. Your queue is retained."}}
 func enqueue(again:Bool=false)async{busy=true;defer{busy=false};do{try await connect();guard canRestore,let api,let queue,let account,let library else{throw RestoreFailure.disabled};if let availableBytes,selectedBytes*2>availableBytes-64*1024*1024{message="Insufficient estimated device space. Select a smaller batch; unrelated content is never removed.";return};let planner=RestorePlanner(queue:queue,photos:PhotoKitRestorer());
 #if DEBUG
 guard selected.count==1,let selectedID=selected.first,(ownerTestAssets?.contains(selectedID) ?? (selectedID==developmentTestAsset)) else{throw RestoreFailure.disabled}
 let evidence=try await api.evidence(selected.first!);_=try await planner.enqueue(account:account,library:library,evidence:evidence,restoreAgain:again)
 #else
 for id in selected{if let manifest=try await api.manifestForAsset(id),![MediaKind.ordinary,.legacy].contains(manifest.kind){guard let compoundQueue else{throw RestoreFailure.disabled};let plan=try await api.compoundPlan(manifest.id,fingerprint:manifest.manifestFingerprint,choice:.all);try await compoundQueue.insert(CompoundRestoreRecord(account:account,library:library,plan:plan),restoreAgain:again)}else{let evidence=try await api.evidence(id);_=try await planner.enqueue(account:account,library:library,evidence:evidence,restoreAgain:again)}}
 #endif
 selected=[];await refresh()}catch RestoreFailure.duplicate{message="This version may already exist in Photos. Restore another copy only by explicit choice."}catch RestoreFailure.ambiguousSave{message="A previous save needs reconciliation. Restoring another copy may create a duplicate."}catch{message="Restore selection could not proceed. Cloud protection is unchanged."}}
 func tick()async{do{try await connect();if canRestore,worker==nil,let coordinator{worker=Task{await coordinator.runDue();if let compoundCoordinator=self.compoundCoordinator{await compoundCoordinator.runDue()};self.worker=nil}};await refresh()}catch{await coordinator?.deactivate();message="Authorization unavailable; no new Photos saves."}}
 func control(_ item:RestoreItem,_ action:String)async{do{try await connect();if action=="pause"{try await coordinator?.pause(item.id)}else if action=="cancel"{try await coordinator?.cancel(item.id)}else{try await coordinator?.resume(item.id)};await refresh()}catch{message="Save outcome requires review; an uncertain Photos save is never retried automatically."}}
 func compoundControl(_ r:CompoundRestoreRecord,_ action:String)async{do{try await connect();if action=="pause"{try await compoundCoordinator?.pause(r.id)}else if action=="cancel"{try await compoundCoordinator?.cancel(r.id)}else{try await compoundCoordinator?.resume(r.id)};await refresh()}catch{message="An uncertain Photos save requires reconciliation before retry."}}
 func restoreVariant(_ asset:UUID,choice:ManifestRestoreChoice)async{do{try await connect();guard canRestore,let api,let compoundQueue,let account,let library,let manifest=try await api.manifestForAsset(asset) else{throw RestoreFailure.disabled};let plan=try await api.compoundPlan(manifest.id,fingerprint:manifest.manifestFingerprint,choice:choice);try await compoundQueue.insert(CompoundRestoreRecord(account:account,library:library,plan:plan));await refresh()}catch{message="This restore variant is unsupported or awaits fidelity acceptance."}}
 func requestPermission()async{_=await PHPhotoLibrary.requestAuthorization(for:.addOnly);await refresh()}
}
struct RestoreView:View {
 @ObservedObject private var model=RestoreModel.shared
 @State private var confirmAnother=false
 var body:some View{NavigationStack{List{
  Section("Restore your backups"){Text(RestoreCopy.iCloudWarning).font(.footnote);Text("Restore creates a new Photos copy. Cloud protection and quota stay unchanged.").font(.footnote);Text(model.message);if let bytes=model.availableBytes{Text("Estimated device space: \(bytes.formatted(.byteCount(style:.file)))")};Text("Selected \(model.selectedPhotos) photos, \(model.selectedVideos) videos · \(model.selectedBytes.formatted(.byteCount(style:.file)))")
   Button("Allow Photos additions"){Task{await model.requestPermission()}}.disabled(!model.canRestore)
   Button("Restore selected to Photos"){Task{await model.enqueue()}}.disabled(model.selected.isEmpty||model.busy || !model.canRestore)
   Button("Restore another copy…"){confirmAnother=true}.disabled(model.selected.isEmpty || !model.canRestore)
  }
  Section("Choose items to restore"){ForEach(model.assets){asset in Toggle(isOn:Binding(get:{model.selected.contains(asset.id)},set:{if $0{model.selected.insert(asset.id)}else{model.selected.remove(asset.id)}})){Text("Protected \(asset.mediaType) · \((asset.sizeBytes ?? 0).formatted(.byteCount(style:.file)))")}};Button("Refresh protected library"){Task{await model.loadAssets()}};if model.hasNextAssets{Button("Next protected page"){Task{await model.loadAssets(next:true)}}}}
  Section("Live Photos and edited media"){Text("Live Photos require both resources. Edited assets require an explicit original or rendered choice; adjustment recipes cannot be reapplied exactly.");ForEach(model.assets){a in HStack{Button("Restore original"){Task{await model.restoreVariant(a.id,choice:.original)}};Button("Restore rendered edit"){Task{await model.restoreVariant(a.id,choice:.edited)}}.disabled(!model.canRestore)}};ForEach(model.compounds){r in VStack{Text("\(r.plan.manifest.kind.rawValue) · \(r.state.rawValue) · \(r.plan.resources.count) resources");if ![.restored,.saving,.reconcile,.cancelled].contains(r.state){HStack{Button("Pause"){Task{await model.compoundControl(r,"pause")}};Button("Retry"){Task{await model.compoundControl(r,"resume")}};Button("Cancel"){Task{await model.compoundControl(r,"cancel")}}}.buttonStyle(.borderless)}}}}
  Section("Restore progress"){ForEach(model.items){item in VStack(alignment:.leading){Text(item.state.displayTitle);Text("\((model.progress[item.id] ?? item.bytesDownloaded).formatted(.byteCount(style:.file))) / \(item.evidence.expectedSize.formatted(.byteCount(style:.file)))").font(.caption);if let code=item.lastErrorCode{Text(code.hasPrefix("PHOTOS_SAVE_ERROR_") ? "Photos reported a save error (code \(code.dropFirst(18))). This copy is unconfirmed; review before restoring again.":code=="SAVE_RESULT_UNCERTAIN" ? "Photos may already contain this copy. Review before restoring again.":code=="INTEGRITY_FAILED" ? "Downloaded bytes failed integrity checks.":code=="PHOTOS_PERMISSION_REQUIRED" ? "Allow Photos additions to continue.":"Restore paused or requires a retry.").font(.caption)};if ![.restored,.saving,.reconcile,.cancelled].contains(item.state){HStack{Button("Pause"){Task{await model.control(item,"pause")}};Button("Resume / Retry"){Task{await model.control(item,"resume")}};Button("Cancel"){Task{await model.control(item,"cancel")}}}.buttonStyle(.borderless)}}};Button("Next queue page"){Task{await model.refresh(next:true)}}}
 }.navigationTitle("Restore")}.confirmationDialog("Create another Photos copy?",isPresented:$confirmAnother,titleVisibility:.visible){Button("Restore another copy"){Task{await model.enqueue(again:true)}}}message:{Text("A previous or uncertain restore may already exist. This creates another copy and never removes existing Photos items.")}.task{await model.loadAssets();while !Task.isCancelled{await model.tick();try? await Task.sleep(for:.seconds(5))}}}
}
