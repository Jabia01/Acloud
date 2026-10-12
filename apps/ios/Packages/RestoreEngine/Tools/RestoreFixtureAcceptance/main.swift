import Foundation
import CryptoKit
import Darwin
import RestoreEngine
// This harness cannot save to Photos. Its only source is explicitly enabled generated loopback data.
@main struct Acceptance {
 static func main()async throws{
  guard CommandLine.arguments==[CommandLine.arguments[0],"--generated-loopback"] else{throw RestoreFailure.authorization}
  let origin=URL(string:"http://127.0.0.1:19813")!,directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),files=try RestoreFiles(directory:directory)
  defer{try? FileManager.default.removeItem(at:directory)}
  let downloader=try FileRestoreDownloader(origin:origin,allowLocalHTTP:true)
  var results:[[String:Any]]=[]
  for mib in [20,100,500]{let size=mib*1024*1024,id=UUID();var hash=SHA256();let chunk=Data(repeating:0x65,count:65536);for _ in 0..<(size/chunk.count){hash.update(data:chunk)};let e=RestoreEvidence(id:UUID(),cloudVersionId:String(repeating:"a",count:64),mediaType:"video",expectedSize:size,expectedSha256:hash.finalize().map{String(format:"%02x",$0)}.joined()),item=RestoreItem(accountID:UUID(),libraryID:UUID(),evidence:e,id:id);let start=Date()
   try await downloader.download(RestoreCapability(url:origin.appendingPathComponent(String(mib)),expiresAt:"2099-01-01T00:00:00.000Z"),to:files.url(id),expectedSize:size,progress:{_ in})
   let downloaded=Date(),verifyStart=Date();try files.verify(item);var usage=rusage();getrusage(RUSAGE_SELF,&usage)
   results.append(["mib":mib,"downloadSeconds":downloaded.timeIntervalSince(start),"downloadMiBPerSecond":Double(mib)/downloaded.timeIntervalSince(start),"verifySeconds":Date().timeIntervalSince(verifyStart),"processPeakRSSBytes":usage.ru_maxrss,"sizeAndSHA256":"PASS","photosSave":"NOT_RUN"]);try files.remove(id)
  }
  for path in ["redirect","expired","partial","oversize"]{let id=UUID();var refused=false;do{try await downloader.download(RestoreCapability(url:origin.appendingPathComponent(path),expiresAt:"2099-01-01T00:00:00.000Z"),to:files.url(id),expectedSize:1024*1024,progress:{_ in})}catch{refused=true};guard refused else{throw RestoreFailure.integrity};try files.remove(id)}
  let output:[String:Any]=["result":"PASS","scope":"generated loopback URLSession downloadTask; no provider, Photos, physical device or production benchmark","networkRejections":["redirect","403","206","oversize"],"results":results];let data=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
 }
}
