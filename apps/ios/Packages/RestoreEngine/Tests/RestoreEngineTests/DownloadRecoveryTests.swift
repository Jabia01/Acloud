import XCTest
import Foundation
@testable import RestoreEngine

private final class RecoveryWire:URLProtocol,@unchecked Sendable {
 static let lock=NSLock()
 static var handler:((RecoveryWire)->Void)?
 static func configure(_ value:@escaping(RecoveryWire)->Void){lock.lock();handler=value;lock.unlock()}
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading(){Self.lock.lock();let h=Self.handler;Self.lock.unlock();h?(self)}
 override func stopLoading(){}
 func respond(_ status:Int,_ bytes:Data,headers:[String:String]=[:],drop:Bool=false){
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:bytes)
  if drop{DispatchQueue.global().asyncAfter(deadline:.now()+0.05){self.client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost))}}
  else{client?.urlProtocolDidFinishLoading(self)}
 }
}
private final class WireRequests:@unchecked Sendable {
 private let lock=NSLock();private var values:[String]=[]
 func add(_ request:URLRequest)->Int{lock.lock();defer{lock.unlock()};values.append(request.value(forHTTPHeaderField:"Range") ?? "");return values.count}
 var ranges:[String]{lock.lock();defer{lock.unlock()};return values}
}
final class DownloadRecoveryTests:XCTestCase {
 let bytes=Data("generated-fixture".utf8)
 private func target()throws->URL{let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:d)};return d.appendingPathComponent(UUID().uuidString+".bin")}
 private func capability(_ version:String="one",token:String="generated")->RestoreCapability{RestoreCapability(url:URL(string:"https://storage.example.invalid/bucket/generated?versionId=\(version)&X-Amz-Signature=\(token)")!,expiresAt:"2099-01-01T00:00:00.000Z")}
 private func downloader()throws->FileRestoreDownloader{try FileRestoreDownloader(origin:URL(string:"https://storage.example.invalid")!,configurationFactory:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[RecoveryWire.self];return c})}
 private func seed(_ target:URL,version:String="one")throws {
  let partial=RestorePartial(target:target);_=try partial.prepare(capability:capability(version),expected:bytes.count);try bytes.prefix(5).write(to:partial.file)
 }
 func testConnectionDropResumesOnlyMissingBytes()async throws {
  let target=try target(),requests=WireRequests(),data=Data(repeating:0x65,count:256*1024),cut=64*1024
  RecoveryWire.configure{wire in
   if requests.add(wire.request)==1{wire.respond(200,data.prefix(cut),headers:["Content-Length":String(data.count)],drop:true)}
   else{wire.respond(206,data.dropFirst(cut),headers:["Content-Length":String(data.count-cut),"Content-Range":"bytes \(cut)-\(data.count-1)/\(data.count)"])}
  }
  do{try await downloader().download(capability(),to:target,expectedSize:data.count,progress:{_ in})}catch{XCTFail("Recovery failed: \(error), ranges=\(requests.ranges)");return}
  XCTAssertEqual(requests.ranges,["","bytes=\(cut)-"]);XCTAssertEqual(try Data(contentsOf:target),data)
  XCTAssertFalse(FileManager.default.fileExists(atPath:RestorePartial(target:target).file.path))
 }
 func testFreshAuthorizationAndDownloaderReusePinnedPartialWithoutSavingURL()async throws {
  let target=try target(),requests=WireRequests(),data=bytes;try seed(target)
  let binding=try String(contentsOf:RestorePartial(target:target).binding,encoding:.utf8);XCTAssertEqual(binding.count,64);XCTAssertFalse(binding.contains("http"));XCTAssertFalse(binding.contains("generated"))
  RecoveryWire.configure{wire in _=requests.add(wire.request);wire.respond(206,data.dropFirst(5),headers:["Content-Range":"bytes 5-\(data.count-1)/\(data.count)"])}
  try await downloader().download(capability(token:"fresh"),to:target,expectedSize:bytes.count,progress:{_ in})
  XCTAssertEqual(requests.ranges,["bytes=5-"]);XCTAssertEqual(try Data(contentsOf:target),bytes)
 }
 func testVersionChangeDiscardsPartial()async throws {
  let target=try target(),requests=WireRequests(),data=bytes;try seed(target)
  RecoveryWire.configure{wire in _=requests.add(wire.request);wire.respond(200,data)}
  try await downloader().download(capability("two"),to:target,expectedSize:bytes.count,progress:{_ in})
  XCTAssertEqual(requests.ranges,[""]);XCTAssertEqual(try Data(contentsOf:target),bytes)
 }
 func testProviderIgnoringRangeReplacesRatherThanAppends()async throws {
  let target=try target(),data=bytes;try seed(target)
  RecoveryWire.configure{wire in wire.respond(200,data)}
  try await downloader().download(capability(),to:target,expectedSize:bytes.count,progress:{_ in})
  XCTAssertEqual(try Data(contentsOf:target),bytes)
 }
 func testWrongRangeFailsClosedAndClearsPartial()async throws {
  let target=try target(),data=bytes;try seed(target)
  RecoveryWire.configure{wire in wire.respond(206,data.dropFirst(5),headers:["Content-Range":"bytes 4-\(data.count-1)/\(data.count)"])}
  do{try await downloader().download(capability(),to:target,expectedSize:bytes.count,progress:{_ in});XCTFail()}catch{XCTAssertEqual(error as? RestoreFailure,.integrity)}
  XCTAssertFalse(FileManager.default.fileExists(atPath:target.path));XCTAssertFalse(FileManager.default.fileExists(atPath:RestorePartial(target:target).file.path))
 }
 func testOversizeStreamNeverProducesDownload()async throws {
  let target=try target(),data=bytes
  RecoveryWire.configure{wire in wire.respond(200,data+data)}
  do{try await downloader().download(capability(),to:target,expectedSize:bytes.count,progress:{_ in});XCTFail()}catch{XCTAssertEqual(error as? RestoreFailure,.integrity)}
  XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
 }
 func testPartialSymlinkIsRejectedWithoutChangingLinkedFile()async throws {
  let target=try target(),outside=try self.target();try bytes.write(to:outside)
  try FileManager.default.createSymbolicLink(at:RestorePartial(target:target).file,withDestinationURL:outside)
  XCTAssertThrowsError(try RestorePartial(target:target).prepare(capability:capability(),expected:bytes.count));XCTAssertEqual(try Data(contentsOf:outside),bytes)
 }
 func testUnpinnedObjectNeverResumes()throws {
  let target=try target();try seed(target)
  let auth=RestoreCapability(url:URL(string:"https://storage.example.invalid/generated")!,expiresAt:"2099-01-01T00:00:00.000Z")
  let offset=try RestorePartial(target:target).prepare(capability:auth,expected:bytes.count);XCTAssertEqual(offset,0)
 }
 func testCancellationCleanupRemovesPartialsButRetryKeepsThem()throws {
  let target=try target(),files=try RestoreFiles(directory:target.deletingLastPathComponent()),id=UUID();let url=files.url(id);try seed(url)
  try files.remove(id,includingPartial:false);XCTAssertTrue(FileManager.default.fileExists(atPath:RestorePartial(target:url).file.path))
  try files.remove(id);XCTAssertFalse(FileManager.default.fileExists(atPath:RestorePartial(target:url).file.path));XCTAssertFalse(FileManager.default.fileExists(atPath:RestorePartial(target:url).binding.path))
 }
}
