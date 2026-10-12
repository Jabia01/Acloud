import Foundation
private final class FileDownloadDelegate:NSObject,URLSessionDownloadDelegate,@unchecked Sendable {
 private let lock=NSLock(),target:URL,expected:Int,progress:@Sendable(Int)->Void
 private var continuation:CheckedContinuation<Void,Error>?,failure:Error?,finished=false,lastProgress:Int64=0
 init(target:URL,expected:Int,progress:@escaping @Sendable(Int)->Void){self.target=target;self.expected=expected;self.progress=progress}
 func attach(_ c:CheckedContinuation<Void,Error>)->Bool{lock.lock();if finished{let error=failure ?? CancellationError();lock.unlock();c.resume(throwing:error);return false};continuation=c;lock.unlock();return true}
 func finish(_ error:Error?){lock.lock();guard !finished else{lock.unlock();return};finished=true;failure=error;let c=continuation;continuation=nil;lock.unlock();if let error{c?.resume(throwing:error)}else{c?.resume()}}
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
 func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){if totalBytesWritten>expected || totalBytesExpectedToWrite>expected{lock.lock();failure=RestoreFailure.integrity;lock.unlock();downloadTask.cancel()}else{lock.lock();let notify=totalBytesWritten-lastProgress>=1024*1024 || totalBytesWritten==expected;if notify{lastProgress=totalBytesWritten};lock.unlock();if notify{progress(Int(totalBytesWritten))}}}
 func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){lock.lock();guard !finished else{lock.unlock();return};defer{lock.unlock()};do{guard let response=downloadTask.response as? HTTPURLResponse else{throw RestoreFailure.http(503)};guard response.statusCode==200 else{throw RestoreFailure.http(response.statusCode)};guard (try location.resourceValues(forKeys:[.fileSizeKey])).fileSize==expected else{throw RestoreFailure.integrity};if FileManager.default.fileExists(atPath:target.path){try FileManager.default.removeItem(at:target)};try FileManager.default.copyItem(at:location,to:target);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
 #if os(iOS)
 try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:target.path)
 #endif
 }catch{failure=error}}
 func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){lock.lock();let result=failure ?? error;lock.unlock();finish(result)}
}
public actor FileRestoreDownloader:RestoreDownloader {
 private let origin:URL,allowLocalHTTP:Bool
 private var sessions:[UUID:URLSession]=[:]
 public init(origin:URL,allowLocalHTTP:Bool=false)throws{guard origin.user==nil,origin.password==nil,origin.query==nil,origin.fragment==nil,["","/"].contains(origin.path),origin.scheme=="https"||(allowLocalHTTP&&origin.scheme=="http"&&(["127.0.0.1","localhost"].contains(origin.host ?? "") || origin.host?.hasSuffix(".local") == true)) else{throw RestoreFailure.authorization};self.origin=origin;self.allowLocalHTTP=allowLocalHTTP}
 public func download(_ capability:RestoreCapability,to target:URL,expectedSize:Int,progress:@escaping @Sendable(Int)->Void)async throws {
  guard capability.method=="GET",capability.url.scheme==origin.scheme,capability.url.host?.lowercased()==origin.host?.lowercased(),capability.url.port==origin.port,capability.url.user==nil,capability.url.password==nil,capability.url.fragment==nil,expectedSize>0 else{throw RestoreFailure.authorization}
  let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];guard let expiry=formatter.date(from:capability.expiresAt),expiry>Date() else{throw RestoreFailure.http(403)}
  let delegate=FileDownloadDelegate(target:target,expected:expectedSize,progress:progress),configuration=URLSessionConfiguration.ephemeral;configuration.httpCookieStorage=nil;configuration.urlCredentialStorage=nil;configuration.urlCache=nil;configuration.allowsCellularAccess=false;configuration.allowsConstrainedNetworkAccess=false;configuration.allowsExpensiveNetworkAccess=false
  let session=URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil),id=UUID();sessions[id]=session;defer{sessions.removeValue(forKey:id);session.finishTasksAndInvalidate()}
  var request=URLRequest(url:capability.url);request.timeoutInterval=3600;request.cachePolicy = .reloadIgnoringLocalCacheData
  try await withTaskCancellationHandler(operation:{try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>)in if delegate.attach(c){session.downloadTask(with:request).resume()}}},onCancel:{delegate.finish(CancellationError());session.invalidateAndCancel()})
 }
 public func cancel()async{for session in sessions.values{session.invalidateAndCancel()}}
}
