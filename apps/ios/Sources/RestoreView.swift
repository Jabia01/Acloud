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
 private var nextCursor:String?,queueCursor:UUID?,queueAnchor:UUID?,account:UUID?,device:UUID?,library:UUID?
 @Published var showingLaterQueuePage=false
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
 func invalidate()async{worker?.cancel();await coordinator?.deactivate();await compoundCoordinator?.deactivate();await worker?.value;worker=nil;coordinator=nil;compoundCoordinator=nil;compoundQueue=nil;compounds=[];api=nil;queue=nil;files=nil;account=nil;device=nil;library=nil;assets=[];items=[];selected=[];progress=[:];nextCursor=nil;queueCursor=nil;queueAnchor=nil;showingLaterQueuePage=false;canRestore=false}
 func loadAssets(next:Bool=false)async{do{try await connect();guard let api else{return};let page=try await api.inventory(cursor:next ? nextCursor:nil);assets=page.items;
 #if DEBUG
 assets=assets.filter{(ownerTestAssets?.contains($0.id) ?? ($0.id==developmentTestAsset)) && ["image","video"].contains($0.mediaType)};nextCursor=page.nextCursor
 #else
 nextCursor=page.nextCursor
 #endif
selected=[];message=canRestore ? (ownerTestAssets != nil ? "Private staging test: restore one disposable item at a time. This creates a new Photos copy; keep originals." : "Select protected versions explicitly. Restoring creates new Photos items."):"Real restore is disabled until server and physical-device acceptance."}catch{message="Protected library unavailable. Sign in or retry when connected."}}
 var hasNextAssets:Bool{nextCursor != nil}
 func refresh(next:Bool=false)async{do{try await connect();if let queue,let account,let library{if next{queueAnchor=queueCursor};let requestedAnchor=queueAnchor;let page=try await queue.recent(account:account,library:library,after:requestedAnchor,limit:100);guard queueAnchor==requestedAnchor else{return};items=page;showingLaterQueuePage=queueAnchor != nil;queueCursor=items.last?.id;if let compoundQueue{compounds=try await compoundQueue.page(account:account,library:library,limit:100)}};progress=await coordinator?.progressSnapshot() ?? [:]}catch{message="Restore is paused. Your queue is retained."}}
 func firstQueuePage()async{queueAnchor=nil;await refresh()}
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
 func localPreviewID(for asset:UUID)->String? {
  guard let account else{return nil}
  guard let item=BackupQueueModel.shared.items.first(where:{$0.assetID==asset && $0.accountID==account}) else{return nil}
  return item.mediaResourceBinding?.sourceLocalID ?? item.originalManifest?.source.localID ?? (item.mediaType == "test" ? nil:item.localAssetIdentifier)
 }
 func localPreviewID(forManifest id:UUID)->String? {
  guard let account else{return nil}
  return BackupQueueModel.shared.manifests.first(where:{$0.id==id && $0.binding.accountID==account})?.source.localID
 }
 func requestPermission()async{_=await PHPhotoLibrary.requestAuthorization(for:.addOnly);await refresh()}
}

