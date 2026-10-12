import XCTest
import Foundation
import CryptoKit
@testable import RestoreEngine
actor FakeRestoreAPI:RestoreAPI{
 var evidence:RestoreEvidence,authorizeError:RestoreFailure?,checkError:RestoreFailure?,changed=false,authorizations=0,rechecks=0,events:[String]=[]
 init(_ e:RestoreEvidence){evidence=e}
 func configure(auth:RestoreFailure?=nil,check:RestoreFailure?=nil,changed:Bool=false){authorizeError=auth;checkError=check;self.changed=changed}
 func authorize(_ e:RestoreEvidence)throws->RestoreAuthorization{authorizations+=1;if let error=authorizeError{throw error};return RestoreAuthorization(evidence:evidence,authorization:RestoreCapability(url:URL(string:"https://storage.example.test/private?temporary=fixture")!,expiresAt:"2099-01-01T00:00:00.000Z"))}
 func recheck(_ e:RestoreEvidence)throws->RestoreEvidence{rechecks+=1;if let error=checkError{throw error};if changed{return RestoreEvidence(id:e.id,cloudVersionId:String(repeating:"0",count:64),mediaType:e.mediaType,expectedSize:e.expectedSize,expectedSha256:e.expectedSha256)};return evidence}
 func report(_ code:String,retry:Int,durationMs:Int?){events.append(code)}
}
actor FakeDownload:RestoreDownloader{
 var failure:Error?,altered=false,sizeDelta=0,delay:UInt64=0,active=0,peak=0,calls=0,maxChunk=0
 func configure(failure:Error?=nil,altered:Bool=false,sizeDelta:Int=0,delay:UInt64=0){self.failure=failure;self.altered=altered;self.sizeDelta=sizeDelta;self.delay=delay}
 func download(_ c:RestoreCapability,to url:URL,expectedSize:Int,progress:@escaping @Sendable(Int)->Void)async throws{calls+=1;active+=1;peak=max(peak,active);defer{active-=1};if delay>0{try await Task.sleep(nanoseconds:delay)};guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw RestoreFailure.storage};let file=try FileHandle(forWritingTo:url);defer{try? file.close()};if let failure{try file.write(contentsOf:Data([1]));throw failure};var left=max(0,expectedSize+sizeDelta),written=0;let chunk=Data(repeating:altered ? 0x64:0x65,count:65536);while left>0{try Task.checkCancellation();let n=min(left,chunk.count);maxChunk=max(maxChunk,n);try file.write(contentsOf:chunk.prefix(n));left-=n;written+=n};try file.synchronize();progress(written)}
 func cancel(){}
}
actor FakePhotos:PhotoLibraryRestorer{
 var allowed=true,failure=false,delay:UInt64=0,identifiers:Set<String>=[],unknown=false,saves=0,active=0,peak=0
 func configure(allowed:Bool=true,failure:Bool=false,delay:UInt64=0,unknown:Bool=false){self.allowed=allowed;self.failure=failure;self.delay=delay;self.unknown=unknown}
 func canSave()->Bool{allowed}
 func save(_ file:URL,mediaType:String)async throws->String{saves+=1;active+=1;peak=max(peak,active);defer{active-=1};if delay>0{try await Task.sleep(nanoseconds:delay)};if failure{throw RestoreFailure.ambiguousSave};let id=UUID().uuidString;identifiers.insert(id);return id}
 func presence(_ id:String)->LocalPresence{unknown ? .unknown:identifiers.contains(id) ? .exists:.absent}
 func add(_ id:String){identifiers.insert(id)}
}
struct FakeCapacity:DeviceCapacity{let bytes:Int64?;func available(at:URL)throws->Int64?{bytes}}
struct Fixture{
 let engine:RestoreCoordinator,queue:RestoreQueue,files:RestoreFiles,item:RestoreItem,api:FakeRestoreAPI,download:FakeDownload,photos:FakePhotos,directory:URL
}
class RestoreTestBase:XCTestCase{
 func fixture(bytes:Int=100,media:String="image",capacity:Int64?=nil,concurrency:Int=2)async throws->Fixture{let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);addTeardownBlock{try? FileManager.default.removeItem(at:dir)};let files=try RestoreFiles(directory:dir.appendingPathComponent("temp")),queue=try RestoreQueue(url:dir.appendingPathComponent("restore.sqlite"));var hash=SHA256();let chunk=Data(repeating:0x65,count:65536);var left=bytes;while left>0{let n=min(left,chunk.count);hash.update(data:chunk.prefix(n));left-=n};let evidence=RestoreEvidence(id:UUID(),cloudVersionId:String(repeating:"a",count:64),mediaType:media,expectedSize:bytes,expectedSha256:hash.finalize().map{String(format:"%02x",$0)}.joined()),item=RestoreItem(accountID:UUID(),libraryID:UUID(),evidence:evidence);try await queue.enqueue(item);let api=FakeRestoreAPI(evidence),download=FakeDownload(),photos=FakePhotos(),engine=RestoreCoordinator(queue:queue,files:files,api:api,downloader:download,photos:photos,capacity:FakeCapacity(bytes:capacity),concurrency:concurrency);try await engine.activate(account:item.accountID,library:item.libraryID);return Fixture(engine:engine,queue:queue,files:files,item:item,api:api,download:download,photos:photos,directory:dir)}
 func state(_ f:Fixture)async throws->RestoreState{try await f.queue.read(f.item.id)!.state}
 func assertState(_ f:Fixture,_ expected:RestoreState)async throws{let actual=try await state(f);XCTAssertEqual(actual,expected)}
 func advance(_ f:Fixture,to target:RestoreState)async throws->RestoreItem{var item=f.item;for state in [RestoreState.authorizing,.downloading,.verifying,.ready,.saving]{item.state=state;item=try await f.queue.save(item);if state==target{return item}};return item}
 func expectFailure(_ operation:()async throws->Void)async{do{try await operation();XCTFail("Expected failure")}catch{}}
}

actor MultiRestoreAPI:RestoreAPI{func authorize(_ e:RestoreEvidence)async throws->RestoreAuthorization{RestoreAuthorization(evidence:e,authorization:RestoreCapability(url:URL(string:"https://storage.example.test/private")!,expiresAt:"2099-01-01T00:00:00.000Z"))};func recheck(_ e:RestoreEvidence)async throws->RestoreEvidence{e}}
