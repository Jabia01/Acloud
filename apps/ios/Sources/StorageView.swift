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
struct StorageView:View {var body:some View{StorageManagementView(model:StorageScreen.model).task{await StorageScreen.connect()}}}
