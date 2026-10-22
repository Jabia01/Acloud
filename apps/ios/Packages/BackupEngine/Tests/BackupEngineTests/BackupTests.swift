import XCTest
import Foundation
import CryptoKit
import UploadFoundation
import DiscoveryCore
@testable import BackupEngine

private func asset(_ id:UUID,status:String,size:Int) throws -> ServerAsset {
 try JSONDecoder().decode(ServerAsset.self,from:JSONSerialization.data(withJSONObject:["id":id.uuidString,"mediaType":"test","status":status,"sizeBytes":size]))
}
private actor TestAPI:MultipartAPI {
 let id=UUID(),assetID=UUID();var phase:RemoteAssetStatus = .queued;var size=0;var accepted:[CompletedPart]=[]
 var createError:BackupFailure?;var creates=0;var completed=false;var verificationUnavailable=false;var cancelled=false;var authorizations=0;var cancellationUnavailable=false
 func create(_ item:BackupItem) throws -> MultipartSession {creates+=1;if let createError{throw createError};size=item.expectedSizeBytes!;return response()}
 func response() -> MultipartSession {MultipartSession(id:id,assetId:assetID,status:phase,partSizeBytes:5*1024*1024)}
 func status(_ id:UUID) -> MultipartSession{response()}
 func start(_ id:UUID) -> MultipartSession{phase = .uploading;return response()}
 func parts(_ id:UUID) -> PartListing{PartListing(completed:completed,parts:accepted)}
 func authorize(_ id:UUID,number:Int,size:Int,checksum:String) throws -> UploadAuthorization {
  authorizations+=1
  return try JSONDecoder().decode(UploadAuthorization.self,from:JSONSerialization.data(withJSONObject:["method":"PUT","url":"https://storage.example.invalid/part","headers":["content-length":String(size)],"expiresAt":"2099-01-01T00:00:00.000Z"]))
 }
 func complete(_ id:UUID) -> MultipartSession{completed=true;phase = .uploaded;return response()}
 func verify(_ id:UUID) throws -> MultipartSession{if verificationUnavailable{throw BackupFailure.http(503)};phase = .protected;return response()}
 func asset(_ id:UUID) throws -> ServerAsset{try BackupEngineTests.remote(assetID,status:phase.rawValue,size:size)}
 func cancel(_ id:UUID)throws{if cancellationUnavailable{throw BackupFailure.http(503)};cancelled=true;phase = .cancelled}
 func failCreate(_ error:BackupFailure?){createError=error}
 func failCancellation(_ value:Bool){cancellationUnavailable=value}
 func accept(_ number:Int,size:Int){accepted.removeAll{$0.partNumber==number};accepted.append(CompletedPart(partNumber:number,sizeBytes:size))}
 func failVerification(_ value:Bool){verificationUnavailable=value}
 func forceProtected(size:Int){self.size=size;phase = .protected;completed=true}
}
private actor TestTransport:PartTransport {
 nonisolated let keepsTransfersDuringConnectionLoss:Bool
 var backgroundIDs:Set<UUID>=[];var cancelledIDs:Set<UUID>=[]
 func background(_ id:UUID){backgroundIDs.insert(id)}
 func activeItemIDs()async->Set<UUID>{backgroundIDs}
 let api:TestAPI;var numbers:[Int]=[];var delayMillis=0,inFlight=0,maximumInFlight=0;var failNumber:Int?;var loseResponse=false;var failAuthorization=false;var failuresRemaining=1
 init(api:TestAPI,background:Bool=false){self.api=api;keepsTransfersDuringConnectionLoss=background}
 func slow(_ milliseconds:Int){delayMillis=milliseconds}
 func configure(fail:Int?,lose:Bool=false,expired:Bool=false,times:Int=1){failNumber=fail;loseResponse=lose;failAuthorization=expired;failuresRemaining=times}
 func upload(item:UUID,number:Int,resource:PreparedResource,authorization:UploadAuthorization,policy:BackupPolicy) async throws {
  numbers.append(number);inFlight+=1;maximumInFlight=max(maximumInFlight,inFlight);defer{inFlight-=1}
  if delayMillis>0{try await Task.sleep(for:.milliseconds(delayMillis))}
  if failNumber==number {failuresRemaining-=1;if failuresRemaining==0{failNumber=nil};if loseResponse{await api.accept(number,size:resource.sizeBytes)};throw failAuthorization ? BackupFailure.authorization : URLError(.networkConnectionLost)}
  await api.accept(number,size:resource.sizeBytes)
 }
 func cancel(item:UUID) {backgroundIDs.remove(item);cancelledIDs.insert(item)}
}
private actor HoldingBackgroundTransport:PartTransport {
 nonisolated let keepsTransfersDuringConnectionLoss=true
 let api:TestAPI;var started=false;var cancelled=false;var itemID:UUID?
 private var completion:CheckedContinuation<Void,Error>?
 init(api:TestAPI){self.api=api}
 func activeItemIDs()async->Set<UUID>{itemID.map{[$0]} ?? []}
 func upload(item:UUID,number:Int,resource:PreparedResource,authorization:UploadAuthorization,policy:BackupPolicy)async throws {
  itemID=item;defer{itemID=nil}
  try await withCheckedThrowingContinuation{completion=$0;started=true}
  await api.accept(number,size:resource.sizeBytes)
 }
 func release(){let callback=completion;completion=nil;callback?.resume()}
 func cancel(item:UUID)async{cancelled=true;itemID=nil;let callback=completion;completion=nil;callback?.resume(throwing:CancellationError())}
}
private struct WaitingPreparer:ResourcePreparer {
 let denied:Bool
 func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot) async throws -> PreparedResource{throw denied ? BackupFailure.inaccessible : BackupFailure.waitingForOriginal}
 func cleanup(_ item:BackupItem) async throws {}
}
final class BackupEngineTests:XCTestCase {
 fileprivate static func remote(_ id:UUID,status:String,size:Int) throws -> ServerAsset{try asset(id,status:status,size:size)}
 private func directory() throws -> URL {let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:d)};return d}
 private func fixture(bytes:Int=12*1024*1024,partConcurrency:Int=1,onProtected:@escaping @Sendable() async->Void={}) async throws -> (SQLiteBackupQueue,BackupCoordinator,TestAPI,TestTransport,BackupItem,ManagedTemporaryFiles,URL) {
  let d=try directory(),source=d.appendingPathComponent("source");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
  let local=UUID(),url=source.appendingPathComponent(local.uuidString+".bin")
  FileManager.default.createFile(atPath:url.path,contents:nil);let h=try FileHandle(forWritingTo:url)
  var left=bytes;let chunk=Data(repeating:0x65,count:64*1024);while left>0{try h.write(contentsOf:chunk.prefix(min(chunk.count,left)));left-=min(chunk.count,left)};try h.close()
  let files=try ManagedTemporaryFiles(directory:d.appendingPathComponent("temp")),queue=try SQLiteBackupQueue(url:d.appendingPathComponent("queue.sqlite"))
  let api=TestAPI(),transport=TestTransport(api:api),item=BackupItem(libraryID:UUID(),localAssetIdentifier:local.uuidString,mediaType:"test")
  _=try await queue.enqueue(item)
  let engine=BackupCoordinator(queue:queue,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:source,files:files),files:files,partConcurrency:partConcurrency,onProtected:onProtected)
  try await engine.setNetwork(NetworkSnapshot());return(queue,engine,api,transport,item,files,d)
 }
 func testNoDeviceSpacePausesBeforePreparingOrCreatingServerReservation()async throws {
  let(q,_,api,t,item,files,d)=try await fixture(bytes:100)
  let engine=BackupCoordinator(queue:q,api:api,transport:t,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files,availableSpace:{_ in 1})
  try await engine.setNetwork(NetworkSnapshot())
  do{try await engine.run(item.id);XCTFail("Expected space failure")}catch{XCTAssertEqual(error as? BackupFailure,.deviceSpace)}
  let saved=try await q.read(item.id),created=await api.creates
  XCTAssertEqual(saved?.state,.paused);XCTAssertEqual(saved?.lastErrorCode,"DEVICE_SPACE_REQUIRED");XCTAssertEqual(created,0)
 }
 func testCloudQuotaPausesWithoutConsumingNetworkRetryBudgetAndCanResume()async throws {
  let(q,e,api,_,item,_,_)=try await fixture(bytes:100);await api.failCreate(.cloudQuota)
  do{try await e.run(item.id);XCTFail("Expected quota failure")}catch{XCTAssertEqual(error as? BackupFailure,.cloudQuota)}
  let saved=try await q.read(item.id);XCTAssertEqual(saved?.state,.paused);XCTAssertEqual(saved?.lastErrorCode,"CLOUD_QUOTA_REQUIRED");XCTAssertEqual(saved?.retryCount,0)
  await api.failCreate(nil);try await e.resume(item.id);try await e.run(item.id);let state=try await q.read(item.id)?.state;XCTAssertEqual(state,.protected)
 }
 func testParallelMultipartIsBoundedAndReconcilesBeforeProtection()async throws {
  let(q,e,api,t,item,_,_)=try await fixture(partConcurrency:2)
  await t.slow(40);try await e.run(item.id)
  let maximum=await t.maximumInFlight,numbers=await t.numbers,parts=try await q.parts(item.id),state=try await q.read(item.id)?.state,complete=await api.completed
  XCTAssertEqual(maximum,2);XCTAssertEqual(numbers.sorted(),[1,2,3]);XCTAssertEqual(parts.count,3);XCTAssertEqual(state,.protected);XCTAssertTrue(complete)
 }
 func testParallelMultipartFailureRetainsAcceptedPartsForRetry()async throws {
  let(q,e,_,t,item,_,_)=try await fixture(partConcurrency:2)
  await t.slow(20);await t.configure(fail:2)
  do{try await e.run(item.id);XCTFail()}catch{}
  let failed=try await q.read(item.id)?.state;XCTAssertEqual(failed,.failedRetryable)
  try await e.retryFailed(item.id);try await e.run(item.id)
  let numbers=await t.numbers,state=try await q.read(item.id)?.state
  XCTAssertEqual(numbers.filter{$0==1}.count,1);XCTAssertEqual(numbers.filter{$0==2}.count,2);XCTAssertEqual(state,.protected)
 }
 private actor PreparationSlots:ResourcePreparer {
  var started=0,maximum=0,active=0,released=false
  var waiters:[CheckedContinuation<Void,Never>]=[]
  func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot)async throws->PreparedResource{
   started+=1;active+=1;maximum=max(maximum,active);defer{active-=1}
   if !released{await withCheckedContinuation{waiters.append($0)}}
   throw BackupFailure.waitingForOriginal
  }
  func release(){released=true;let pending=waiters;waiters=[];for waiter in pending{waiter.resume()}}
  func cleanup(_ item:BackupItem)async throws{}
 }
 func testDueQueueUsesTwoSlotsAndRejectsOverlappingWorkers()async throws {
  let(q,_,api,t,item,files,_)=try await fixture(bytes:100),preparer=PreparationSlots()
  for _ in 0..<2{_=try await q.enqueue(BackupItem(libraryID:item.libraryID,localAssetIdentifier:UUID().uuidString,mediaType:"test"))}
  let e=BackupCoordinator(queue:q,api:api,transport:t,preparer:preparer,files:files)
  try await e.setNetwork(NetworkSnapshot());let worker=Task{try await e.runDue()}
  for _ in 0..<200{if await preparer.started==2{break};try await Task.sleep(for:.milliseconds(5))}
  try await e.runDue();let initial=await preparer.started
  await preparer.release();try await worker.value
  let maximum=await preparer.maximum,total=await preparer.started
  XCTAssertEqual(initial,2);XCTAssertEqual(maximum,2);XCTAssertEqual(total,3)
 }
 private actor ProtectionEvents {var count=0;func add(){count+=1}}
 func testBackgroundAlertHookWaitsForServerVerificationAndFiresBeforeWorkerReturns()async throws{
  let events=ProtectionEvents()
  let(q,e,api,_,item,_,_)=try await fixture(bytes:100,onProtected:{await events.add()})
  await api.failVerification(true);do{try await e.run(item.id)}catch{}
  let unverified=await events.count;XCTAssertEqual(unverified,0)
  await api.failVerification(false);try await e.retryFailed(item.id);try await e.run(item.id)
  let verified=await events.count,state=try await q.read(item.id)?.state
  XCTAssertEqual(verified,1);XCTAssertEqual(state,.protected)
  try await e.reconcileStartup();let afterRelaunch=await events.count;XCTAssertEqual(afterRelaunch,1)
 }
 func testFailureStageSurvivesQueueReopenWithoutChangingLegacyRecords()async throws {
  let(q,e,api,_,item,_,d)=try await fixture(bytes:100)
  await api.failVerification(true);do{try await e.run(item.id);XCTFail()}catch{}
  let reopened=try SQLiteBackupQueue(url:d.appendingPathComponent("queue.sqlite"))
  let failed=try await reopened.read(item.id)
  XCTAssertEqual(failed?.lastFailureStage,"Verifying saved backup")
  try await e.retryFailed(item.id);let retried=try await q.read(item.id)
  XCTAssertNil(retried?.lastFailureStage)
  var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as! [String:Any]
  legacy.removeValue(forKey:"lastFailureStage")
  let decoded=try JSONDecoder().decode(BackupItem.self,from:JSONSerialization.data(withJSONObject:legacy))
  XCTAssertNil(decoded.lastFailureStage)
 }
 func testBackgroundConnectionLossRecoversWithoutForegroundTimer()async throws {
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=TestTransport(api:api,background:true)
  await transport.configure(fail:1)
  let engine=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await engine.setNetwork(NetworkSnapshot());try await engine.run(item.id)
  let state=try await q.read(item.id)?.state,calls=await transport.numbers,auths=await api.authorizations
  XCTAssertEqual(state,.protected);XCTAssertEqual(calls,[1,1]);XCTAssertEqual(auths,2)
 }
 func testRepeatedBackgroundDropsUseBoundedRecoveryThenDurableRetry()async throws {
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=TestTransport(api:api,background:true)
  await transport.configure(fail:1,times:10)
  let engine=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await engine.setNetwork(NetworkSnapshot());do{try await engine.run(item.id);XCTFail()}catch{}
  let result=try await q.read(item.id),calls=await transport.numbers
  XCTAssertEqual(result?.state,.failedRetryable);XCTAssertEqual(result?.lastErrorCode,"NETWORK_-1005")
  XCTAssertNotNil(result?.nextRetryAt);XCTAssertEqual(calls,[1,1,1])
 }
 func testUserPauseWinsDuringBackgroundDropRecovery()async throws {
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=TestTransport(api:api,background:true)
  await transport.configure(fail:1,times:10)
  let engine=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await engine.setNetwork(NetworkSnapshot());let running=Task{try await engine.run(item.id)}
  for _ in 0..<200{if !(await transport.numbers).isEmpty{break};try await Task.sleep(for:.milliseconds(10))}
  try await engine.pause(item.id);_=try? await running.value
  let state=try await q.read(item.id)?.state,calls=await transport.numbers
  XCTAssertEqual(state,.paused);XCTAssertEqual(calls,[1])
 }
 func testBackgroundLostResponseDoesNotResendAcceptedPart()async throws {
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=TestTransport(api:api,background:true)
  await transport.configure(fail:1,lose:true)
  let engine=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await engine.setNetwork(NetworkSnapshot());try await engine.run(item.id)
  let state=try await q.read(item.id)?.state,calls=await transport.numbers
  XCTAssertEqual(state,.protected);XCTAssertEqual(calls,[1])
 }
 func testBackgroundDaemonRetainsUploadDuringConnectionLoss()async throws{
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=HoldingBackgroundTransport(api:api)
  let engine=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await engine.setNetwork(NetworkSnapshot())
  let running=Task{try await engine.run(item.id)};defer{running.cancel()}
  for _ in 0..<200{if await transport.started{break};try await Task.sleep(for:.milliseconds(10))}
  let started=await transport.started;XCTAssertTrue(started)
  try await engine.setNetwork(NetworkSnapshot(connected:false))
  let cancelled=await transport.cancelled,state=try await q.read(item.id)?.state
  XCTAssertFalse(cancelled);XCTAssertEqual(state,.uploading)
  try await engine.setNetwork(NetworkSnapshot());await transport.release();try await running.value
  let finished=try await q.read(item.id)?.state;XCTAssertEqual(finished,.protected)
 }
 func testBackgroundDaemonStillStopsWhenWiFiPolicyWouldBeViolated()async throws{
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=HoldingBackgroundTransport(api:api)
  let engine=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await engine.setNetwork(NetworkSnapshot())
  let running=Task{try await engine.run(item.id)};defer{running.cancel()}
  for _ in 0..<200{if await transport.started{break};try await Task.sleep(for:.milliseconds(10))}
  let started=await transport.started;XCTAssertTrue(started)
  try await engine.setNetwork(NetworkSnapshot(connected:true,cellular:true,wifi:false))
  _=try? await running.value
  let cancelled=await transport.cancelled,current=try await q.read(item.id)
  XCTAssertTrue(cancelled);XCTAssertEqual(current?.state,.paused);XCTAssertEqual(current?.lastErrorCode,"NETWORK_POLICY")
 }
 func testStartupPreservesBackgroundTransferAndDoesNotUploadAgain()async throws{
  let(q,e,_,t,item,files,_)=try await fixture(bytes:10)
  let retained=files.directory.appendingPathComponent(item.id.uuidString+".bin");try Data([1,2,3]).write(to:retained)
  await t.background(item.id);try await e.reconcileStartup();try await e.runDue()
  let cancelled=await t.cancelledIDs,numbers=await t.numbers,state=try await q.read(item.id)?.state
  XCTAssertTrue(cancelled.isEmpty);XCTAssertTrue(numbers.isEmpty);XCTAssertEqual(state,.queued);XCTAssertTrue(FileManager.default.fileExists(atPath:retained.path))
 }
 func testStartupCancelsUnknownBackgroundTransfer()async throws{
  let(_,e,_,t,_,_,_)=try await fixture(bytes:10);let unknown=UUID();await t.background(unknown);try await e.reconcileStartup();let cancelled=await t.cancelledIDs;XCTAssertTrue(cancelled.contains(unknown))
 }
 func testStartupHonorsPausedBackgroundTransfer()async throws{
  let(q,e,_,t,item,_,_)=try await fixture(bytes:10);var paused=item;paused.state = .paused;_=try await q.save(paused);await t.background(item.id);try await e.reconcileStartup();let cancelled=await t.cancelledIDs,state=try await q.read(item.id)?.state;XCTAssertTrue(cancelled.contains(item.id));XCTAssertEqual(state,.paused)
 }
 func testQueueSurvivesReopenAndSimulatedDeviceRestart() async throws {
  let d=try directory(),url=d.appendingPathComponent("queue.sqlite"),item=BackupItem(libraryID:UUID(),localAssetIdentifier:"mock",mediaType:"test")
  var q:SQLiteBackupQueue?=try SQLiteBackupQueue(url:url);_=try await q!.enqueue(item);q=nil
  let restarted=try SQLiteBackupQueue(url:url);let result=try await restarted.read(item.id);XCTAssertEqual(result?.state,.queued)
 }
 func testRecentTransfersIncludeNewestAcross100RowBoundaryAndPageWithoutDuplicates()async throws{
  let q=try SQLiteBackupQueue(url:directory().appendingPathComponent("recent.sqlite")),library=UUID();var newest:UUID?
  for i in 0..<105{let id=UUID(uuidString:String(format:"%08X-0000-4000-8000-000000000000",i))!;let item=BackupItem(libraryID:library,localAssetIdentifier:"fixture-\(i)",mediaType:"test",id:id);_=try await q.enqueue(item);newest=id}
  let first=try await q.recent(limit:100);XCTAssertEqual(first.count,100);XCTAssertEqual(first.first?.id,newest)
  let second=try await q.recent(before:first.last,limit:100);XCTAssertEqual(second.count,5);XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with:Set(second.map(\.id))))
  let internalPage=try await q.page(limit:100);XCTAssertNotEqual(internalPage.first?.id,newest)
 }
 func testDuplicateIdentityIsScopedToLibrary() async throws {
  let q=try SQLiteBackupQueue(url:directory().appendingPathComponent("queue.sqlite")),lib=UUID()
  let a=try await q.enqueue(BackupItem(libraryID:lib,localAssetIdentifier:"same",mediaType:"test"))
  let b=try await q.enqueue(BackupItem(libraryID:lib,localAssetIdentifier:"same",mediaType:"test"))
  let c=try await q.enqueue(BackupItem(libraryID:UUID(),localAssetIdentifier:"same",mediaType:"test"))
  XCTAssertEqual(a,b);XCTAssertNotEqual(a,c)
 }
 func testProtectionCannotBeSavedAsClientState() async throws {
  let(q,_,_,_,item,_,_)=try await fixture(bytes:10);var forged=item;forged.state = .protected
  do{_=try await q.save(forged);XCTFail()}catch{XCTAssertEqual(error as? BackupFailure,.illegalTransition)}
 }
 func testWrongAssetProofCannotProtect() async throws {
  let(q,_,_,_,item,_,_)=try await fixture(bytes:10);var forged=item;forged.state = .protected;forged.assetID=UUID();forged.expectedSizeBytes=10
  do{_=try await q.protect(forged,proof:asset(UUID(),status:"PROTECTED",size:10));XCTFail()}catch{XCTAssertEqual(error as? BackupFailure,.illegalTransition)}
 }
 func testStaleCallbacksRejected() async throws {
  let(q,_,_,_,item,_,_)=try await fixture(bytes:10);var paused=item;paused.state = .paused;_=try await q.save(paused)
  do{_=try await q.save(item);XCTFail()}catch{XCTAssertEqual(error as? BackupFailure,.staleWrite)}
 }
 func testSmallFileThroughMultipartAndServerVerification() async throws {
  let(q,e,_,t,item,files,_)=try await fixture(bytes:100);try await e.run(item.id)
  let result=try await q.read(item.id);XCTAssertEqual(result?.state,.protected);let numbers=await t.numbers;XCTAssertEqual(numbers,[1]);XCTAssertFalse(FileManager.default.fileExists(atPath:files.url(item.id).path))
 }
 func testGenerated20MiBMultipart() async throws {
  let(q,e,_,t,item,_,_)=try await fixture(bytes:20*1024*1024);let start=Date();try await e.run(item.id)
  let result=try await q.read(item.id);let parts=await t.numbers;XCTAssertEqual(result?.state,.protected);XCTAssertEqual(parts,[1,2,3,4]);print("Generated 20 MiB mock-engine elapsed seconds: \(Date().timeIntervalSince(start))")
 }
 func testPartRetryResumesAfterRestart() async throws {
  let(q,e,api,t,item,files,d)=try await fixture();await t.configure(fail:2)
  do{try await e.run(item.id);XCTFail()}catch{}
  let partial=try await q.read(item.id);XCTAssertEqual(partial?.state,.failedRetryable)
  let reopened=try SQLiteBackupQueue(url:d.appendingPathComponent("queue.sqlite"))
  let next=BackupCoordinator(queue:reopened,api:api,transport:t,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await next.setNetwork(NetworkSnapshot());try await next.reconcileStartup();try await next.retryFailed(item.id);try await next.run(item.id)
  let result=try await reopened.read(item.id);let parts=await t.numbers;XCTAssertEqual(result?.state,.protected);XCTAssertEqual(parts,[1,2,2,3])
 }
 func testCrashBeforeLocalPartCommitReconcilesStorage() async throws {
  let(q,e,_,t,item,_,_)=try await fixture();await t.configure(fail:2,lose:true)
  do{try await e.run(item.id)}catch{}
  let committed=try await q.parts(item.id);XCTAssertEqual(committed.map(\.partNumber),[1])
  try await e.retryFailed(item.id);try await e.run(item.id);let parts=await t.numbers;XCTAssertEqual(parts,[1,2,3]);let final=try await q.read(item.id);XCTAssertEqual(final?.state,.protected)
 }
 func testExpiredAuthorizationRefreshesOnRetry() async throws {
  let(q,e,api,t,item,_,_)=try await fixture(bytes:100);await t.configure(fail:1,expired:true)
  do{try await e.run(item.id)}catch{};try await e.retryFailed(item.id);try await e.run(item.id)
  let count=await api.authorizations;XCTAssertEqual(count,2);let result=try await q.read(item.id);XCTAssertEqual(result?.state,.protected)
 }
 func testVerificationOutageRetainsUploadedObjectAndRetries() async throws {
  let(q,e,api,t,item,_,_)=try await fixture(bytes:100);await api.failVerification(true)
  do{try await e.run(item.id)}catch{};await api.failVerification(false);try await e.retryFailed(item.id);try await e.run(item.id)
  let parts=await t.numbers;XCTAssertEqual(parts,[1]);let result=try await q.read(item.id);XCTAssertEqual(result?.state,.protected)
 }
 func testStaleQueueAlreadyProtectedNeverTransfers() async throws {
  let(q,e,api,t,item,_,_)=try await fixture(bytes:100);var r=item;r.assetID=api.assetID;r.sessionID=api.id;r.expectedSizeBytes=100;_=try await q.save(r);await api.forceProtected(size:100)
  try await e.reconcileStartup();try await e.run(item.id);let parts=await t.numbers;XCTAssertTrue(parts.isEmpty);let result=try await q.read(item.id);XCTAssertEqual(result?.state,.protected)
 }
 func testCancelledBackupCanStartFreshWithoutLosingHistoryOrDeduplication()async throws{
  let(q,e,api,_,item,files,d)=try await fixture(bytes:100)
  var started=item;started.sessionID=api.id;started.assetID=api.assetID;started.expectedSizeBytes=100;started.expectedChecksum=String(repeating:"a",count:64);started.bytesUploaded=50;_=try await q.save(started)
  try await e.cancel(item.id);let freshID=try await e.restartCancelled(item.id)
  let freshRecord=try await q.read(freshID),oldRecord=try await q.read(item.id)
  let fresh=try XCTUnwrap(freshRecord),old=try XCTUnwrap(oldRecord)
  XCTAssertNotEqual(freshID,item.id);XCTAssertNotEqual(fresh.uploadKey,item.uploadKey)
  XCTAssertEqual(old.state,.cancelled);XCTAssertEqual(old.sessionID,api.id);XCTAssertFalse(old.cancellationPending)
  XCTAssertEqual(fresh.state,.queued);XCTAssertNil(fresh.sessionID);XCTAssertNil(fresh.assetID);XCTAssertNil(fresh.expectedChecksum);XCTAssertNil(fresh.originalManifest);XCTAssertEqual(fresh.bytesUploaded,0)
  let latest=try await q.find(library:item.libraryID,localID:item.localAssetIdentifier);XCTAssertEqual(latest?.id,freshID)
  let repeated=try await e.restartCancelled(item.id);XCTAssertEqual(repeated,freshID)
  let duplicate=try await q.enqueue(BackupItem(libraryID:item.libraryID,localAssetIdentifier:item.localAssetIdentifier,mediaType:"test"));XCTAssertEqual(duplicate,freshID)
  let nextAPI=TestAPI(),nextTransport=TestTransport(api:nextAPI),next=BackupCoordinator(queue:q,api:nextAPI,transport:nextTransport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await next.setNetwork(NetworkSnapshot());try await next.run(freshID)
  let verified=try await q.read(freshID),history=try await q.recent();XCTAssertEqual(verified?.state,.protected);XCTAssertNotEqual(verified?.sessionID,old.sessionID);XCTAssertEqual(history.count,2)
  XCTAssertTrue(FileManager.default.fileExists(atPath:d.appendingPathComponent("source").appendingPathComponent(item.localAssetIdentifier+".bin").path))
 }
 func testRestartFromOlderCancelledHistoryFindsLatestCancelledAttempt()async throws{
  let(q,e,_,_,item,_,_)=try await fixture(bytes:100)
  try await e.cancel(item.id);let second=try await e.restartCancelled(item.id)
  try await e.cancel(second);let third=try await e.restartCancelled(item.id)
  XCTAssertNotEqual(third,item.id);XCTAssertNotEqual(third,second)
  let latest=try await q.find(library:item.libraryID,localID:item.localAssetIdentifier),history=try await q.recent()
  XCTAssertEqual(latest?.id,third);XCTAssertEqual(latest?.state,.queued);XCTAssertEqual(history.filter{$0.state == .cancelled}.count,2);XCTAssertEqual(history.count,3)
 }
 func testRestartWaitsForRemoteCancellationAcknowledgement()async throws{
  let(q,e,api,_,item,_,_)=try await fixture(bytes:100)
  var started=item;started.sessionID=api.id;started.assetID=api.assetID;_=try await q.save(started)
  await api.failCancellation(true);do{try await e.cancel(item.id);XCTFail("Cancellation should be pending")}catch{}
  do{_=try await e.restartCancelled(item.id);XCTFail("Cannot create another attempt before cancellation acknowledgement")}catch{}
  let pending=try await q.read(item.id),history=try await q.recent();XCTAssertEqual(pending?.state,.cancelled);XCTAssertTrue(pending?.cancellationPending == true);XCTAssertEqual(history.count,1)
  await api.failCancellation(false);let fresh=try await e.restartCancelled(item.id);XCTAssertNotEqual(fresh,item.id)
 }
 func testRestartReconcilesProtectionThatWonCancellationRace()async throws{
  let(q,e,api,_,item,_,_)=try await fixture(bytes:100)
  var started=item;started.sessionID=api.id;started.assetID=api.assetID;started.expectedSizeBytes=100;_=try await q.save(started)
  try await e.cancel(item.id);await api.forceProtected(size:100)
  let result=try await e.restartCancelled(item.id),protected=try await q.read(item.id),history=try await q.recent()
  XCTAssertEqual(result,item.id);XCTAssertEqual(protected?.state,.protected);XCTAssertEqual(history.count,1)
  do{_=try await q.enqueueAgain(afterCancelled:item.id);XCTFail("Protected history must not be replaced")}catch{}
 }
 func testRestartArchiveCollisionRollsBackWithoutLosingCancelledLookup()async throws{
  let(q,e,_,_,item,_,_)=try await fixture(bytes:100);try await e.cancel(item.id);_=try await e.settleCancellation(item.id)
  _=try await q.enqueue(BackupItem(libraryID:item.libraryID,localAssetIdentifier:"cancelled-attempt:"+item.id.uuidString,mediaType:"test"))
  do{_=try await q.enqueueAgain(afterCancelled:item.id);XCTFail("Expected uniqueness collision")}catch{}
  let found=try await q.find(library:item.libraryID,localID:item.localAssetIdentifier),history=try await q.recent();XCTAssertEqual(found?.id,item.id);XCTAssertEqual(found?.state,.cancelled);XCTAssertEqual(history.count,2)
 }
 func testCancelNeverDeletesGeneratedSource() async throws {
  let(q,e,_,_,item,_,d)=try await fixture(bytes:100);try await e.cancel(item.id);try await e.run(item.id)
  let result=try await q.read(item.id);XCTAssertEqual(result?.state,.cancelled);XCTAssertTrue(FileManager.default.fileExists(atPath:d.appendingPathComponent("source").appendingPathComponent(item.localAssetIdentifier+".bin").path))
 }
 func testPauseAndResumeAll() async throws {
  let(q,e,_,_,item,_,_)=try await fixture(bytes:100);try await e.pauseAll();let paused=try await q.read(item.id);XCTAssertEqual(paused?.state,.paused)
  try await e.resumeAll();let queued=try await q.read(item.id);XCTAssertEqual(queued?.state,.queued);try await e.run(item.id);let done=try await q.read(item.id);XCTAssertEqual(done?.state,.protected)
 }
 func testRetryJitterAndBackoffBounds() {
  let r=RetryPolicy();for attempt in 1...30{let lo=r.delay(attempt:attempt,random:0),hi=r.delay(attempt:attempt,random:1);XCTAssertEqual(hi,lo*2);XCTAssertLessThanOrEqual(hi,3600);XCTAssertGreaterThan(lo,0)}
  XCTAssertGreaterThan(r.delay(attempt:3,random:1),r.delay(attempt:2,random:1))
 }
 func testRetryClassification() {
  let r=RetryPolicy();for status in [408,429,500,503]{XCTAssertTrue(r.retryable(BackupFailure.http(status)))}
  for status in [400,401,403,404,409,410]{XCTAssertFalse(r.retryable(BackupFailure.http(status)))}
  XCTAssertTrue(r.retryable(BackupFailure.authorization));XCTAssertFalse(r.retryable(BackupFailure.sourceChanged));XCTAssertTrue(r.retryable(URLError(.timedOut)))
 }
 func testNetworkPolicyUnknownSizeCellularAndConstrained() {
  var p=BackupPolicy(),item=BackupItem(libraryID:UUID(),localAssetIdentifier:"mock",mediaType:"video")
  let cell=NetworkSnapshot(cellular:true,wifi:false);XCTAssertFalse(p.permits(item,network:cell));p.wifiOnly=false;p.allowCellular=true
  XCTAssertFalse(p.permits(item,network:cell));item.expectedSizeBytes=8*1024*1024;XCTAssertFalse(p.permits(item,network:cell));p.allowLargeVideosOnCellular=true;XCTAssertTrue(p.permits(item,network:cell))
  item.expectedSizeBytes=11*1024*1024;XCTAssertFalse(p.permits(item,network:cell));XCTAssertFalse(p.permits(item,network:NetworkSnapshot(constrained:true)))
 }
 func testNetworkChangePausesBeforeTransfer() async throws {
  let(q,e,_,t,item,_,_)=try await fixture(bytes:100);try await e.setNetwork(NetworkSnapshot(cellular:true,wifi:false));try await e.run(item.id)
  let result=try await q.read(item.id);let parts=await t.numbers;XCTAssertEqual(result?.state,.paused);XCTAssertTrue(parts.isEmpty)
 }
 func testNetworkPauseAutomaticallyResumesOnPermittedConnection()async throws{
  let(q,e,_,t,item,_,_)=try await fixture(bytes:100)
  try await e.setNetwork(NetworkSnapshot(connected:false));try await e.runDue()
  var current=try await q.read(item.id);XCTAssertEqual(current?.lastErrorCode,"NETWORK_POLICY")
  try await e.runDue();current=try await q.read(item.id);XCTAssertEqual(current?.state,.paused)
  try await e.setNetwork(NetworkSnapshot(cellular:true,wifi:false));try await e.runDue()
  current=try await q.read(item.id);XCTAssertEqual(current?.state,.paused)
  try await e.setNetwork(NetworkSnapshot(constrained:true));try await e.runDue()
  current=try await q.read(item.id);XCTAssertEqual(current?.state,.paused)
  try await e.setNetwork(NetworkSnapshot());try await e.runDue()
  current=try await q.read(item.id);let parts=await t.numbers
  XCTAssertEqual(current?.state,.protected);XCTAssertEqual(parts,[1])
 }
 func testAutomaticNetworkRecoveryRetainsAcceptedMultipartParts()async throws{
  let(q,e,_,t,item,_,_)=try await fixture()
  await t.configure(fail:2)
  do{try await e.run(item.id);XCTFail("Expected interrupted transfer")}catch{}
  try await e.pause(item.id,reason:"NETWORK_POLICY")
  try await e.setNetwork(NetworkSnapshot());try await e.runDue()
  let current=try await q.read(item.id),parts=await t.numbers
  XCTAssertEqual(current?.state,.protected);XCTAssertEqual(parts,[1,2,2,3])
 }
 func testNetworkRecoveryPreservesManualAndResourcePauses()async throws{
  for reason in ["USER_PAUSED","WAITING_FOR_ICLOUD_ORIGINAL","LOCAL_ACCESS_UNAVAILABLE"]{
   let(q,e,_,t,item,_,_)=try await fixture(bytes:100)
   try await e.pause(item.id,reason:reason);try await e.setNetwork(NetworkSnapshot());try await e.runDue()
   let current=try await q.read(item.id),parts=await t.numbers
   XCTAssertEqual(current?.state,.paused);XCTAssertEqual(current?.lastErrorCode,reason);XCTAssertTrue(parts.isEmpty)
  }
 }
 func testManualPauseOverridesAutomaticNetworkRecovery()async throws{
  let(q,e,_,_,item,_,_)=try await fixture(bytes:100)
  try await e.pause(item.id,reason:"NETWORK_POLICY");try await e.pause(item.id)
  try await e.setNetwork(NetworkSnapshot());try await e.runDue()
  let current=try await q.read(item.id);XCTAssertEqual(current?.lastErrorCode,"USER_PAUSED");XCTAssertEqual(current?.state,.paused)
 }
 func testNetworkRecoveryWaitsForDaemonTransferToDrain()async throws{
  let(q,e,_,t,item,_,_)=try await fixture(bytes:100)
  try await e.pause(item.id,reason:"NETWORK_POLICY");await t.background(item.id)
  try await e.runDue();let paused=try await q.read(item.id);XCTAssertEqual(paused?.state,.paused)
  await t.cancel(item:item.id);try await e.runDue()
  let current=try await q.read(item.id);XCTAssertEqual(current?.state,.protected)
 }
 func testNetworkPauseRecoversAfterCoordinatorRestart()async throws{
  let(q,e,api,t,item,files,d)=try await fixture(bytes:100)
  try await e.pause(item.id,reason:"NETWORK_POLICY")
  let restarted=BackupCoordinator(queue:q,api:api,transport:t,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files)
  try await restarted.setNetwork(NetworkSnapshot());try await restarted.reconcileStartup();try await restarted.runDue()
  let current=try await q.read(item.id);XCTAssertEqual(current?.state,.protected)
 }
 func testICloudWaitAndDeniedAccessPauseWithoutDestruction() async throws {
  for denied in [false,true]{let(q,_,api,t,item,files,_)=try await fixture(bytes:100)
   let e=BackupCoordinator(queue:q,api:api,transport:t,preparer:WaitingPreparer(denied:denied),files:files);try await e.setNetwork(NetworkSnapshot());do{try await e.run(item.id)}catch{}
   let result=try await q.read(item.id);XCTAssertEqual(result?.state,.paused);let cancelled=await api.cancelled;XCTAssertFalse(cancelled)
  }
 }
 func testTempTraversalRejected() throws {
  let d=try directory(),files=try ManagedTemporaryFiles(directory:d.appendingPathComponent("temp"));let outside=d.appendingPathComponent("keep.bin");try Data([1]).write(to:outside)
  XCTAssertThrowsError(try files.remove(outside));XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
 }
 func testStreamingHashAndPartBoundaries() throws {
  let d=try directory(),url=d.appendingPathComponent("mock.bin");try Data(repeating:7,count:6*1024*1024+1).write(to:url)
  let resource=try StreamingIntegrity.inspect(url),files=try ManagedTemporaryFiles(directory:d.appendingPathComponent("parts")),id=UUID()
  let a=try files.part(resource,id:id,number:1,size:5*1024*1024),b=try files.part(resource,id:id,number:2,size:5*1024*1024)
  XCTAssertEqual(a.sizeBytes,5*1024*1024);XCTAssertEqual(b.sizeBytes,1024*1024+1);XCTAssertEqual(resource.checksum.count,64)
 }
 func testQueueRecordsContainNoAuthorizationOrCredentials() async throws {
  let(q,e,_,_,item,_,d)=try await fixture(bytes:100);try await e.run(item.id);let r=try await q.read(item.id)!
  let text=String(data:try JSONEncoder().encode(r),encoding:.utf8)!;for key in ["https://","X-Amz","Bearer","secret","authorization"]{XCTAssertFalse(text.contains(key))}
  let values=try d.resourceValues(forKeys:[.isDirectoryKey]);XCTAssertTrue(values.isDirectory == true)
 }
 func testQueueScale1000_10000_100000() async throws {
  let q=try SQLiteBackupQueue(url:directory().appendingPathComponent("queue.sqlite")),library=UUID();let start=Date()
  for i in 0..<100000{_=try await q.enqueue(BackupItem(libraryID:library,localAssetIdentifier:"generated-\(i)",mediaType:"test"))
   if [999,9999,99999].contains(i){let elapsed=Date().timeIntervalSince(start);let page=try await q.page(limit:100);XCTAssertEqual(page.count,100);let found=try await q.find(library:library,localID:"generated-\(i)");XCTAssertNotNil(found);print("Queue records \(i+1), cumulative seconds \(elapsed)")}
  }
  let summary=try await q.summary();XCTAssertEqual(summary[.queued],100000)
 }
 func testPermanentErrorDoesNotRapidRetryAndRetryLimitStops() async throws {
  let(q,_,api,t,item,files,d)=try await fixture(bytes:100)
  let e=BackupCoordinator(queue:q,api:api,transport:t,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files,retry:RetryPolicy(maximumAttempts:2));try await e.setNetwork(NetworkSnapshot())
  await t.configure(fail:1);do{try await e.run(item.id)}catch{}
  let first=try await q.read(item.id)!;XCTAssertEqual(first.state,.failedRetryable);XCTAssertNotNil(first.nextRetryAt)
  try await e.run(item.id);let calls=await t.numbers;XCTAssertEqual(calls,[1])
  var due=first;due.nextRetryAt=Date(timeIntervalSince1970:0);_=try await q.save(due);await t.configure(fail:1);do{try await e.run(item.id)}catch{}
  let permanent=try await q.read(item.id);XCTAssertEqual(permanent?.state,.failedPermanent);try await e.run(item.id);let final=await t.numbers;XCTAssertEqual(final,[1,1])
 }
 func testUploadedUnverifiedStartupNeedsNoLocalOriginal() async throws {
  let(q,e,api,t,item,_,d)=try await fixture(bytes:100);await api.failVerification(true);do{try await e.run(item.id)}catch{}
  try FileManager.default.removeItem(at:d.appendingPathComponent("source").appendingPathComponent(item.localAssetIdentifier+".bin"))
  await api.failVerification(false);try await e.reconcileStartup();try await e.retryFailed(item.id);try await e.run(item.id)
  let result=try await q.read(item.id);let transfers=await t.numbers;XCTAssertEqual(result?.state,.protected);XCTAssertEqual(transfers,[1])
 }
 func testOrphanTempCleanupOnlyManagedOpaqueFiles() async throws {
  let(_,e,_,_,_,files,_)=try await fixture(bytes:100)
  let orphan=files.url(UUID()),unrecognized=files.directory.appendingPathComponent("keep.txt");try Data([1]).write(to:orphan);try Data([1]).write(to:unrecognized)
  try await e.reconcileStartup();XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path));XCTAssertTrue(FileManager.default.fileExists(atPath:unrecognized.path))
 }
 func testPartRecordReplacementIsIdempotentAndCrashSafe() async throws {
  let(q,_,_,_,item,_,_)=try await fixture(bytes:100),parts=[CompletedPart(partNumber:1,sizeBytes:100)]
  try await q.replaceParts(item.id,parts:parts);try await q.replaceParts(item.id,parts:parts);let actual=try await q.parts(item.id);XCTAssertEqual(actual,parts)
  do{try await q.replaceParts(item.id,parts:parts+parts);XCTFail()}catch{};let after=try await q.parts(item.id);XCTAssertEqual(after,parts)
 }
 #if os(macOS)
 func testQueuePersistenceAcrossActualProcesses() async throws {
  if let path=ProcessInfo.processInfo.environment["BACKUP_QUEUE_PROCESS_FIXTURE"],let stage=ProcessInfo.processInfo.environment["BACKUP_QUEUE_PROCESS_STAGE"] {
   let q=try SQLiteBackupQueue(url:URL(fileURLWithPath:path))
   if stage == "write" {
    let item=BackupItem(libraryID:UUID(),localAssetIdentifier:"generated-process-metadata",mediaType:"test")
    _=try await q.enqueue(item);var next=item;next.state = .paused;next.sessionID=UUID();next.expectedSizeBytes=100;_=try await q.save(next)
    try await q.replaceParts(item.id,parts:[CompletedPart(partNumber:1,sizeBytes:100)])
   } else {
    let page=try await q.page();XCTAssertEqual(page.count,1);XCTAssertEqual(page.first?.state,.paused);XCTAssertNotNil(page.first?.sessionID)
    let parts=try await q.parts(page[0].id);XCTAssertEqual(parts,[CompletedPart(partNumber:1,sizeBytes:100)])
   }
   return
  }
  let d=try directory(),path=d.appendingPathComponent("queue.sqlite").path
  for stage in ["write","read"] {
   let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);if CommandLine.arguments[0].hasSuffix("/xctest") {p.arguments=["-XCTest","BackupEngineTests.BackupEngineTests/testQueuePersistenceAcrossActualProcesses",Bundle(for:BackupEngineTests.self).bundlePath]}else{p.arguments=["BackupEngineTests.BackupEngineTests/testQueuePersistenceAcrossActualProcesses"]}
   var env=ProcessInfo.processInfo.environment;env["BACKUP_QUEUE_PROCESS_FIXTURE"]=path;env["BACKUP_QUEUE_PROCESS_STAGE"]=stage;p.environment=env
   let output=Pipe();p.standardOutput=output;p.standardError=output;try p.run();let data=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
   XCTAssertEqual(p.terminationStatus,0,"Generated child queue process failed (\(data.count) captured diagnostic bytes).")
  }
 }
 #endif

 func testIntentionalRemovalPreservesProtectionAndPreventsReupload() async throws {
  let(q,e,_,_,item,_,_)=try await fixture(bytes:5);try await e.run(item.id)
  let protected=try await q.read(item.id)!
  try await q.recordLocalRemoval(item.id,assetID:protected.assetID!,size:5,checksum:protected.expectedChecksum!)
  let removed=try await q.read(item.id);XCTAssertEqual(removed?.state,.protected);XCTAssertEqual(removed?.localRemovedAfterProtection,true)
  let due=try await q.due();XCTAssertFalse(due.contains{$0.id==item.id})
  let store=try SQLiteDiscoveredAssetStore(url:nil),checkpoint=try await store.begin(snapshotKey:"generated",total:1,authorization:.authorized)
  let next=try await store.writeBatch([AssetMetadata(localAssetID:item.localAssetIdentifier,mediaType:.image)],checkpoint:checkpoint,nextOffset:1);try await store.finish(next);try await store.invalidateVisibility()
  let asset=try await store.asset(localID:item.localAssetIdentifier)!,decision=try await BackupPlanner(queue:q).decision(asset,library:item.libraryID,policy:BackupPolicy(),network:NetworkSnapshot());XCTAssertEqual(decision,.intentionallyRemoved)
  try await q.recordLocalRemoval(item.id,assetID:protected.assetID!,size:5,checksum:protected.expectedChecksum!,removed:false)
  let restored=try await q.read(item.id);XCTAssertEqual(restored?.localRemovedAfterProtection,false);XCTAssertEqual(restored?.state,.protected)
 }
 func testUnprotectedItemCannotAcquireRemovalMarker() async throws {
  let(q,_,_,_,item,_,_)=try await fixture(bytes:5)
  do{try await q.recordLocalRemoval(item.id,assetID:UUID(),size:5,checksum:String(repeating:"a",count:64));XCTFail()}catch{}
 }
 func testOrdinaryQueueWriteCannotFabricateRemovalMarker() async throws {
  let(q,_,_,_,item,_,_)=try await fixture(bytes:5);var forged=try await q.read(item.id)!;forged.localRemovedAfterProtection=true
  do{_=try await q.save(forged);XCTFail()}catch{}
 }

 func testPlannerUsesDiscoveryAndRequiresExplicitDevelopmentEnablement() async throws {
  let store=try SQLiteDiscoveredAssetStore(url:nil),local="generated-planner-metadata",lib=UUID()
  let checkpoint=try await store.begin(snapshotKey:"mock",total:1,authorization:.authorized)
  let next=try await store.writeBatch([AssetMetadata(localAssetID:local,mediaType:.image)],checkpoint:checkpoint,nextOffset:1);try await store.finish(next)
  let asset=try await store.asset(localID:local)!,q=try SQLiteBackupQueue(url:directory().appendingPathComponent("queue.sqlite")),planner=BackupPlanner(queue:q)
  let initial=try await planner.decision(asset,library:lib,policy:BackupPolicy(),network:NetworkSnapshot());XCTAssertEqual(initial,.needsBackup)
  do{_=try await planner.enqueueExplicit(asset,library:lib,developmentEnabled:false);XCTFail()}catch{}
  let id=try await planner.enqueueExplicit(asset,library:lib,developmentEnabled:true)
  let queued=try await planner.decision(asset,library:lib,policy:BackupPolicy(),network:NetworkSnapshot());XCTAssertEqual(queued,.alreadyQueued)
  var waiting=try await q.read(id)!;waiting.state = .paused;waiting.lastErrorCode="WAITING_FOR_ICLOUD_ORIGINAL";_=try await q.save(waiting)
  let decision=try await planner.decision(asset,library:lib,policy:BackupPolicy(),network:NetworkSnapshot());XCTAssertEqual(decision,.waitingForResource)
  try await store.invalidateVisibility();let removed=try await store.asset(localID:local)!
  let inaccessible=try await planner.decision(removed,library:UUID(),policy:BackupPolicy(),network:NetworkSnapshot());XCTAssertEqual(inaccessible,.inaccessible)
  let retained=try await q.read(id);XCTAssertNotNil(retained) // Losing local access never cancels/deletes backup work.
 }

 func testPartAuthorizationTreatsHostnameCaseInsensitively() throws {
  let d=try directory(),url=d.appendingPathComponent("generated.bin");try Data("hello".utf8).write(to:url)
  let resource=try StreamingIntegrity.inspect(url),transport=try PartURLSessionTransport(origin:URL(string:"http://Moronkes-MacBook-Pro.local:9000")!,allowLocalHTTP:true)
  for (host,port,allowed) in [("moronkes-macbook-pro.local",9000,true),("other.local",9000,false),("moronkes-macbook-pro.local",9001,false)] {
   let a=try JSONDecoder().decode(UploadAuthorization.self,from:JSONSerialization.data(withJSONObject:["method":"PUT","url":"http://\(host):\(port)/generated","headers":["content-length":"5"],"expiresAt":"2099-01-01T00:00:00.000Z"]))
   if allowed {XCTAssertNoThrow(try transport.validateAuthorization(resource:resource,authorization:a))}
   else {XCTAssertThrowsError(try transport.validateAuthorization(resource:resource,authorization:a))}
  }
 }

 func testProviderAgnosticPartHeadersWithoutNativeChecksumRemainValid() throws {
  let d=try directory(),url=d.appendingPathComponent("generated.bin");try Data("hello".utf8).write(to:url)
  let resource=try StreamingIntegrity.inspect(url),transport=try PartURLSessionTransport(origin:URL(string:"https://storage.example.invalid")!)
  let a=try JSONDecoder().decode(UploadAuthorization.self,from:JSONSerialization.data(withJSONObject:["method":"PUT","url":"https://storage.example.invalid/generated","headers":["content-length":"5"],"expiresAt":"2099-01-01T00:00:00.000Z"]))
  XCTAssertNoThrow(try transport.validateAuthorization(resource:resource,authorization:a))
 }

 func testPartTransportRejectsUnsafeAuthorizationBeforeNetworkingAndShutsDown() async throws {
  let d=try directory(),url=d.appendingPathComponent("generated.bin");try Data("hello".utf8).write(to:url)
  let resource=try StreamingIntegrity.inspect(url),transport=try PartURLSessionTransport(origin:URL(string:"https://storage.example.invalid")!)
  let headers=["content-length":"5","x-amz-checksum-sha256":Data(SHA256.hash(data:Data("hello".utf8))).base64EncodedString()]
  for variation in 0..<6 {
   var h=headers;var origin="https://storage.example.invalid/object";var expiry="2099-01-01T00:00:00.000Z";var method="PUT"
   switch variation{case 0:origin="https://other.example.invalid/object";case 1:expiry="2000-01-01T00:00:00.000Z";case 2:h["Authorization"]="fixture";case 3:h["content-length"]="6";case 4:h["x-amz-checksum-sha256"]="invalid";default:method="GET"}
   let auth=try JSONDecoder().decode(UploadAuthorization.self,from:JSONSerialization.data(withJSONObject:["method":method,"url":origin,"headers":h,"expiresAt":expiry]))
   do{try await transport.upload(item:UUID(),number:1,resource:resource,authorization:auth,policy:BackupPolicy());XCTFail()}catch{XCTAssertEqual(error as? BackupFailure,.authorization)}
  }
  await transport.shutdown()
 }

 func testPauseActiveTransferAndResumeKeepsPartsSafe() async throws {
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=BlockingTransport()
  let e=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files);try await e.setNetwork(NetworkSnapshot())
  let task=Task{try await e.run(item.id)};while !(await transport.started){try await Task.sleep(for:.milliseconds(1))}
  try await e.pause(item.id);try await task.value;let paused=try await q.read(item.id);XCTAssertEqual(paused?.state,.paused)
  try await e.resume(item.id);let resumed=try await q.read(item.id);XCTAssertEqual(resumed?.state,.queued)
 }
 func testNetworkChangeCancelsActiveTransferSafely() async throws {
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=BlockingTransport()
  let e=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files);try await e.setNetwork(NetworkSnapshot())
  let task=Task{try await e.run(item.id)};while !(await transport.started){try await Task.sleep(for:.milliseconds(1))}
  try await e.setNetwork(NetworkSnapshot(cellular:true,wifi:false));try await task.value;let paused=try await q.read(item.id);XCTAssertEqual(paused?.state,.paused);XCTAssertEqual(paused?.lastErrorCode,"NETWORK_POLICY")
 }
 func testCancellationOfActiveTransferIsDurableAndServerNotified() async throws {
  let(q,_,api,_,item,files,d)=try await fixture(bytes:100),transport=BlockingTransport()
  let e=BackupCoordinator(queue:q,api:api,transport:transport,preparer:GeneratedResourcePreparer(sourceDirectory:d.appendingPathComponent("source"),files:files),files:files);try await e.setNetwork(NetworkSnapshot())
  let task=Task{try await e.run(item.id)};while !(await transport.started){try await Task.sleep(for:.milliseconds(1))}
  try await e.cancel(item.id);try await task.value;let cancelled=try await q.read(item.id);XCTAssertEqual(cancelled?.state,.cancelled);XCTAssertEqual(cancelled?.cancellationPending,false);let remote=await api.cancelled;XCTAssertTrue(remote)
 }

}

private actor BlockingTransport:PartTransport {
 var started=false
 var continuation:CheckedContinuation<Void,Error>?
 func upload(item:UUID,number:Int,resource:PreparedResource,authorization:UploadAuthorization,policy:BackupPolicy) async throws {
  try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in continuation=c;started=true}
 }
 func cancel(item:UUID){let c=continuation;continuation=nil;c?.resume(throwing:CancellationError())}
}

final class DevelopmentOriginTests: XCTestCase {
 func testLocalHostnameRequiresDevelopmentOptIn() throws {
  let local=URL(string:"http://mac.local:9000")!
  XCTAssertNoThrow(try PartURLSessionTransport(origin:local,allowLocalHTTP:true))
  XCTAssertThrowsError(try PartURLSessionTransport(origin:local))
  XCTAssertThrowsError(try PartURLSessionTransport(origin:URL(string:"http://mac.local.attacker.invalid:9000")!,allowLocalHTTP:true))
  XCTAssertThrowsError(try PartURLSessionTransport(origin:URL(string:"http://user:password@mac.local:9000")!,allowLocalHTTP:true))
 }
}
