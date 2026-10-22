import XCTest
import Foundation
import CryptoKit
import MediaPreservation
@testable import RestoreEngine
actor CompoundFixtureAPI:CompoundRestoreAPI{let plan:CompoundRestorePlan;init(_ p:CompoundRestorePlan){plan=p};func compoundPlan(_ id:UUID,fingerprint:String,choice:ManifestRestoreChoice)->CompoundRestorePlan{plan};func compoundAuthorization(manifest:UUID,resource:CompoundPlanResource,fingerprint:String)->RestoreAuthorization{RestoreAuthorization(evidence:resource.evidence,authorization:RestoreCapability(url:URL(string:"https://storage.example.test/private")!,expiresAt:"2099-01-01T00:00:00.000Z"))};func authorize(_ e:RestoreEvidence)->RestoreAuthorization{RestoreAuthorization(evidence:e,authorization:RestoreCapability(url:URL(string:"https://storage.example.test/private")!,expiresAt:"2099-01-01T00:00:00.000Z"))};func recheck(_ e:RestoreEvidence)->RestoreEvidence{e}}
actor CompoundFixturePhotos:CompoundPhotoLibraryRestorer{var saves=0,resourceCount=0,allowed=true;func canSave()->Bool{allowed};func validate(_ r:[CompoundSaveResource]){};func save(_ r:[CompoundSaveResource])->String{saves+=1;resourceCount=r.count;return "generated-new-local-copy"};func presence(_ id:String)->LocalPresence{.exists};func deny(){allowed=false}}
private actor MeteredCompoundDownload:RestoreDownloader {
 var calls=0,active=0,maximum=0,failSecond=false
 func download(_ capability:RestoreCapability,to file:URL,expectedSize:Int,progress:@escaping @Sendable(Int)->Void)async throws {
  calls+=1;let number=calls;active+=1;maximum=max(maximum,active);defer{active-=1}
  try await Task.sleep(for:.milliseconds(30))
  if failSecond,number==2{throw URLError(.networkConnectionLost)}
  try Data(repeating:0x65,count:expectedSize).write(to:file)
 }
 func fail(){failSecond=true}
 func cancel()async{}
}
final class CompoundTests:XCTestCase{
 func json(roles:[String]=["PRIMARY_STILL","PAIRED_VIDEO"],choice:String="ALL",kind:String="LIVE_PHOTO")->[String:Any]{let sha=SHA256.hash(data:Data(repeating:0x65,count:100)).map{String(format:"%02x",$0)}.joined();let rs=roles.enumerated().map{i,role->[String:Any] in let asset=UUID().uuidString;return ["id":UUID().uuidString,"role":role,"resourceType":role=="PAIRED_VIDEO" ? 9:role=="ADJUSTMENT_DATA" ? 7:role=="EDITED_RENDER" ? 5:1,"uti":"public.data","required":true,"resourceClass":role=="EDITED_RENDER" ? "EDITED":role=="ADJUSTMENT_DATA" ? "AUXILIARY":"ORIGINAL","expectedSize":100,"expectedSha256":sha,"assetId":asset,"cloudVersionId":String(repeating:"a",count:64),"status":"PROTECTED","evidence":["id":asset,"cloudVersionId":String(repeating:"a",count:64),"mediaType":i==1&&kind=="LIVE_PHOTO" ? "video":"image","expectedSize":100,"expectedSha256":sha,"resourcePolicy":"SINGLE_PROTECTED_RESOURCE"]]};return ["manifest":["id":UUID().uuidString,"manifestVersion":1,"kind":kind,"mediaType":"image","policy":"PRESERVE_ALL_AVAILABLE","legacy":false,"protection":"FULLY_PROTECTED","requiredCount":rs.count,"protectedCount":rs.count,"sourceFingerprint":String(repeating:"b",count:64),"sourceChanged":false,"reviewRequired":false,"integrityDegraded":false,"manifestFingerprint":String(repeating:"c",count:64),"resources":rs],"choice":choice,"resources":rs]}
 func decode(_ j:[String:Any])throws->CompoundRestorePlan{try JSONDecoder().decode(CompoundRestorePlan.self,from:JSONSerialization.data(withJSONObject:j))}
 func changed(_ key:String,_ value:Any)throws->CompoundRestorePlan{var j=json();var m=j["manifest"] as! [String:Any];m[key]=value;j["manifest"]=m;return try decode(j)}
 func testLivePlanComplete()throws{XCTAssertTrue(try decode(json()).valid);XCTAssertTrue(try decode(json()).reconstructable)}
 func testPartialLogicalProofRejected()throws{XCTAssertFalse(try changed("protection","PARTIALLY_PROTECTED").valid)}
 func testSourceChangedRejected()throws{XCTAssertFalse(try changed("sourceChanged",true).valid)}
 func testIntegrityDegradedRejected()throws{XCTAssertFalse(try changed("integrityDegraded",true).valid)}
 func testUnknownRequiredRejected()throws{XCTAssertFalse(try changed("reviewRequired",true).valid)}
 func testFutureSchemaRejected()throws{XCTAssertFalse(try changed("manifestVersion",2).valid)}
 func testMissingPairRejected()throws{var j=json();j["resources"]=[(j["resources"] as! [[String:Any]])[0]];XCTAssertFalse(try decode(j).valid)}
 func testDuplicateResourceRejected()throws{var j=json();let r=(j["resources"] as! [[String:Any]])[0];j["resources"]=[r,r];XCTAssertFalse(try decode(j).valid)}
 func testRoleSubstitutionRejected()throws{var j=json();var rs=j["resources"] as! [[String:Any]];rs[1]["role"]="PRIMARY_STILL";j["resources"]=rs;XCTAssertFalse(try decode(j).valid)}
 func testUTISubstitutionRejected()throws{var j=json();var rs=j["resources"] as! [[String:Any]];rs[1]["uti"]="public.jpeg";j["resources"]=rs;XCTAssertFalse(try decode(j).valid)}
 func testVersionSubstitutionRejected()throws{var j=json();var rs=j["resources"] as! [[String:Any]];rs[1]["cloudVersionId"]=String(repeating:"d",count:64);j["resources"]=rs;XCTAssertFalse(try decode(j).valid)}
 func testRAWPlanPreservesOriginal()throws{XCTAssertTrue(try decode(json(roles:["RAW_ORIGINAL"],kind:"RAW")).reconstructable)}
 func testRAWJPEGPlanUsesBoth()throws{XCTAssertTrue(try decode(json(roles:["RAW_ORIGINAL","JPEG_COMPANION"],kind:"RAW_JPEG")).reconstructable)}
 func testEditedFullRecipeNotFlattened()throws{XCTAssertFalse(try decode(json(roles:["PRIMARY_STILL","EDITED_RENDER","ADJUSTMENT_DATA"],kind:"EDITED")).reconstructable)}
 func testEditedOriginalExplicit()throws{var j=json(roles:["PRIMARY_STILL","EDITED_RENDER","ADJUSTMENT_DATA"],choice:"ORIGINAL",kind:"EDITED");j["resources"]=[(j["resources"] as! [[String:Any]])[0]];let p=try decode(j);XCTAssertTrue(p.valid);XCTAssertTrue(p.reconstructable)}
 func testEditedRenderedExplicit()throws{var j=json(roles:["PRIMARY_STILL","EDITED_RENDER","ADJUSTMENT_DATA"],choice:"EDITED",kind:"EDITED");j["resources"]=[(j["resources"] as! [[String:Any]])[1]];let p=try decode(j);XCTAssertTrue(p.valid);XCTAssertTrue(p.reconstructable)}
 func fixture()async throws->(CompoundRestoreQueue,CompoundRestoreCoordinator,CompoundRestoreRecord,CompoundFixturePhotos,RestoreFiles){let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);addTeardownBlock{try? FileManager.default.removeItem(at:root)};let queue=try CompoundRestoreQueue(url:root.appendingPathComponent("queue.sqlite")),files=try RestoreFiles(directory:root.appendingPathComponent("files")),plan=try decode(json()),record=CompoundRestoreRecord(account:UUID(),library:UUID(),plan:plan),photos=CompoundFixturePhotos();try await queue.insert(record);let engine=CompoundRestoreCoordinator(queue:queue,files:files,api:CompoundFixtureAPI(plan),downloader:FakeDownload(),photos:photos,capacity:FakeCapacity(bytes:nil));try await engine.activate(account:record.account,library:record.library);return(queue,engine,record,photos,files)}
 func testPairDownloadsVerifyAndSaveTogether()async throws{let(q,e,r,p,files)=try await fixture();try await e.run(r.id);let saved=try await q.read(r.id);XCTAssertEqual(saved?.state,.restored);let count=await p.resourceCount;XCTAssertEqual(count,2);for id in r.fileIDs.values{XCTAssertFalse(FileManager.default.fileExists(atPath:files.url(id).path))}}
 func testPermissionDenialNeverSavesPair()async throws{let(q,e,r,p,_)=try await fixture();await p.deny();do{try await e.run(r.id);XCTFail()}catch{};let saved=try await q.read(r.id),count=await p.saves;XCTAssertEqual(saved?.state,.paused);XCTAssertEqual(count,0)}
 func testAccountSwitchStopsCompoundWorkflow()async throws{let(_,e,r,p,_)=try await fixture();await e.deactivate();do{try await e.run(r.id);XCTFail()}catch{};let count=await p.saves;XCTAssertEqual(count,0)}
 func testQueuePaginationTenantIsolation()async throws{let(q,_,r,_,_)=try await fixture();let page=try await q.page(account:UUID(),library:r.library);XCTAssertTrue(page.isEmpty)}
 func testCompoundDownloadsUseTwoSlotsAndRetryReusesVerifiedResource()async throws {
  let(q,_,r,p,files)=try await fixture(),download=MeteredCompoundDownload()
  await download.fail()
  let engine=CompoundRestoreCoordinator(queue:q,files:files,api:CompoundFixtureAPI(r.plan),downloader:download,photos:p,capacity:FakeCapacity(bytes:nil))
  try await engine.activate(account:r.account,library:r.library)
  do{try await engine.run(r.id);XCTFail()}catch{}
  let savesBefore=await p.saves;XCTAssertEqual(savesBefore,0)
  try await engine.resume(r.id);try await engine.run(r.id)
  let calls=await download.calls,maximum=await download.maximum,state=try await q.read(r.id)?.state
  XCTAssertEqual(calls,3);XCTAssertEqual(maximum,2);XCTAssertEqual(state,.restored)
 }
 func testCompoundCachedResourceMustPassChecksumAgain()async throws {
  let(q,_,r,p,files)=try await fixture(),download=MeteredCompoundDownload()
  let resources=r.plan.resources
  try Data(repeating:0x64,count:100).write(to:files.url(r.fileIDs[resources[0].id]!))
  try Data(repeating:0x65,count:100).write(to:files.url(r.fileIDs[resources[1].id]!))
  let engine=CompoundRestoreCoordinator(queue:q,files:files,api:CompoundFixtureAPI(r.plan),downloader:download,photos:p,capacity:FakeCapacity(bytes:nil))
  try await engine.activate(account:r.account,library:r.library);try await engine.run(r.id)
  let calls=await download.calls,state=try await q.read(r.id)?.state
  XCTAssertEqual(calls,1);XCTAssertEqual(state,.restored)
 }

}

