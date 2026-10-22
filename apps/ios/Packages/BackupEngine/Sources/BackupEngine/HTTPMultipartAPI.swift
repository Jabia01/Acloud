import Foundation
import MediaPreservation
import HealthClient
import UploadFoundation

private final class NoRedirect: NSObject,URLSessionTaskDelegate,@unchecked Sendable {
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
public actor HTTPMultipartAPI:MultipartAPI {
 private let base:URL;private let tokens:any SessionTokenStore;private let network:URLSession
 public init(base:URL,tokens:any SessionTokenStore,allowLocalHTTP:Bool=false) throws {
  guard base.user==nil,base.password==nil,base.query==nil,base.fragment==nil,base.scheme=="https" || (allowLocalHTTP && base.scheme=="http" && (["localhost","127.0.0.1"].contains(base.host ?? "") || base.host?.hasSuffix(".local") == true)) else{throw BackupFailure.authorization}
  self.base=base;self.tokens=tokens
  let c=URLSessionConfiguration.ephemeral;c.httpCookieStorage=nil;c.urlCredentialStorage=nil;c.urlCache=nil
  network=URLSession(configuration:c,delegate:NoRedirect(),delegateQueue:nil)
 }
 private func request<T:Decodable>(_ path:String,method:String="POST",body:[String:Any]?=nil,key:UUID?=nil) async throws -> T {
  if let expected=Bundle.main.object(forInfoDictionaryKey:"BetaDeploymentFingerprint") as? String {
   guard base.scheme=="https",expected.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw BackupFailure.authorization}
   var probe=URLRequest(url:base.appendingPathComponent("health"));probe.timeoutInterval=10
   let (_,response)=try await network.data(for:probe)
   guard let http=response as? HTTPURLResponse,http.statusCode==200,http.value(forHTTPHeaderField:"X-Environment-Fingerprint")==expected else{throw BackupFailure.authorization}
  }
  guard let token=try tokens.read() else{throw BackupFailure.http(401)}
  var r=URLRequest(url:base.appendingPathComponent(path));r.httpMethod=method;r.timeoutInterval=16*60
  if let fingerprint=Bundle.main.object(forInfoDictionaryKey:"BetaDeploymentFingerprint") as? String{r.setValue(fingerprint,forHTTPHeaderField:"X-Environment-Fingerprint")}
  r.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type")
  if let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,version.range(of:"^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$",options:.regularExpression) != nil{r.setValue(version,forHTTPHeaderField:"X-App-Version")}
        if let key{r.setValue(key.uuidString,forHTTPHeaderField:"Idempotency-Key")};if let body{r.httpBody=try JSONSerialization.data(withJSONObject:body)}
  let (data,response)=try await network.data(for:r)
  guard let http=response as? HTTPURLResponse else{throw BackupFailure.http(503)}
  if let fingerprint=Bundle.main.object(forInfoDictionaryKey:"BetaDeploymentFingerprint") as? String,http.value(forHTTPHeaderField:"X-Environment-Fingerprint") != fingerprint{throw BackupFailure.authorization}
  guard (200..<300).contains(http.statusCode) else{
   throw BackupFailure.responseFailure(status:http.statusCode,body:data)
  }
  return try JSONDecoder().decode(T.self,from:data)
 }
 public func create(_ item:BackupItem) async throws -> MultipartSession {
  guard let size=item.expectedSizeBytes,let checksum=item.expectedChecksum else{throw BackupFailure.missing}
  if let binding=item.mediaResourceBinding{struct Receipt:Decodable{let recorded:Bool};let _:Receipt=try await request("media-manifests/\(binding.manifestID)/resources/\(binding.resourceID)/capture",body:["sourceFingerprint":binding.sourceFingerprint,"expectedSize":size,"expectedSha256":checksum]);return try await request("media-manifests/\(binding.manifestID)/resources/\(binding.resourceID)/upload",body:["sourceFingerprint":binding.sourceFingerprint])}
  return try await request("uploads",body:["media_type":item.mediaType,"expected_size_bytes":size,"checksum_sha256":checksum,"multipart":true,"library_id":item.libraryID.uuidString],key:item.uploadKey)
 }
 public func status(_ id:UUID) async throws -> MultipartSession {try await request("uploads/\(id)/",method:"GET")}
 public func start(_ id:UUID) async throws -> MultipartSession {try await request("uploads/\(id)/multipart")}
 public func parts(_ id:UUID) async throws -> PartListing {try await request("uploads/\(id)/parts",method:"GET")}
 public func authorize(_ id:UUID,number:Int,size:Int,checksum:String) async throws -> UploadAuthorization {try await request("uploads/\(id)/parts/\(number)/authorize",body:["size_bytes":size,"checksum_sha256":checksum])}
 public func complete(_ id:UUID) async throws -> MultipartSession {try await request("uploads/\(id)/complete-multipart")}
 public func verify(_ id:UUID) async throws -> MultipartSession {try await request("uploads/\(id)/complete")}
 public func asset(_ id:UUID) async throws -> ServerAsset {try await request("assets/\(id)",method:"GET")}
 public func integrity(_ id:UUID) async throws -> OriginalServerProof?{try await request("assets/\(id)/integrity",method:"GET")}
 public func cancel(_ id:UUID) async throws {let _:MultipartSession=try await request("uploads/\(id)",method:"DELETE")}
 public func createManifest(_ manifest:MediaManifest)async throws->UUID{struct Created:Decodable{let id:UUID};let receipt:Created=try await request("media-manifests",body:manifest.wireMetadata());return receipt.id}
 public func manifestProof(_ id:UUID)async throws->ServerManifestProof{try await request("media-manifests/\(id)",method:"GET")}
 public func invalidateManifest(_ id:UUID,fingerprint:String)async throws{struct Invalidated:Decodable{let state:String};let _:Invalidated=try await request("media-manifests/\(id)/source-changed",body:["sourceFingerprint":fingerprint])}
}