private extension ProtectedRestoreAsset {
 var backupDate:Date? {
  guard let protectedAt else{return nil}
  let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
  return formatter.date(from:protectedAt) ?? ISO8601DateFormatter().date(from:protectedAt)
 }
}
struct RestoreView:View {
 @ObservedObject private var model=RestoreModel.shared
 @State private var confirmAnother=false
 @State private var mediaFilter:AcloudMediaFilter = .all
 var body:some View {
  NavigationStack {
   List {
    Section {AcloudHero(icon:"arrow.down.circle",eyebrow:"Bring it back",title:"Back to your Photos.",message:"Select a verified backup to save a new copy to your device. Your cloud backup stays protected.").acloudFeatureRow()}
    Section("Restore your backups") {
     Text(RestoreCopy.iCloudWarning).font(.footnote)
     Text("Restore creates a new Photos copy. Cloud protection and quota stay unchanged.").font(.footnote)
     Text(model.message).font(.subheadline)
     if let bytes=model.availableBytes{Text("Estimated device space: \(bytes.formatted(.byteCount(style:.file)))").font(.caption)}
     Text("Selected \(model.selectedPhotos) photos, \(model.selectedVideos) videos · \(model.selectedBytes.formatted(.byteCount(style:.file)))").font(.subheadline)
     Button("Allow Photos additions"){Task{await model.requestPermission()}}.disabled(!model.canRestore)
     Button{Task{await model.enqueue()}}label:{Label("Restore selected to Photos",systemImage:"arrow.down.circle.fill").frame(maxWidth:.infinity)}
      .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selected.isEmpty || model.busy || !model.canRestore)
     Button("Restore another copy…"){confirmAnother=true}.disabled(model.selected.isEmpty || !model.canRestore)
    }
    Section("Choose items to restore") {
     Picker("Media type",selection:$mediaFilter){ForEach(AcloudMediaFilter.allCases){filter in Text(filter.rawValue).tag(filter)}}.pickerStyle(.segmented)
     Text("Grouped by backup date, newest first. A preview appears when the original is available locally.").font(.caption).foregroundStyle(.secondary)
     if model.assets.isEmpty{Text("No verified backups are available in this page.").foregroundStyle(.secondary)}
     else if model.assets.filter({mediaFilter.includes($0.mediaType)}).isEmpty{Text("No \(mediaFilter.rawValue.lowercased()) in this page.").foregroundStyle(.secondary)}
    }
    ForEach(acloudMediaGroups(model.assets.filter{mediaFilter.includes($0.mediaType)},type:{$0.mediaType},date:{$0.backupDate})) {group in
     Section {ForEach(group.items){asset in
      Toggle(isOn:Binding(get:{model.selected.contains(asset.id)},set:{if $0{model.selected.insert(asset.id)}else{model.selected.remove(asset.id)}})) {
       AcloudMediaHeader(type:asset.mediaType,reference:asset.id,localID:model.localPreviewID(for:asset.id),dateLabel:"Backed up",date:asset.backupDate,detail:asset.sizeBytes.map{"Verified size · \($0.formatted(.byteCount(style:.file)))"} ?? "Verified backup · size unavailable")
      }.padding(.vertical,8)
     }} header:{AcloudMediaGroupTitle(title:group.title+" · verified backups",date:group.day)}
    }
    Section {
     Button("Refresh protected library"){Task{await model.loadAssets()}}
     if model.hasNextAssets{Button("Next protected page"){Task{await model.loadAssets(next:true)}}}
     DisclosureGroup("Advanced restore: Live Photos and edits") {
      Text("Live Photos require both resources. Edited assets require an explicit original or rendered choice; adjustment recipes cannot be reapplied exactly.").font(.footnote)
      ForEach(model.assets.filter{mediaFilter.includes($0.mediaType)}){asset in
       VStack(alignment:.leading,spacing:8) {
        AcloudMediaHeader(type:asset.mediaType,reference:asset.id,localID:model.localPreviewID(for:asset.id),dateLabel:"Backed up",date:asset.backupDate)
        ViewThatFits(in:.horizontal){HStack{variantActions(asset.id)};VStack(alignment:.leading){variantActions(asset.id)}}.buttonStyle(.bordered).disabled(!model.canRestore)
       }.padding(.vertical,8)
      }
     }
    }
    if !model.items.isEmpty {
     Section("Restore progress"){Text("Grouped by the date each restore was requested.").font(.caption).foregroundStyle(.secondary)}
     ForEach(acloudMediaGroups(model.items.filter{mediaFilter.includes($0.evidence.mediaType)},type:{$0.evidence.mediaType},date:{$0.createdAt})){group in
      Section {ForEach(group.items){item in restoreRow(item)}} header:{AcloudMediaGroupTitle(title:group.title+" · restores",date:group.day)}
     }
    }
    ForEach(acloudMediaGroups(model.compounds.filter{mediaFilter.includes($0.plan.manifest.mediaType)},type:{$0.plan.manifest.mediaType},date:{$0.createdAt})){group in
     Section {ForEach(group.items){record in compoundRow(record)}} header:{AcloudMediaGroupTitle(title:group.title+" · complete-media restores",date:group.day)}
    }
    if model.items.count==100 || model.showingLaterQueuePage{Section{
     if model.items.count==100{Button("Next queue page"){Task{await model.refresh(next:true)}}}
     if model.showingLaterQueuePage{Button("First queue page"){Task{await model.firstQueuePage()}}}
    }}
   }.acloudCanvas().navigationTitle("Restore")
  }.confirmationDialog("Create another Photos copy?",isPresented:$confirmAnother,titleVisibility:.visible){Button("Restore another copy"){Task{await model.enqueue(again:true)}}}message:{Text("A previous or uncertain restore may already exist. This creates another copy and never removes existing Photos items.")}
   .task{await model.loadAssets();while !Task.isCancelled{await model.tick();try? await Task.sleep(for:.seconds(5))}}
 }
 private func restoreRow(_ item:RestoreItem)->some View {
  VStack(alignment:.leading,spacing:12) {
   AcloudMediaHeader(type:item.evidence.mediaType,reference:item.evidence.id,localID:item.localIdentifier ?? model.localPreviewID(for:item.evidence.id),dateLabel:"Restore requested",date:item.createdAt,detail:"Size · \(item.evidence.expectedSize.formatted(.byteCount(style:.file)))")
   Label(item.state.displayTitle,systemImage:item.state == .restored ? "checkmark.circle.fill":"arrow.down.circle")
    .font(.subheadline.weight(.semibold)).foregroundStyle(item.state == .restored ? AcloudStyle.accent:Color.primary)
   if item.state == .restored,let restoredAt=item.restoredAt{Text("Saved \(restoredAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))").font(.caption).foregroundStyle(.secondary)}
   else if item.state != .cancelled {
    ProgressView(value:Double(min(model.progress[item.id] ?? item.bytesDownloaded,item.evidence.expectedSize)),total:Double(max(1,item.evidence.expectedSize))).accessibilityLabel("Download progress")
    Text("\((model.progress[item.id] ?? item.bytesDownloaded).formatted(.byteCount(style:.file))) of \(item.evidence.expectedSize.formatted(.byteCount(style:.file))) downloaded").font(.caption).foregroundStyle(.secondary)
   }
   if let code=item.lastErrorCode {Text(restoreGuidance(code)).font(.subheadline).foregroundStyle(.secondary)}
   if ![.restored,.saving,.reconcile,.cancelled].contains(item.state) {
    ViewThatFits(in:.horizontal){HStack{restoreActions(item)};VStack(alignment:.leading){restoreActions(item)}}.buttonStyle(.bordered)
   }
   DisclosureGroup("Details & support") {
    VStack(alignment:.leading,spacing:6) {
     Text("Transfer reference: R-\(item.id.uuidString.prefix(8))").textSelection(.enabled)
     Text("Last updated \(item.updatedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
     if let code=item.lastErrorCode{Text(code).textSelection(.enabled)}
    }.font(.caption).foregroundStyle(.secondary)
   }.font(.caption)
  }.padding(.vertical,10)
 }
 private func compoundRow(_ record:CompoundRestoreRecord)->some View {
  VStack(alignment:.leading,spacing:12) {
   AcloudMediaHeader(type:record.plan.manifest.mediaType,reference:record.plan.manifest.id,localID:model.localPreviewID(forManifest:record.plan.manifest.id),dateLabel:"Restore requested",date:record.createdAt,detail:"\(record.plan.resources.count) files · \(record.plan.manifest.kind.rawValue.replacingOccurrences(of:"_",with:" ").capitalized)")
   Text(record.state.displayTitle).font(.subheadline.weight(.semibold))
   if ![.restored,.saving,.reconcile,.cancelled].contains(record.state) {
    HStack{Button("Pause"){Task{await model.compoundControl(record,"pause")}};Button("Retry"){Task{await model.compoundControl(record,"resume")}};Button("Cancel",role:.destructive){Task{await model.compoundControl(record,"cancel")}}}.buttonStyle(.bordered)
   }
   DisclosureGroup("Details & support"){Text("Transfer reference: R-\(record.id.uuidString.prefix(8))").font(.caption).textSelection(.enabled)}
  }.padding(.vertical,10)
 }
 @ViewBuilder private func variantActions(_ id:UUID)->some View {
  Button("Restore original"){Task{await model.restoreVariant(id,choice:.original)}}
  Button("Restore rendered edit"){Task{await model.restoreVariant(id,choice:.edited)}}
 }
 @ViewBuilder private func restoreActions(_ item:RestoreItem)->some View {
  if [.paused,.retryable,.permanent].contains(item.state){Button("Resume / Retry"){Task{await model.control(item,"resume")}}}
  else{Button("Pause"){Task{await model.control(item,"pause")}}}
  Button("Cancel",role:.destructive){Task{await model.control(item,"cancel")}}
 }
 private func restoreGuidance(_ code:String)->String {
  if code.hasPrefix("PHOTOS_SAVE_ERROR_"){return "Photos reported a save error (code \(code.dropFirst(18))). This copy is unconfirmed; review before restoring again."}
  if code=="SAVE_RESULT_UNCERTAIN"{return "Photos may already contain this copy. Review before restoring again."}
  if code=="INTEGRITY_FAILED"{return "Downloaded bytes failed integrity checks."}
  if code=="PHOTOS_PERMISSION_REQUIRED"{return "Allow Photos additions to continue."}
  return "Restore paused or requires a retry."
 }
}