private final class CompoundChangingSpace:DeviceCapacity,@unchecked Sendable {
 private var calls=0;private let lock=NSLock()
 func available(at:URL)throws->Int64?{lock.lock();defer{lock.unlock()};calls+=1;return calls==2 ? 0:Int64.max}
}
extension CompoundTests {
 func testCompleteMediaChecksDeviceSpaceAgainBeforeSavingAndCanResume()async throws {
  let(q,_,r,p,files)=try await fixture(),download=FakeDownload(),engine=CompoundRestoreCoordinator(queue:q,files:files,api:CompoundFixtureAPI(r.plan),downloader:download,photos:p,capacity:CompoundChangingSpace())
  try await engine.activate(account:r.account,library:r.library)
  do{try await engine.run(r.id);XCTFail("Expected device capacity failure")}catch{XCTAssertEqual(error as? RestoreFailure,.deviceSpace)}
  let paused=try await q.read(r.id),saves=await p.saves;XCTAssertEqual(paused?.state,.paused);XCTAssertEqual(paused?.lastErrorCode,"DEVICE_SPACE_REQUIRED");XCTAssertEqual(saves,0)
  try await engine.resume(r.id);try await engine.run(r.id);let done=try await q.read(r.id),count=await download.calls;XCTAssertEqual(done?.state,.restored);XCTAssertEqual(count,r.plan.resources.count)
 }
}
