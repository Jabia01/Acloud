import Foundation
import UploadFoundation

// Persistent system tasks carry opaque queue IDs. Queue never serializes authorization.
public final class PartURLSessionTransport:NSObject,PartTransport,URLSessionTaskDelegate,@unchecked Sendable {
 private let origin:URL;private let background:Bool;private let cellular:Bool
 private let lock=NSLock();private var pending:[Int:CheckedContinuation<Void,Error>]=[:]
 private var finishHandler:(@Sendable()->Void)?
 private lazy var session:URLSession={
  let c:URLSessionConfiguration
  #if os(iOS)
  c=background ? .background(withIdentifier:"com.example.backupclient.dev.multipart") : .ephemeral
  c.sessionSendsLaunchEvents=background;c.isDiscretionary=false
  #else
  c = .ephemeral
  #endif
  c.httpCookieStorage=nil;c.urlCredentialStorage=nil;c.urlCache=nil;c.allowsCellularAccess=cellular
  c.allowsConstrainedNetworkAccess=false;c.allowsExpensiveNetworkAccess=cellular;c.timeoutIntervalForResource=300
  return URLSession(configuration:c,delegate:self,delegateQueue:nil)
 }()
 public init(origin:URL,background:Bool=false,allowsCellular:Bool=false,allowLocalHTTP:Bool=false) throws {
  guard origin.user==nil,origin.password==nil,origin.query==nil,origin.fragment==nil,origin.scheme=="https" || (allowLocalHTTP && origin.scheme=="http" && (["localhost","127.0.0.1"].contains(origin.host ?? "") || origin.host?.hasSuffix(".local") == true)) else{throw BackupFailure.authorization}
  self.origin=origin;self.background=background;cellular=allowsCellular;super.init()
 }
 public func reconnect(completion:@escaping @Sendable()->Void){lock.lock();finishHandler=completion;lock.unlock();_=session}
 public func activeItemIDs() async -> Set<UUID> {
  Set(await session.allTasks.compactMap{UUID(uuidString:$0.taskDescription?.split(separator:":").first.map(String.init) ?? "")})
 }
 func validateAuthorization(resource:PreparedResource,authorization:UploadAuthorization) throws {
  let u=authorization.url,p=ISO8601DateFormatter();p.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
  guard authorization.method=="PUT",let expiry=p.date(from:authorization.expiresAt),expiry>Date(),u.scheme==origin.scheme,u.host?.lowercased()==origin.host?.lowercased(),u.port==origin.port,u.user==nil,u.password==nil,u.fragment==nil,[Set(["content-length"]),Set(["content-length","x-amz-checksum-sha256"])].contains(Set(authorization.headers.keys)),authorization.headers["content-length"]==String(resource.sizeBytes) else{throw BackupFailure.authorization}
  let h=resource.checksum;guard h.count==64 else{throw BackupFailure.authorization};var digest=Data();var i=h.startIndex
  while i<h.endIndex{let end=h.index(i,offsetBy:2);guard let b=UInt8(h[i..<end],radix:16) else{throw BackupFailure.authorization};digest.append(b);i=end}
  guard authorization.headers["x-amz-checksum-sha256"]==nil || authorization.headers["x-amz-checksum-sha256"]==digest.base64EncodedString() else{throw BackupFailure.authorization}
 }
 public func upload(item:UUID,number:Int,resource:PreparedResource,authorization:UploadAuthorization,policy:BackupPolicy) async throws {
  try validateAuthorization(resource:resource,authorization:authorization)
  var request=URLRequest(url:authorization.url);request.httpMethod="PUT";request.allowsCellularAccess=cellular && policy.allowCellular && !policy.wifiOnly
  request.allowsConstrainedNetworkAccess = !policy.pauseOnConstrained;request.allowsExpensiveNetworkAccess=request.allowsCellularAccess
  for(k,v) in authorization.headers{request.setValue(v,forHTTPHeaderField:k)}
  try await withTaskCancellationHandler(operation:{
   try Task.checkCancellation()
   try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in
    let task=session.uploadTask(with:request,fromFile:resource.fileURL);task.taskDescription="\(item.uuidString):\(number)"
    lock.lock();pending[task.taskIdentifier]=c;lock.unlock();if Task.isCancelled{task.cancel()}else{task.resume()}
   }
  },onCancel:{Task{await self.cancel(item:item)}})
 }
 public func cancel(item:UUID) async {
  for task in await session.allTasks where task.taskDescription?.hasPrefix(item.uuidString+":")==true{task.cancel()}
  // Wait for daemon acknowledgement; never remove a file still owned by a transfer.
  while await session.allTasks.contains(where:{$0.taskDescription?.hasPrefix(item.uuidString+":")==true}){try? await Task.sleep(for:.milliseconds(20))}
 }
 public func shutdown() async {
  for task in await session.allTasks{task.cancel()}
  while !(await session.allTasks).isEmpty{try? await Task.sleep(for:.milliseconds(20))}
  session.invalidateAndCancel()
 }
 public func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){
  lock.lock();let c=pending.removeValue(forKey:task.taskIdentifier);lock.unlock();guard let c else{return}
  if let error{c.resume(throwing:error);return}
  guard let http=task.response as? HTTPURLResponse else{c.resume(throwing:BackupFailure.http(503));return}
  if (200..<300).contains(http.statusCode){c.resume()}else{c.resume(throwing:http.statusCode==403 ? BackupFailure.authorization : BackupFailure.http(http.statusCode))}
 }
 public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
 public func urlSessionDidFinishEvents(forBackgroundURLSession session:URLSession){lock.lock();let h=finishHandler;finishHandler=nil;lock.unlock();DispatchQueue.main.async{h?()}}
}
