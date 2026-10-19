import SwiftUI
import LocalStorageManagement
import HealthClient
import BackupEngine
@MainActor final class StorageScreen {
 static let model=StorageManagementModel()
 static func connect() async{
  await model.invalidate()
  let epoch=model.configurationGeneration
  do{
   guard BetaReleaseSafety.acceptedConfiguration,let value=Bundle.main.object(forInfoDictionaryKey:"APIBaseURL") as? String,let base=URL(string:value) else{return}
   let tokens=KeychainSessionStore(service:(Bundle.main.bundleIdentifier ?? "com.example.backupclient")+".session"),account=try await AuthAPI(baseURL:base,store:tokens).me(),server=try HTTPCleanupServer(base:base,tokens:tokens,allowLocalHTTP:_isDebugAssertConfiguration())
   let policy=try await server.get("storage/free-up-space/policy",type:CleanupPolicy.self),cloud=try await server.get("storage/summary",type:CloudStorageSummary.self)
   guard let user=UUID(uuidString:account.id),let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else{return}
   let libKey="backup_library_"+user.uuidString,library=UserDefaults.standard.string(forKey:libKey).flatMap(UUID.init(uuidString:)) ?? UUID();UserDefaults.standard.set(library.uuidString,forKey:libKey)
   let context=CleanupContext(userID:user,deviceID:policy.deviceId,libraryID:library),store=try LocalCleanupStore(url:support.appendingPathComponent("LocalCleanup/"+user.uuidString+"/cleanup.sqlite"))
   #if DEBUG
   let development=true
   #else
   let development=false
   #endif
   let gate=CleanupGate(developmentBuild:development,explicitFlag:Bundle.main.object(forInfoDictionaryKey:"EnableFreeUpSpace") as? Bool ?? false,disposableContext:Bundle.main.object(forInfoDictionaryKey:"DisposableCleanupContext") as? Bool ?? false,serverEnabled:policy.enabled)
   // No real-library capture/allowlist is invented. Complete destructive backup evidence is still unavailable.
   let photos=PhotoKitDeletionAdapter(gate:gate,context:context)
   let queue=try SQLiteBackupQueue(url:support.appendingPathComponent("BackupQueue/"+user.uuidString+"/queue.sqlite"))
   let update:@Sendable(CleanupCandidate,Bool) async throws -> Void={candidate,removed in
    guard candidate.context==context,candidate.resources.count==1,let resource=candidate.resources.first,let item=try await queue.find(library:context.libraryID,localID:candidate.backedUp.localID),resource.sizeBytes<=Int64(Int.max) else{throw CleanupFailure.storage}
    try await queue.recordLocalRemoval(item.id,assetID:resource.assetID,size:Int(resource.sizeBytes),checksum:resource.checksum,removed:removed)
   }
   guard epoch==model.configurationGeneration else{return}
   model.configure(context:context,gate:gate,store:store,library:photos,server:server,recordRemoval:{try await update($0,true)},recordReappearance:{try await update($0,false)});model.cloud=cloud;model.plan=policy.planCode ?? "Unavailable";await model.refresh()
  }catch{guard epoch==model.configurationGeneration else{return};model.message="Storage unavailable. Sign in with this device and check the server."}
 }
}
struct StorageView:View {
 @ObservedObject private var model=StorageScreen.model
 var body:some View {
  NavigationStack {
   List {
    Section {
     AcloudHero(icon:"externaldrive",eyebrow:"Acloud storage",title:"Know what is protected.",message:"Your cloud storage and device storage are separate. Backing up a file never removes its original.").acloudFeatureRow()
    }
    Section("Cloud storage") {
     if let cloud=model.cloud {
      VStack(alignment:.leading,spacing:14) {
       Text("\(acloudCapacity(cloud.protectedBytes)) protected").font(.system(.title2,design:.rounded).weight(.bold))
       ProgressView(value:Double(min(cloud.protectedBytes,cloud.quotaBytes)),total:Double(max(1,cloud.quotaBytes))).accessibilityLabel("Cloud storage used")
       Text("\(acloudCapacity(cloud.quotaBytes)) total capacity").foregroundStyle(.secondary)
       Text("Capacity uses GiB: a 5 GB plan is about 4.7 GiB. Live Photos and edits may contain several resource files.").font(.caption).foregroundStyle(.secondary)
       if cloud.overQuota {Label("Storage limit reached. Existing verified backups are retained.",systemImage:"exclamationmark.circle").foregroundStyle(.orange)}
      }.padding(.vertical,10)
      LazyVGrid(columns:[GridItem(.adaptive(minimum:140),spacing:12)],spacing:12) {
       AcloudMetric(title:"Available",value:acloudCapacity(cloud.remainingBytes),icon:"externaldrive.badge.plus")
       AcloudMetric(title:"Reserved for transfers",value:acloudCapacity(cloud.reservedBytes),icon:"arrow.up.circle")
      }.acloudFeatureRow()
     } else {
      Label("Storage usage is unavailable",systemImage:"externaldrive.badge.questionmark").font(.headline)
      Text("Sign in and check your connection, then refresh. No storage amount is estimated here.").foregroundStyle(.secondary)
     }
     Button {Task{await StorageScreen.connect()}} label:{Label("Refresh storage",systemImage:"arrow.clockwise")}.disabled(model.busy)
    }
    Section("Device space") {
     Label("Your originals stay on your device",systemImage:"iphone.and.arrow.forward").font(.headline)
     Text("Free Up Space is unavailable unless its separate safety checks are approved. Keep another copy of your originals during beta.").foregroundStyle(.secondary)
     if model.enabled {
      NavigationLink("Review Free Up Space") {StorageManagementView(model:model)}
     }
    }
   }.acloudCanvas().navigationTitle("Storage")
  }.task{await StorageScreen.connect()}
 }
}
