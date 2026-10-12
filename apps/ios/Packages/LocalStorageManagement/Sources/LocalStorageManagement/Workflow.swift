import Foundation
public enum CleanupFailure:Error,Equatable {case disabled,identity,selection,localEvidence,proof,foreground,staleWorkflow,storage,systemCancelled,systemFailed}
public struct LibraryRead:Sendable {
 public let permission:CleanupPermission,snapshots:[String:LocalSnapshot],presence:[String:LocalPresence]
 public init(permission:CleanupPermission,snapshots:[String:LocalSnapshot],presence:[String:LocalPresence]){self.permission=permission;self.snapshots=snapshots;self.presence=presence}
}
public protocol LocalPhotoLibrary:Sendable {
 func read(_ localIDs:[String]) async throws -> LibraryRead
 func requestDeletion(_ candidates:[CleanupCandidate],context:CleanupContext) async throws
}
// Deliberately not Encodable: capabilities must never enter persistent job/history storage.
public struct CleanupProof:Decodable,Sendable {
 public let proofId:UUID,token:String,userId:UUID,deviceId:UUID,libraryId:UUID,expiresAt:Date,resources:[ResourceProtection]
 public init(proofId:UUID=UUID(),token:String,userId:UUID,deviceId:UUID,libraryId:UUID,expiresAt:Date,resources:[ResourceProtection]){self.proofId=proofId;self.token=token;self.userId=userId;self.deviceId=deviceId;self.libraryId=libraryId;self.expiresAt=expiresAt;self.resources=resources}
}
public struct CleanupReceipt:Decodable,Sendable {
 public let proofId:UUID,userId:UUID,deviceId:UUID,libraryId:UUID,assetIds:[UUID],expiresAt:Date,approved:Bool
 public init(proofId:UUID,userId:UUID,deviceId:UUID,libraryId:UUID,assetIds:[UUID],expiresAt:Date,approved:Bool=true){self.proofId=proofId;self.userId=userId;self.deviceId=deviceId;self.libraryId=libraryId;self.assetIds=assetIds;self.expiresAt=expiresAt;self.approved=approved}
}
public protocol CleanupServer:Sendable {
 func prepare(context:CleanupContext,assetIDs:[UUID]) async throws -> CleanupProof
 func consume(_ proof:CleanupProof) async throws -> CleanupReceipt
 func protectionStillOwned(context:CleanupContext,assetIDs:[UUID]) async throws -> Bool
 func report(proofID:UUID,result:String) async
}
@MainActor public final class LocalCleanupCoordinator {
 public private(set) var context:CleanupContext,job:CleanupJob?
 public private(set) var foreground=true
 private var generation=UUID(),proof:CleanupProof?,permission:CleanupPermission?
 private let store:LocalCleanupStore,library:any LocalPhotoLibrary,server:any CleanupServer
 private let gate:CleanupGate
 private let recordReappearance:@Sendable(CleanupCandidate) async throws -> Void
 private let recordRemoval:@Sendable(CleanupCandidate) async throws -> Void
 private var busy=false
 public init(context:CleanupContext,gate:CleanupGate,store:LocalCleanupStore,library:any LocalPhotoLibrary,server:any CleanupServer,recordRemoval:@escaping @Sendable(CleanupCandidate) async throws -> Void={_ in},recordReappearance:@escaping @Sendable(CleanupCandidate) async throws -> Void={_ in}){self.context=context;self.gate=gate;self.store=store;self.library=library;self.server=server;self.recordRemoval=recordRemoval;self.recordReappearance=recordReappearance}
 private func active(_ id:UUID)throws{guard foreground else{throw CleanupFailure.foreground};guard id==generation else{throw CleanupFailure.staleWorkflow}}
 private func eligible(_ candidates:[CleanupCandidate],read:LibraryRead)throws{
  guard read.permission == .authorized || read.permission == .limited else{throw CleanupFailure.localEvidence}
  let summary=FreeUpSpaceEligibilityService().scan(candidates,current:read.snapshots,context:context,permission:read.permission)
  guard summary.eligibleCount==candidates.count else{throw CleanupFailure.localEvidence}
 }
 private func scope(_ p:CleanupProof,_ candidates:[CleanupCandidate])->Bool {
  let expected=candidates.flatMap(\.resources),now=Date()
  guard p.userId==context.userID,p.deviceId==context.deviceID,p.libraryId==context.libraryID,p.expiresAt>now,p.expiresAt.timeIntervalSince(now)<=61,p.token.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,p.resources.count==expected.count,Set(p.resources.map(\.assetID)).count==p.resources.count else{return false}
  let map=Dictionary(uniqueKeysWithValues:expected.map{($0.assetID,$0)})
  return p.resources.allSatisfy{let e=map[$0.assetID];return e?.sizeBytes==$0.sizeBytes && e?.checksum==$0.checksum && $0.status=="PROTECTED"}
 }
 // Review never requests deletion. One foreground confirmation approves one bounded batch only.
 public func review(_ selected:[CleanupCandidate]) async throws {
  guard gate.allows else{throw CleanupFailure.disabled};guard !busy else{throw CleanupFailure.staleWorkflow};busy=true;defer{busy=false}
  guard foreground,!selected.isEmpty,selected.count<=10,Set(selected.map(\.id)).count==selected.count,Set(selected.map{$0.backedUp.localID}).count==selected.count,selected.flatMap(\.resources).count<=10,Set(selected.flatMap(\.resources).map(\.assetID)).count==selected.flatMap(\.resources).count else{throw CleanupFailure.selection}
  let pending=try await store.pendingLocalIDs(context:context);guard selected.allSatisfy({!pending.contains($0.backedUp.localID)}) else{throw CleanupFailure.selection}
  generation=UUID();let epoch=generation;proof=nil
  let read=try await library.read(selected.map{$0.backedUp.localID});try active(epoch);try eligible(selected,read:read)
  var j=CleanupJob(context:context,candidates:selected);job=j;try await store.save(j)
  let p=try await server.prepare(context:context,assetIDs:selected.flatMap(\.resources).map(\.assetID));try active(epoch);guard scope(p,selected) else{throw CleanupFailure.proof}
  let again=try await library.read(selected.map{$0.backedUp.localID});try active(epoch);guard read.permission==again.permission else{throw CleanupFailure.localEvidence};try eligible(selected,read:again)
  permission=again.permission;proof=p;j.state = .awaitingConfirmation;job=j;try await store.save(j)
 }
 public func cancel() async {generation=UUID();proof=nil;permission=nil;if var j=job,j.state == .awaitingConfirmation || j.state == .selected{j.state = .cancelled;job=j;try? await store.save(j)}}
 public func background() async{foreground=false;await cancel()}
 public func resumeForeground(){foreground=true}
 public func invalidateAccount() async{foreground=false;await cancel()}
 public func confirm(explicit:Bool) async throws {
  guard gate.allows else{throw CleanupFailure.disabled};guard !busy else{throw CleanupFailure.staleWorkflow};busy=true;defer{busy=false}
  guard explicit,let p=proof,var j=job,j.state == .awaitingConfirmation,j.context==context else{throw CleanupFailure.selection}
  let epoch=generation;try active(epoch);guard scope(p,j.candidates) else{proof=nil;throw CleanupFailure.proof}
  proof=nil // Consume capability once; failed/ambiguous responses require a new review.
  let receipt=try await server.consume(p);try active(epoch)
  guard receipt.approved,receipt.proofId==p.proofId,receipt.userId==context.userID,receipt.deviceId==context.deviceID,receipt.libraryId==context.libraryID,Set(receipt.assetIds)==Set(j.candidates.flatMap(\.resources).map(\.assetID)),receipt.expiresAt>Date(),receipt.expiresAt.timeIntervalSinceNow<=16 else{throw CleanupFailure.proof}
  let read=try await library.read(j.candidates.map{$0.backedUp.localID});try active(epoch);guard read.permission==permission else{throw CleanupFailure.localEvidence};try eligible(j.candidates,read:read)
  j.state = .deletionRequested;job=j;try await store.save(j);try active(epoch)
  j.state = .systemPending;job=j;try await store.save(j);try active(epoch);guard receipt.expiresAt>Date() else{throw CleanupFailure.proof}
  do{try await library.requestDeletion(j.candidates,context:context)}catch{j.state = error as? CleanupFailure == .systemCancelled ? .cancelled:.reconcileRequired;job=j;try? await store.save(j);await server.report(proofID:p.proofId,result:j.state == .cancelled ? "CANCELLED":"RECONCILE_REQUIRED");throw error}
  // If foreground/account changed during the system dialog, retain a pending journal for reconciliation.
  do{try active(epoch);try await reconcileJob(&j)}catch{j.state = .reconcileRequired;job=j;try? await store.save(j);throw error}
  job=j;await server.report(proofID:p.proofId,result:j.state == .removed ? "REMOVED":"RECONCILE_REQUIRED")
 }
 private func reconcileJob(_ j:inout CleanupJob) async throws {
  guard j.context==context else{throw CleanupFailure.identity}
  let epoch=generation,read=try await library.read(j.candidates.map{$0.backedUp.localID});try active(epoch)
  guard try await server.protectionStillOwned(context:context,assetIDs:j.candidates.flatMap(\.resources).map(\.assetID)) else{throw CleanupFailure.proof};try active(epoch)
  // Absence under limited/changed access is not proof of deletion.
  guard read.permission == .authorized else{throw CleanupFailure.localEvidence}
  for c in j.candidates {
   if read.presence[c.backedUp.localID] == .absentConfirmed {
    j.removed.insert(c.id);try await recordRemoval(c);try active(epoch)
   }else{j.removed.remove(c.id);if read.presence[c.backedUp.localID] == .present{try await recordReappearance(c);try active(epoch)}}
  }
  j.state = j.removed.count==j.candidates.count ? .removed:.reconcileRequired;try await store.save(j)
 }
 public func reconcileStartup() async throws {
  guard !busy else{throw CleanupFailure.staleWorkflow};busy=true;defer{busy=false}
  proof=nil;permission=nil;let epoch=generation;var after:UUID?
  while true{let jobs=try await store.jobs(account:context.userID,after:after);try active(epoch);if jobs.isEmpty{break};for var j in jobs where j.context==context{
   switch j.state {
   case .selected,.awaitingConfirmation:j.state = .cancelled;try await store.save(j)
   case .deletionRequested,.systemPending,.reconcileRequired,.removed:do{try await reconcileJob(&j)}catch{j.state = .reconcileRequired;try? await store.save(j)}
   case .cancelled,.failed:break
   }
  };after=jobs.last?.id}
  // This method never calls requestDeletion, prepare or consume.
 }
}
