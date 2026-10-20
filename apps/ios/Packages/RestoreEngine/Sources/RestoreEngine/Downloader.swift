import Foundation
import CryptoKit
import OSLog

// Store only an opaque binding, never a signed URL. Each retry still requires a
// fresh server capability for the same immutable version and final SHA-256 proof.
struct RestorePartial {
 let file:URL,binding:URL
 init(target:URL){file=target.appendingPathExtension("partial");binding=target.appendingPathExtension("partial-binding")}
 static func secure(_ url:URL)throws {
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
  var excluded=url;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
  #if os(iOS)
  try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
  #endif
 }
 func remove()throws{for url in [file,binding]{if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}}}
 func prepare(capability:RestoreCapability,expected:Int)throws->Int {
  for url in [file,binding] where FileManager.default.fileExists(atPath:url.path){guard try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]).isRegularFile==true,try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw RestoreFailure.storage}}
  let version=URLComponents(url:capability.url,resolvingAgainstBaseURL:false)?.queryItems?.filter{$0.name=="versionId"}
  let pinned=version?.count==1 && !(version?.first?.value ?? "").isEmpty
  let identity="\(capability.url.scheme ?? "")://\(capability.url.host ?? ""):\(capability.url.port ?? 443)\(URLComponents(url:capability.url,resolvingAgainstBaseURL:false)?.percentEncodedPath ?? "")|\(version?.first?.value ?? "")|\(expected)"
  let digest=Data(SHA256.hash(data:Data(identity.utf8))).map{String(format:"%02x",$0)}.joined()
  let previous=try? String(contentsOf:binding,encoding:.utf8)
  let size=((try? FileManager.default.attributesOfItem(atPath:file.path)[.size]) as? NSNumber)?.intValue ?? 0
  if pinned,previous==digest,size>0,size<expected{return size}
  try remove();guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw RestoreFailure.storage}
  try Data(digest.utf8).write(to:binding,options:.atomic);try Self.secure(file);try Self.secure(binding);return 0
 }
}

