import XCTest
import Foundation
import MediaPreservation
@testable import BackupEngine
actor GeneratedMediaSource:MediaResourceSource{var value:MediaSourceSnapshot,networkRequired=false,changed=false,altered=false,calls:[Bool]=[];init(_ s:MediaSourceSnapshot){value=s};func snapshot(_ id:String)->MediaSourceSnapshot{if changed{return MediaSourceSnapshot(localID:id,mediaType:"image",modification:Date(timeIntervalSince1970:2),resources:value.resources)};return value};func stream(_ id:String,descriptor:ResourceDescriptor,to url:URL,allowNetwork:Bool,progress:@escaping @Sendable(Double)->Void)throws{calls.append(allowNetwork);if networkRequired && !allowNetwork{throw BackupFailure.waitingForOriginal};try Data(repeating:altered ? 0x66:0x65,count:100).write(to:url)};func requireNetwork(){networkRequired=true};func change(){changed=true};func alterBytes(){altered=true}}
final class MultiResourceTests:XCTestCase{
 func fixture()async throws->(MediaManifest,ManifestStore,GeneratedMediaSource,MultiResourcePreparer,BackupItem,URL){let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);addTeardownBlock{try? FileManager.default.removeItem(at:root)};let binding=ManifestBinding(accountID:UUID(),deviceID:UUID(),libraryID:UUID()),source=MediaSourceSnapshot(localID:"generated-private-local-id",mediaType:"image",modification:Date(timeIntervalSince1970:1),resources:[ResourceDescriptor(ordinal:0,resourceType:1,uti:"public.jpeg"),ResourceDescriptor(ordinal:1,resourceType:9,uti:"com.apple.quicktime-movie")]),manifest=MediaManifest(binding:binding,source:source),store=try ManifestStore(url:root.appendingPathComponent("manifest.sqlite")),fake=GeneratedMediaSource(source),files=try ManagedTemporaryFiles(directory:root.appendingPathComponent("files"));try await store.insert(manifest);var item=BackupItem(libraryID:binding.libraryID,localAssetIdentifier:manifest.resources[0].id.uuidString,mediaType:"image",id:manifest.resources[0].id);item.accountID=binding.accountID;item.deviceID=binding.deviceID;item.mediaResourceBinding=ManifestResourceBinding(manifest:manifest,resource:manifest.resources[0]);return(manifest,store,fake,MultiResourcePreparer(source:fake,store:store,files:files,binding:binding),item,root)}
 func testResourceCaptureDoesNotClaimComplete()async throws{let(m,s,_,p,i,_)=try await fixture();_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());let actual=try await s.read(m.id);XCTAssertEqual(actual?.state,.partial);XCTAssertEqual(actual?.resources[0].expectedSize,100);XCTAssertNil(actual?.resources[1].expectedSize)}
 func testChangedBytesWithSameMetadataInvalidatesManifest()async throws{let(m,s,f,p,i,_)=try await fixture();_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());await f.alterBytes();do{_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());XCTFail()}catch{};let actual=try await s.read(m.id);XCTAssertEqual(actual?.state,.sourceChanged);XCTAssertNotNil(actual?.changedFingerprint);do{_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());XCTFail()}catch{};let retried=try await s.read(m.id);XCTAssertEqual(actual?.changedFingerprint,retried?.changedFingerprint)}
 func testSourceChangeRejectsCapture()async throws{let(m,s,f,p,i,_)=try await fixture();await f.change();do{_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());XCTFail()}catch{};let actual=try await s.read(m.id);XCTAssertEqual(actual?.state,.sourceChanged)}
 func testICloudRequiredRetainsWaitingState()async throws{let(m,s,f,p,i,_)=try await fixture();await f.requireNetwork();do{_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());XCTFail()}catch{};let actual=try await s.read(m.id);XCTAssertEqual(actual?.resources[0].waitingForNetwork,true);let calls=await f.calls;XCTAssertEqual(calls,[false])}
 func testCrossAccountCaptureRejected()async throws{let(_,_,_,p,original,_)=try await fixture();var i=original;i.accountID=UUID();do{_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());XCTFail()}catch{}}
 func testPartialManifestSurvivesSQLiteRestart()async throws{let(m,_,_,p,i,root)=try await fixture();_=try await p.prepare(i,policy:BackupPolicy(),network:NetworkSnapshot());let reopened=try ManifestStore(url:root.appendingPathComponent("manifest.sqlite")),actual=try await reopened.read(m.id);XCTAssertEqual(actual?.resources[0].expectedSize,100);XCTAssertNil(actual?.resources[1].expectedSha256)}
 func testNewManifestAttemptWinsOverMatchingCancelledHistory()async throws{
  let(m,store,source,_,_,root)=try await fixture(),queue=try SQLiteBackupQueue(url:root.appendingPathComponent("queue.sqlite")),planner=MultiResourceBackupPlanner(store:store,queue:queue)
  _=try await planner.enqueue(m,binding:m.binding)
  var cancelledRecord=try await queue.read(m.resources[0].id);cancelledRecord?.state = .cancelled
  _=try await queue.save(try XCTUnwrap(cancelledRecord))
  let snapshot=await source.snapshot(m.source.localID)
  let fallback=try await planner.existing(source:snapshot,binding:m.binding);XCTAssertEqual(fallback?.id,m.id)
  let fresh=try await planner.captureExplicit(source:snapshot,binding:m.binding);_=try await planner.enqueue(fresh,binding:m.binding)
  let selected=try await planner.existing(source:snapshot,binding:m.binding),rows=try await queue.page()
  XCTAssertEqual(selected?.id,fresh.id);XCTAssertEqual(rows.count,4)
  let repeated=try await planner.existing(source:snapshot,binding:m.binding);XCTAssertEqual(repeated?.id,fresh.id)
  let old=try await queue.read(m.resources[0].id);XCTAssertEqual(old?.state,.cancelled)
 }
 func testReusableManifestSelectionCannotCrossAccountBinding()async throws{
  let(m,store,source,_,_,root)=try await fixture(),queue=try SQLiteBackupQueue(url:root.appendingPathComponent("queue.sqlite")),planner=MultiResourceBackupPlanner(store:store,queue:queue)
  let snapshot=await source.snapshot(m.source.localID),wrong=ManifestBinding(accountID:UUID(),deviceID:m.binding.deviceID,libraryID:m.binding.libraryID)
  let result=try await planner.existing(source:snapshot,binding:wrong);XCTAssertNil(result)
 }

}
