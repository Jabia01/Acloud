import SwiftUI
import UIKit
import BackupEngine
import MediaPreservation
import HealthClient
import Photos
import PhotosUI

#if DEBUG
@MainActor private final class BackupBackgroundTime {
 private var identifier:UIBackgroundTaskIdentifier = .invalid
 func begin(){identifier=UIApplication.shared.beginBackgroundTask(withName:"Finish backup step"){[weak self] in self?.end()}}
 func end(){guard identifier != .invalid else{return};UIApplication.shared.endBackgroundTask(identifier);identifier = .invalid}
}
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
 @Published var message="Sign in to open the development queue."
 @Published var busy=false
 @Published var canSelectOriginals=false
 @Published var originalProgress:Double=0
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
 private var accountID:String?
 private var worker:Task<Void,Never>?
 var backgroundCompletion:(@Sendable()->Void)?
 func connect() async throws {
  guard BetaReleaseSafety.acceptedConfiguration else{throw BackupFailure.missing}
  guard let baseString=Bundle.main.object(forInfoDictionaryKey:"APIBaseURL") as? String,let base=URL(string:baseString) else{throw BackupFailure.missing}
  let tokens=KeychainSessionStore(service:(Bundle.main.bundleIdentifier ?? "com.example.backupclient")+".session")
  let accountAPI=AuthAPI(baseURL:base,store:tokens)
  let account=try await accountAPI.me()
  #if !DEBUG
  guard try await accountAPI.realMediaAccepted() else{canSelectOriginals=false;throw BackupFailure.policy}
  let boundDevice=try await accountAPI.currentDeviceID()
  #endif
  #if DEBUG
  let photoTestEnabled=Bundle.main.object(forInfoDictionaryKey:"DevelopmentSinglePhotoBackup") as? Bool ?? false
  let boundDevice:UUID?
  if accountID==account.id,let deviceID {boundDevice=deviceID}
  else {boundDevice=photoTestEnabled ? try? await accountAPI.currentDeviceID() : nil}
  let photoAccessReady=photoTestEnabled && boundDevice != nil
  if engine != nil,accountID==account.id,canSelectOriginals==photoAccessReady{return}
  #else
  if engine != nil,accountID==account.id,deviceID==boundDevice{return}
  #endif
  if let engine{try await engine.pauseAll()}
  await transport?.shutdown()
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
  let background=Bundle.main.object(forInfoDictionaryKey:"DevelopmentBackgroundTransfers") as? Bool ?? false
  let transfer=try PartURLSessionTransport(origin:storage,background:background,allowLocalHTTP: _isDebugAssertConfiguration())
  let multipartAPI=try HTTPMultipartAPI(base:base,tokens:tokens,allowLocalHTTP:_isDebugAssertConfiguration());manifestAPI=multipartAPI
  #if DEBUG
  deviceID=boundDevice
  canSelectOriginals=photoAccessReady
  let preparer:any ResourcePreparer=DevelopmentTestPreparer(generated:GeneratedResourcePreparer(sourceDirectory:source!,files:files),photos:PhotoKitResourcePreparer(files:files,developmentEnabled:canSelectOriginals))
  #else
  let binding=ManifestBinding(accountID:user,deviceID:boundDevice,libraryID:lib),store=try ManifestStore(url:root.appendingPathComponent("manifests.sqlite"))
  manifestStore=store;preservationBinding=binding
  let ordinary=OriginalResourcePreparer(source:PhotoKitOriginalSource(),files:files,binding:OriginalBinding(accountID:user,deviceID:boundDevice,libraryID:lib),progress:{[weak self] value in Task{@MainActor in self?.originalProgress=value}})
  let preparer:any ResourcePreparer=PreservationResourcePreparer(ordinary:ordinary,multiple:MultiResourcePreparer(source:PhotoKitMediaSource(),store:store,files:files,binding:binding,invalidate:{id,fingerprint in try? await multipartAPI.invalidateManifest(id,fingerprint:fingerprint)}))
  canSelectOriginals=true
  #endif
  let e=BackupCoordinator(queue:q,api:multipartAPI,transport:transfer,preparer:preparer,files:files)
  queue=q;engine=e;transport=transfer;library=lib;accountID=account.id;monitor=BackupNetworkMonitor(coordinator:e)
  if let completion=backgroundCompletion{transfer.reconnect(completion:completion);backgroundCompletion=nil}
  var policy=BackupPolicy();policy.allowICloudOriginals=allowICloudOriginals;try await e.setPolicy(policy)
  try await e.reconcileStartup()
  #if DEBUG
  message=canSelectOriginals ? "Development test: explicitly choose one disposable still photo. Keep the original. Real-device validation remains pending." : (photoTestEnabled ? "Photo test unavailable: could not confirm this signed-in device. Open Account and sign in again, then return here." : "Photo test flag missing in this installed build. Run the updated Debug build from Xcode.")
  if (try? await accountAPI.ownerDeviceTestRestoreAssets()) != nil {
   message="Private staging test: at most two disposable items, 32 MB each. Keep originals. This is not beta release approval."
  }
  #else
  message="Choose assets explicitly. Each required original resource is verified separately. Keep originals; complex Photos fidelity acceptance remains pending."
  #endif
 }
 func refresh() async {
  do{try await connect();if let queue{summary=try await queue.summary();items=try await queue.page(limit:100)};await reconcileManifests()}catch{message="Backup connector unavailable. Device acceptance is pending."}
 }
 func enqueueGenerated() async {
  #if !DEBUG
  message="Generated upload adapters are unavailable in beta Release. Real PhotoKit backup acceptance is pending."
  return
  #else
  await action {
   guard let source=self.source,let library=self.library,let queue=self.queue else{throw BackupFailure.missing}
   let id=UUID(),url=source.appendingPathComponent(id.uuidString+".bin")
   guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw BackupFailure.storage}
   let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()}
   let chunk=Data(repeating:0x65,count:64*1024);for _ in 0..<320{try handle.write(contentsOf:chunk)};try handle.synchronize()
   _=try await queue.enqueue(BackupItem(libraryID:library,localAssetIdentifier:id.uuidString,mediaType:"test"))
  }
  #endif
 }
 func updateOriginalPolicy() async {await action{var policy=BackupPolicy();policy.allowICloudOriginals=self.allowICloudOriginals;try await self.engine?.setPolicy(policy)}}
 func enqueueSelected(_ ids:[String]) async {
  #if DEBUG
  await action {
   guard self.canSelectOriginals,ids.count==1,let id=ids.first,let queue=self.queue,let account=self.accountID.flatMap(UUID.init(uuidString:)),let device=self.deviceID,let library=self.library else{throw BackupFailure.authorization}
   let descriptor=try await PhotoKitOriginalSource().describe(id)
   guard descriptor.supported,["image","video"].contains(descriptor.mediaType) else {self.message="Choose one ordinary photo or unedited video. Live Photos, RAW, and edited media are excluded from this test.";return}
   if descriptor.mediaType == "video" {guard let duration=descriptor.duration,duration>0,duration<=30 else{self.message="Choose a short test video of 30 seconds or less.";return}}
   var item=BackupItem(libraryID:library,localAssetIdentifier:id,mediaType:descriptor.mediaType)
   item.accountID=account;item.deviceID=device
   _=try await queue.enqueue(item)
  }
  #else
  await action{
   guard self.canSelectOriginals,ids.count<=10,let queue=self.queue,let account=self.accountID.flatMap(UUID.init(uuidString:)),let device=self.deviceID,let library=self.library else{throw BackupFailure.authorization}
   guard let store=self.manifestStore,let api=self.manifestAPI else{throw BackupFailure.missing};let binding=ManifestBinding(accountID:account,deviceID:device,libraryID:library),planner=MultiResourceBackupPlanner(store:store,queue:queue);for id in Set(ids){let snapshot=try await PhotoKitMediaSource().snapshot(id);let manifest=try await planner.captureExplicit(source:snapshot,binding:binding);_=try await api.createManifest(manifest);_=try await planner.enqueue(manifest,binding:binding)}
  }
  #endif
 }
 func reconcileManifests()async{
  guard let store=manifestStore,let api=manifestAPI,let binding=preservationBinding else{return}
  guard let page=try? await store.page(binding:binding,after:manifestReconcileCursor,limit:50) else{return}
  manifestReconcileCursor=page.count==50 ? page.last?.id:nil
  for manifest in page{
   if let pending=manifest.changedFingerprint{try? await api.invalidateManifest(manifest.id,fingerprint:pending)}
   if let fresh=try? await PhotoKitMediaSource().snapshot(manifest.source.localID),!manifest.matches(fresh){try? await api.invalidateManifest(manifest.id,fingerprint:fresh.fingerprint);if var current=try? await store.read(manifest.id){current.state = .sourceChanged;current.changedFingerprint=fresh.fingerprint;_=try? await store.save(current)}}
   if let proof=try? await api.manifestProof(manifest.id){_=try? await store.apply(proof,to:manifest.id)}
  }
  manifests=(try? await store.page(binding:binding,limit:50)) ?? []
 }
 func action(_ operation:() async throws -> Void) async {
  busy=true;defer{busy=false}
  do{try await connect();try await operation();await refresh()}catch{message="Action paused or failed. The queue retains its state."}
 }
 func pauseAll() async{await action{try await self.engine?.pauseAll()}}
 func resumeAll() async{await action{try await self.engine?.resumeAll()}}
 func retryFailed() async{await action{try await self.engine?.retryAllFailed()}}
 func retry(_ id:UUID) async{await action{try await self.engine?.retryFailed(id)}}
 func pause(_ id:UUID) async{await action{try await self.engine?.pause(id)}}
 func resume(_ id:UUID) async{await action{try await self.engine?.resume(id)}}
 func cancel(_ id:UUID) async{await action{try await self.engine?.cancel(id)}}
 func tick() async {
  do{try await connect();if worker==nil,let engine{worker=Task{
   #if DEBUG
   let allowance=BackupBackgroundTime();allowance.begin();defer{allowance.end()}
   #endif
   defer{self.worker=nil};try? await engine.runDue();await self.refresh()}};await refresh()}catch{message="Waiting for account or API access."}
 }
 func stopForSignOut() async throws{worker?.cancel();try await engine?.pauseAll();await transport?.shutdown();await worker?.value;worker=nil;monitor=nil;engine=nil;transport=nil;queue=nil;manifestStore=nil;manifestAPI=nil;preservationBinding=nil;manifests=[];accountID=nil;deviceID=nil;canSelectOriginals=false;items=[];summary=[:]}
 func handleBackground(completion:@escaping @Sendable()->Void) async {
  backgroundCompletion={Task{@MainActor in
   // Drain in-process callbacks before reconciling daemon-completed parts.
   await self.worker?.value
   do{try await self.engine?.reconcileStartup();try await self.engine?.runDue();await self.refresh()}catch{self.message="Background upload will resume when the app is opened."}
   completion()
  }}
  do{try await connect();if let pending=backgroundCompletion{transport?.reconnect(completion:pending);backgroundCompletion=nil}}catch{completion();backgroundCompletion=nil}
 }
}
struct BackupQueueView:View {
 @ObservedObject private var model=BackupQueueModel.shared
 private enum PickerSelection:String,Identifiable {case photo,video,originals;var id:String{rawValue}}
 @State private var pickerSelection:PickerSelection?
 #if DEBUG
 private var developmentSelection:some View {
Section("Single-item development test") {
    Button("Choose One Test Photo") { pickerSelection = .photo }.disabled(!model.canSelectOriginals || model.busy)
    Button("Choose One Test Video") { pickerSelection = .video }.disabled(!model.canSelectOriginals || model.busy)
    Text("Choose a disposable screenshot or an unedited video of 30 seconds or less. Only your selected item is queued. Originals are kept; iCloud downloads are off.")
   }
 }
 #endif
 var body:some View {
  NavigationStack{List{
   Section("Backup Queue"){
    ForEach(BackupState.allCases,id:\.self){state in if let count=model.summary[state],count>0{Text("\(count) \(state.rawValue.lowercased())")}}
    Text(model.message).font(.footnote)
   }
   #if DEBUG
   developmentSelection
   #else
   Section("Original backup"){Toggle("Download iCloud originals on Wi-Fi",isOn:$model.allowICloudOriginals).onChange(of:model.allowICloudOriginals){_,_ in Task{await model.updateOriginalPolicy()}};Button("Choose originals for backup"){pickerSelection = .originals}.disabled(!model.canSelectOriginals||model.busy);Text("Selection is explicit. Photos are never deleted automatically.");if model.originalProgress>0{ProgressView(value:model.originalProgress)}}
   #endif
   #if DEBUG
   Section("Development Controls"){
    Button("Queue Generated 20 MiB File"){Task{await model.enqueueGenerated()}}
    Button("Pause All"){Task{await model.pauseAll()}}
    Button("Resume"){Task{await model.resumeAll()}}
    Button("Retry Failed"){Task{await model.retryFailed()}}
   }.disabled(model.busy)
   #endif
   Section("Complete media preservation"){ForEach(model.manifests){manifest in VStack(alignment:.leading){Text(manifest.source.kind == .livePhoto ? "Live Photo":manifest.source.kind == .rawJPEG ? "RAW + JPEG":manifest.source.kind == .edited ? "Edited media":"Original media");Text(manifest.state == .fullyProtected ? "Required resources protected":manifest.state == .sourceChanged ? "Source changed — recapture required":"Preservation incomplete or awaiting verification");Text("\(manifest.required.filter{$0.status=="PROTECTED"}.count) of \(manifest.required.count) required resources protected").font(.caption);Text("Photos reconstruction and cleanup require format-specific device acceptance.").font(.caption)}}}
   Section("First 100 Items"){
    ForEach(model.items){item in VStack(alignment:.leading){Text(item.state.rawValue);if item.lastErrorCode=="WAITING_FOR_ICLOUD_ORIGINAL"{Text("Original requires an iCloud download. Allow Wi-Fi downloads, then resume.").font(.caption)};Text("\(item.bytesUploaded) bytes transferred").font(.caption);if let code=item.lastErrorCode,item.state != .protected{Text("Diagnostic: \(code)").font(.caption).textSelection(.enabled)}
     HStack{Button("Pause"){Task{await model.pause(item.id)}};if [.failedPermanent,.failedRetryable].contains(item.state){Button("Retry"){Task{await model.retry(item.id)}}}else{Button("Resume"){Task{await model.resume(item.id)}}};Button("Cancel"){Task{await model.cancel(item.id)}}}.buttonStyle(.borderless).disabled(item.state == .protected)
    }}
   }
  }.navigationTitle("Backup Queue")}.sheet(item:$pickerSelection){selection in OriginalAssetPicker(videoOnly:selection == .video){ids in pickerSelection=nil;Task{await model.enqueueSelected(ids)}}.id(selection.id)}.task{await model.refresh();while !Task.isCancelled{await model.tick();try? await Task.sleep(for:.seconds(5))}}
 }
}

private struct OriginalAssetPicker:UIViewControllerRepresentable {
 let videoOnly:Bool
 let selected:([String])->Void
 func makeCoordinator()->Coordinator{Coordinator(selected:selected)}
 func makeUIViewController(context:Context)->PHPickerViewController{var config=PHPickerConfiguration(photoLibrary:.shared());
  #if DEBUG
  config.filter = videoOnly ? .videos:.images;config.selectionLimit=1
  #else
  config.filter = .any(of:[.images,.videos]);config.selectionLimit=10
  #endif
  let picker=PHPickerViewController(configuration:config);picker.delegate=context.coordinator;return picker}
 func updateUIViewController(_ controller:PHPickerViewController,context:Context){}
 final class Coordinator:NSObject,PHPickerViewControllerDelegate{let selected:([String])->Void;init(selected:@escaping([String])->Void){self.selected=selected};func picker(_ picker:PHPickerViewController,didFinishPicking results:[PHPickerResult]){selected(results.compactMap(\.assetIdentifier))}}
}
