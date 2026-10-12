#if canImport(SwiftUI)
import SwiftUI
import Foundation
public struct CloudStorageSummary:Decodable,Sendable {
 public let quotaBytes:Int64,protectedBytes:Int64,reservedBytes:Int64,remainingBytes:Int64,overQuota:Bool
}
public struct CleanupPolicy:Decodable,Sendable {public let enabled:Bool,developmentOnly:Bool,deviceId:UUID,planCode:String?}
public enum CleanupCopy {
 public static let warning="Remove selected items from your Photos library. If you use iCloud Photos, Apple may also remove them from your other Apple devices and iCloud Photos. Acloud keeps the verified backups separately. This action cannot be undone from Acloud."
 public static let cloudUsage="Removing Photos items does not reduce Acloud cloud storage usage. Space reclaimed by iOS may differ from this estimate and may not be immediate."
}
@MainActor public final class StorageManagementModel:ObservableObject {
 @Published public var cloud:CloudStorageSummary?
 @Published public var plan="Unavailable"
 @Published public var message="Sign in to view storage."
 @Published public var candidates:[CleanupCandidate]=[]
 @Published public var reasons:[UUID:CleanupReason]=[:]
 @Published public var selected:Set<UUID>=[]
 @Published public var history:[CleanupHistory]=[]
 @Published public var reviewSummary=""
 @Published public var knownBytes:Int64=0
 @Published public var unknownSizes=0
 @Published public var reviewReady=false
 @Published public var busy=false
 @Published public var enabled=false
 private var coordinator:LocalCleanupCoordinator?,store:LocalCleanupStore?,library:(any LocalPhotoLibrary)?,context:CleanupContext?
 private var workflowGeneration=UUID()
 public var configurationGeneration:UUID{workflowGeneration}
 public init(){}
 public func configure(context:CleanupContext,gate:CleanupGate,store:LocalCleanupStore,library:any LocalPhotoLibrary,server:any CleanupServer,recordRemoval:@escaping @Sendable(CleanupCandidate) async throws -> Void={_ in},recordReappearance:@escaping @Sendable(CleanupCandidate) async throws -> Void={_ in}){
  self.context=context;self.store=store;self.library=library;coordinator=LocalCleanupCoordinator(context:context,gate:gate,store:store,library:library,server:server,recordRemoval:recordRemoval,recordReappearance:recordReappearance);enabled=gate.allows
 }
 public func invalidate() async{workflowGeneration=UUID();await coordinator?.invalidateAccount();coordinator=nil;context=nil;store=nil;library=nil;candidates=[];selected=[];history=[];cloud=nil;enabled=false;reviewReady=false;message="Cleanup requires a new signed-in review."}
 public func background() async{workflowGeneration=UUID();await coordinator?.background();reviewReady=false}
 public func foreground(){coordinator?.resumeForeground()}
 public func refresh() async{
  guard let store,let library,let context else{return};let epoch=workflowGeneration
  do{try await coordinator?.reconcileStartup();let list=try await store.evidence(account:context.userID,limit:500),pending=try await store.pendingLocalIDs(context:context)
   let read=try await library.read(list.map{$0.backedUp.localID});guard epoch==workflowGeneration else{return}
   let filtered=list.map{c->CleanupCandidate in var c=c;c.pending=c.pending || pending.contains(c.backedUp.localID);return c},summary=FreeUpSpaceEligibilityService().scan(filtered,current:read.snapshots,context:context,permission:read.permission)
   candidates=filtered;reasons=summary.reasons;knownBytes=summary.knownBytes;unknownSizes=summary.unknownSizeCount;selected.formIntersection(Set(filtered.filter{reasons[$0.id] == .eligible}.map(\.id)));history=try await store.history(account:context.userID)
   message=enabled ? "Explicit review required. At most 10 items per confirmed batch.":"Free Up Space is disabled. Physical-iPhone acceptance and complete backup evidence are required."
  }catch{if epoch==workflowGeneration{message="Protection or local access could not be confirmed. No deletion was requested."}}
 }
 public func select(_ media:String?){selected=Set(candidates.filter{reasons[$0.id] == .eligible && (media==nil || $0.backedUp.mediaType==media)}.map(\.id))}
 public var selectedItems:[CleanupCandidate]{candidates.filter{selected.contains($0.id) && reasons[$0.id] == .eligible}}
 public var nextBatch:[CleanupCandidate]{var list:[CleanupCandidate]=[],resources=0;for c in selectedItems{if resources+c.resources.count>10{break};list.append(c);resources+=c.resources.count;if list.count==10{break}};return list}
 public func review() async{guard let coordinator,!busy else{return};busy=true;defer{busy=false};let epoch=workflowGeneration
  do{let batch=nextBatch;try await coordinator.review(batch);guard epoch==workflowGeneration else{return};let known=batch.compactMap{$0.backedUp.knownBytes}.reduce(Int64(0),+);reviewSummary="\(batch.filter{$0.backedUp.mediaType == "image"}.count) photos, \(batch.filter{$0.backedUp.mediaType == "video"}.count) videos. Known-size estimate: \(ByteCountFormatter.string(fromByteCount:known,countStyle:.file)). \(batch.filter{$0.backedUp.knownBytes == nil}.count) sizes unavailable.";reviewReady=true}catch{reviewReady=false;message="Review could not be approved. Recheck protection, permission and source evidence."}}
 public func cancelReview() async{reviewReady=false;await coordinator?.cancel()}
 public func confirm() async{guard let coordinator,!busy else{return};busy=true;defer{busy=false};reviewReady=false
  do{try await coordinator.confirm(explicit:true);selected=[];message="Photos request completed; checking local availability."}catch{message="Photos removal was cancelled or could not be confirmed. Reconciliation is required; deletion will not retry automatically."};await refresh()}
}
public struct StorageManagementView:View {
 @ObservedObject var model:StorageManagementModel
 @Environment(\.scenePhase) private var scenePhase
 @State private var confirming=false
 public init(model:StorageManagementModel){self.model=model}
 private func bytes(_ n:Int64)->String{ByteCountFormatter.string(fromByteCount:n,countStyle:.file)}
 public var body:some View{
  NavigationStack{List{
   Section("Acloud Storage"){
    Text("Plan: \(model.plan)");if let c=model.cloud{Text("Protected: \(bytes(c.protectedBytes))");Text("Remaining: \(bytes(c.remainingBytes))");Text("Plan capacity: \(bytes(c.quotaBytes))");if c.overQuota{Text("Over cloud quota. Existing verified backups are retained.")}}else{Text("Cloud usage unavailable")}
    Text(CleanupCopy.cloudUsage).font(.footnote)
   }
   Section("Photos library on this iPhone"){
    Text("Eligible in this page: \(model.candidates.filter{model.reasons[$0.id] == .eligible}.count)");Text("Known-size estimate: \(bytes(model.knownBytes))");Text("Size unavailable: \(model.unknownSizes)");Text("Not eligible: \(model.candidates.filter{model.reasons[$0.id] != .eligible}.count)")
    Text("Metadata review only. No originals are downloaded to scan eligibility.").font(.footnote)
   }
   Section("Free Up Space"){
    Text(model.message);Text(CleanupCopy.warning).font(.footnote)
    HStack{Button("All eligible"){model.select(nil)};Button("Photos"){model.select("image")};Button("Videos"){model.select("video")}}.disabled(!model.enabled || model.busy)
    ForEach(Array(model.candidates.enumerated()),id:\.element.id){index,item in
     Toggle(isOn:Binding(get:{model.selected.contains(item.id)},set:{if $0{model.selected.insert(item.id)}else{model.selected.remove(item.id)}})){
      Text("\(item.backedUp.mediaType == "video" ? "Video":"Photo") \(index+1)");Text(model.reasons[item.id]?.rawValue ?? "Unknown").font(.caption);Text(item.backedUp.knownBytes.map(bytes) ?? "Size unavailable").font(.caption)
     }.disabled(!model.enabled || model.reasons[item.id] != .eligible || model.busy)
    }
    Text("Selected photos: \(model.selectedItems.filter{$0.backedUp.mediaType == "image"}.count) · videos: \(model.selectedItems.filter{$0.backedUp.mediaType == "video"}.count)")
    Button("Review next batch (up to 10 items)"){Task{await model.review()}}.disabled(!model.enabled || model.selectedItems.isEmpty || model.busy)
   }
   Section("Recent cleanup"){if model.history.isEmpty{Text("No cleanup history")};ForEach(Array(model.history.enumerated()),id:\.offset){_,h in Text("\(h.removedCount) confirmed removed · \(bytes(h.knownBytes)) known-size estimate · \(h.state.rawValue)");if h.unknownSizes>0{Text("Partial estimate: \(h.unknownSizes) sizes unavailable")}}}
  }.navigationTitle("Storage")}
  .confirmationDialog("Remove the reviewed Photos items?",isPresented:Binding(get:{model.reviewReady},set:{model.reviewReady=$0;if !$0 && !confirming{Task{await model.cancelReview()}}}),titleVisibility:.visible){
   Button("Free Up Space",role:.destructive){confirming=true;Task{await model.confirm();confirming=false}}
   Button("Cancel",role:.cancel){Task{await model.cancelReview()}}
  }message:{Text(model.reviewSummary+"\n"+CleanupCopy.warning+"\n"+CleanupCopy.cloudUsage+"\nEach additional batch requires a new review and confirmation.")}
  .onChange(of:scenePhase){phase in if phase != .active{Task{await model.background()}}else{model.foreground()}}
 }
}
#endif
