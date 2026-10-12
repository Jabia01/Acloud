import Foundation
import HealthClient
private final class CleanupNoRedirect:NSObject,URLSessionTaskDelegate,@unchecked Sendable{
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
public actor HTTPCleanupServer:CleanupServer {
 private let base:URL,tokens:any SessionTokenStore,network:URLSession
 public init(base:URL,tokens:any SessionTokenStore,allowLocalHTTP:Bool=false)throws{
  guard base.user==nil,base.password==nil,base.query==nil,base.fragment==nil,base.scheme=="https" || (allowLocalHTTP && base.scheme=="http" && (["localhost","127.0.0.1"].contains(base.host ?? "") || base.host?.hasSuffix(".local") == true)) else{throw CleanupFailure.identity}
  self.base=base;self.tokens=tokens;let c=URLSessionConfiguration.ephemeral;c.httpCookieStorage=nil;c.urlCache=nil;c.urlCredentialStorage=nil;network=URLSession(configuration:c,delegate:CleanupNoRedirect(),delegateQueue:nil)
 }
 public func get<T:Decodable>(_ path:String,type:T.Type) async throws->T{try await request(path,body:nil)}
 private func request<T:Decodable>(_ path:String,body:[String:Any]?) async throws->T{
  guard let token=try tokens.read() else{throw CleanupFailure.identity};var r=URLRequest(url:base.appendingPathComponent(path));r.httpMethod=body==nil ? "GET":"POST";r.timeoutInterval=16*60;r.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type");if let body{r.httpBody=try JSONSerialization.data(withJSONObject:body)}
  let(data,response)=try await network.data(for:r);guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else{throw CleanupFailure.proof}
  let d=JSONDecoder();d.dateDecodingStrategy = .custom{decoder in let text=try decoder.singleValueContainer().decode(String.self),f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];guard let date=f.date(from:text) else{throw CleanupFailure.proof};return date};return try d.decode(T.self,from:data)
 }
 public func prepare(context:CleanupContext,assetIDs:[UUID]) async throws->CleanupProof{try await request("storage/free-up-space/prepare",body:["assetIds":assetIDs.map(\.uuidString),"libraryId":context.libraryID.uuidString])}
 public func consume(_ proof:CleanupProof) async throws->CleanupReceipt{try await request("storage/free-up-space/consume",body:["token":proof.token])}
 public func protectionStillOwned(context:CleanupContext,assetIDs:[UUID]) async throws->Bool{
  struct Result:Decodable{struct Item:Decodable{let assetId:UUID,reason:String};let items:[Item]}
  let result:Result=try await request("storage/free-up-space/eligibility",body:["assetIds":assetIDs.map(\.uuidString),"libraryId":context.libraryID.uuidString]);return result.items.count==assetIDs.count && Set(result.items.map(\.assetId))==Set(assetIDs) && result.items.allSatisfy{["RECHECK_REQUIRED","FEATURE_DISABLED"].contains($0.reason)}
 }
 public func report(proofID:UUID,result:String) async{struct Result:Decodable{let recorded:Bool};let _:Result?=try? await request("storage/free-up-space/confirm-result",body:["proofId":proofID.uuidString,"result":result])}
}