private final class FileDownloadDelegate:NSObject,URLSessionDataDelegate,@unchecked Sendable {
 private let lock=NSLock(),partial:RestorePartial,expected:Int,offset:Int,progress:@Sendable(Int)->Void
 private var continuation:CheckedContinuation<Void,Error>?,failure:Error?,finished=false,lastProgress=0,bytes:Int,handle:FileHandle?
 init(partial:RestorePartial,expected:Int,offset:Int,progress:@escaping @Sendable(Int)->Void){self.partial=partial;self.expected=expected;self.offset=offset;self.bytes=offset;self.progress=progress}
 func attach(_ c:CheckedContinuation<Void,Error>)->Bool{lock.lock();if finished{let error=failure ?? CancellationError();lock.unlock();c.resume(throwing:error);return false};continuation=c;lock.unlock();return true}
 func finish(_ error:Error?){lock.lock();guard !finished else{lock.unlock();return};finished=true;try? handle?.synchronize();try? handle?.close();handle=nil;failure=failure ?? error;let result=failure,c=continuation;continuation=nil;lock.unlock();if let result{c?.resume(throwing:result)}else{c?.resume()}}
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
  lock.lock();defer{lock.unlock()}
  guard !finished else{completionHandler(.cancel);return}
  do{
   guard let http=response as? HTTPURLResponse else{throw RestoreFailure.http(503)}
   guard http.statusCode==200 || http.statusCode==206 else{throw RestoreFailure.http(http.statusCode)}
   if http.statusCode==206 {
    guard offset>0,http.value(forHTTPHeaderField:"Content-Range")=="bytes \(offset)-\(expected-1)/\(expected)" else{throw RestoreFailure.integrity}
    bytes=offset
   }else{bytes=0} // Provider ignored Range: replace, never append the whole file.
   if response.expectedContentLength>=0,response.expectedContentLength != expected-bytes{throw RestoreFailure.integrity}
   handle=try FileHandle(forWritingTo:partial.file)
   if bytes==0{try handle?.truncate(atOffset:0)}else{try handle?.seek(toOffset:UInt64(bytes))}
   completionHandler(.allow)
  }catch{failure=error;completionHandler(.cancel)}
 }
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){
  lock.lock();guard !finished,failure==nil else{lock.unlock();return}
  do{guard handle != nil,data.count<=expected-bytes else{throw RestoreFailure.integrity};try handle?.write(contentsOf:data);bytes+=data.count;let notify=bytes-lastProgress>=1024*1024 || bytes==expected;if notify{lastProgress=bytes};let count=bytes;lock.unlock();if notify{progress(count)}}catch{failure=error;lock.unlock();dataTask.cancel()}
 }
 func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){lock.lock();let result=failure ?? error ?? (bytes==expected ? nil:RestoreFailure.integrity);lock.unlock();finish(result)}
}
public actor FileRestoreDownloader:RestoreDownloader {
 private let origin:URL,allowLocalHTTP:Bool
 private let configurationFactory:@Sendable()->URLSessionConfiguration
 private var sessions:[UUID:URLSession]=[:],targets:Set<URL>=[]
 public init(origin:URL,allowLocalHTTP:Bool=false,configurationFactory:@escaping @Sendable()->URLSessionConfiguration={.ephemeral})throws{guard origin.user==nil,origin.password==nil,origin.query==nil,origin.fragment==nil,["","/"].contains(origin.path),origin.scheme=="https"||(allowLocalHTTP&&origin.scheme=="http"&&(["127.0.0.1","localhost"].contains(origin.host ?? "") || origin.host?.hasSuffix(".local") == true)) else{throw RestoreFailure.authorization};self.origin=origin;self.allowLocalHTTP=allowLocalHTTP;self.configurationFactory=configurationFactory}
 public func download(_ capability:RestoreCapability,to target:URL,expectedSize:Int,progress:@escaping @Sendable(Int)->Void)async throws {
  guard capability.method=="GET",capability.url.scheme==origin.scheme,capability.url.host?.lowercased()==origin.host?.lowercased(),capability.url.port==origin.port,capability.url.user==nil,capability.url.password==nil,capability.url.fragment==nil,expectedSize>0,expectedSize<=10*1024*1024*1024,!targets.contains(target) else{throw RestoreFailure.authorization}
  let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];guard let expiry=formatter.date(from:capability.expiresAt),expiry>Date() else{throw RestoreFailure.http(403)}
  let started=Date()
  targets.insert(target);defer{targets.remove(target)}
  let partial=RestorePartial(target:target)
  for attempt in 0...2 {
   try Task.checkCancellation();guard expiry>Date() else{throw RestoreFailure.http(403)}
   let offset=try partial.prepare(capability:capability,expected:expectedSize)
   let delegate=FileDownloadDelegate(partial:partial,expected:expectedSize,offset:offset,progress:progress),configuration=configurationFactory()
   configuration.httpCookieStorage=nil;configuration.urlCredentialStorage=nil;configuration.urlCache=nil;configuration.allowsCellularAccess=false;configuration.allowsConstrainedNetworkAccess=false;configuration.allowsExpensiveNetworkAccess=false
   let session=URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil),id=UUID();sessions[id]=session
   defer{sessions.removeValue(forKey:id);session.finishTasksAndInvalidate()}
   var request=URLRequest(url:capability.url);request.timeoutInterval=3600;request.cachePolicy = .reloadIgnoringLocalCacheData
   request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
   if offset>0{request.setValue("bytes=\(offset)-",forHTTPHeaderField:"Range")}
   do {
    try await withTaskCancellationHandler(operation:{try Task.checkCancellation();try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>)in if delegate.attach(c){session.dataTask(with:request).resume()}}},onCancel:{delegate.finish(CancellationError());session.invalidateAndCancel()})
    try Task.checkCancellation()
    if FileManager.default.fileExists(atPath:target.path){guard try target.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw RestoreFailure.storage};try FileManager.default.removeItem(at:target)}
    try FileManager.default.moveItem(at:partial.file,to:target);try? FileManager.default.removeItem(at:partial.binding)
    Logger(subsystem:"com.acloud.transfers",category:"restore-performance").info("phase=download durationMs=\(Int(Date().timeIntervalSince(started)*1000)) bytes=\(expectedSize) resumedBytes=\(offset)");return
   }catch{
    if error as? RestoreFailure == .integrity{try? partial.remove()}
    guard let failure=error as? URLError,[.networkConnectionLost,.timedOut,.cannotConnectToHost,.notConnectedToInternet].contains(failure.code),attempt<2 else{throw error}
    try await Task.sleep(for:.milliseconds(250*(attempt+1)))
   }
  }
 }
 public func cancel()async{for session in sessions.values{session.invalidateAndCancel()}}
}
