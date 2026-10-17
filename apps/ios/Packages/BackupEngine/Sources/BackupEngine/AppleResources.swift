#if canImport(Photos)
import Foundation
import Photos
public struct PhotoKitOriginalSource:OriginalResourceSource {
 public init(){}
 private func asset(_ id:String)throws->PHAsset{let auth=PHPhotoLibrary.authorizationStatus(for:.readWrite);guard auth == .authorized || auth == .limited,let a=PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject else{throw BackupFailure.inaccessible};return a}
 public func describe(_ id:String) async throws -> OriginalDescriptor {let a=try asset(id),r=PHAssetResource.assetResources(for:a);return OriginalDescriptor(localID:a.localIdentifier,mediaType:a.mediaType == .video ? "video":"image",resourceTypes:r.map{$0.type.rawValue},resourceUTIs:r.map{$0.uniformTypeIdentifier},width:a.pixelWidth,height:a.pixelHeight,duration:a.mediaType == .video ? a.duration:nil,creation:a.creationDate,modification:a.modificationDate,livePhoto:a.mediaSubtypes.contains(.photoLive))}
 public func stream(_ id:String,to url:URL,allowNetwork:Bool,progress:@escaping @Sendable(Double)->Void) async throws {
  let a=try asset(id),resources=PHAssetResource.assetResources(for:a)
  let snapshot=try await describe(id);guard snapshot.supported,resources.count==1,let resource=resources.first else{throw BackupFailure.unsupported}
  let options=PHAssetResourceRequestOptions();options.isNetworkAccessAllowed=allowNetwork;options.progressHandler={value in progress(min(1,max(0,value)))}
  let writer=try PhotoResourceWriter(url:url)
  do{try await withTaskCancellationHandler(operation:{try await writer.write(resource,options:options)},onCancel:{writer.cancel()});progress(1)}catch{let e=error as NSError;if e.domain==PHPhotosErrorDomain&&e.code==PHPhotosError.Code.networkAccessRequired.rawValue{throw BackupFailure.waitingForOriginal};if error is CancellationError{throw CancellationError()};throw BackupFailure.inaccessible}
 }
}
#if DEBUG
// Compatibility adapter remains opt-in; generated development paths do not grant beta admission.
public struct PhotoKitResourcePreparer:ResourcePreparer {
 private let files:ManagedTemporaryFiles;private let enabled:Bool
 public init(files:ManagedTemporaryFiles,developmentEnabled:Bool=false){self.files=files;enabled=developmentEnabled}
 public func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot) async throws -> PreparedResource {guard enabled,let account=item.accountID,let device=item.deviceID else{throw BackupFailure.unsupported};return try await OriginalResourcePreparer(source:PhotoKitOriginalSource(),files:files,binding:OriginalBinding(accountID:account,deviceID:device,libraryID:item.libraryID)).prepare(item,policy:policy,network:network)}
 public func cleanup(_ item:BackupItem) async throws{try files.cleanup(item.id)}
}
 #endif
private final class PhotoResourceWriter:@unchecked Sendable {
 private let lock=NSLock()
 private let handle:FileHandle
 private var continuation:CheckedContinuation<Void,Error>?
 private var requestID:PHAssetResourceDataRequestID?
 private var finished=false
 private var cancelled=false
 private var bytes=0
 init(url:URL) throws {
  guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw BackupFailure.storage}
  #if os(iOS)
  try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
  #endif
  handle=try FileHandle(forWritingTo:url)
 }
 func write(_ resource:PHAssetResource,options:PHAssetResourceRequestOptions) async throws {
  try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
   lock.lock()
   if cancelled{lock.unlock();c.resume(throwing:CancellationError());return}
   continuation=c;lock.unlock()
   let id=PHAssetResourceManager.default().requestData(for:resource,options:options,dataReceivedHandler:{[self] data in
    lock.lock();guard !finished else{lock.unlock();return}
    do{guard data.count<=10*1024*1024*1024-bytes else{throw BackupFailure.unsupported};bytes+=data.count;try handle.write(contentsOf:data);lock.unlock()}catch{lock.unlock();finish(error)}
   },completionHandler:{[self] error in finish(error)})
   lock.lock();requestID=id;let shouldCancel=cancelled || finished;lock.unlock()
   if shouldCancel{PHAssetResourceManager.default().cancelDataRequest(id)}
  }
 }
 private func finish(_ error:Error?){
  lock.lock();guard !finished else{lock.unlock();return};finished=true
  let c=continuation;continuation=nil
  var failure=error
  do{if error==nil{try handle.synchronize()};try handle.close()}catch{failure=error}
  lock.unlock();if let failure{c?.resume(throwing:failure)}else{c?.resume()}
 }
 func cancel(){lock.lock();cancelled=true;let id=requestID;lock.unlock();if let id{PHAssetResourceManager.default().cancelDataRequest(id)};finish(CancellationError())}
 deinit{try? handle.close()}
}
#endif
#if canImport(Network)
import Network
public final class BackupNetworkMonitor:@unchecked Sendable {
 private let monitor=NWPathMonitor()
 public init(coordinator:BackupCoordinator,onChange:@escaping @Sendable()->Void={}){monitor.pathUpdateHandler={path in
  let value=NetworkSnapshot(connected:path.status == .satisfied,cellular:path.usesInterfaceType(.cellular),wifi:path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),constrained:path.isConstrained)
  Task{try? await coordinator.setNetwork(value);onChange()}
 };monitor.start(queue:DispatchQueue(label:"backup.network-policy"))}
 deinit{monitor.cancel()}
}
#endif
#if canImport(Photos)
import MediaPreservation
public struct PhotoKitMediaSource:MediaResourceSource{
 public init(){}
 private func asset(_ id:String)throws->PHAsset{let auth=PHPhotoLibrary.authorizationStatus(for:.readWrite);guard auth == .authorized||auth == .limited,let asset=PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject else{throw BackupFailure.inaccessible};return asset}
 private func orderedResources(_ asset:PHAsset)throws->[PHAssetResource]{
  let resources=PHAssetResource.assetResources(for:asset),descriptors=resources.enumerated().map{ResourceDescriptor(ordinal:$0.offset,resourceType:$0.element.type.rawValue,uti:$0.element.uniformTypeIdentifier)}
  guard let order=try? ResourceDescriptor.canonicalSourceOrder(descriptors) else{throw BackupFailure.unsupported}
  return order.map{resources[$0]}
 }
 public func snapshot(_ id:String)async throws->MediaSourceSnapshot{let a=try asset(id),resources=try orderedResources(a);return MediaSourceSnapshot(localID:id,mediaType:a.mediaType == .video ? "video":"image",livePhoto:a.mediaSubtypes.contains(.photoLive),width:a.pixelWidth,height:a.pixelHeight,creation:a.creationDate,modification:a.modificationDate,duration:a.mediaType == .video ? a.duration:nil,resources:resources.enumerated().map{ResourceDescriptor(ordinal:$0.offset,resourceType:$0.element.type.rawValue,uti:$0.element.uniformTypeIdentifier)})}
 public func stream(_ id:String,descriptor:ResourceDescriptor,to url:URL,allowNetwork:Bool,progress:@escaping @Sendable(Double)->Void)async throws{let a=try asset(id),resources=try orderedResources(a);guard resources.indices.contains(descriptor.ordinal) else{throw BackupFailure.sourceChanged};let resource=resources[descriptor.ordinal];guard ResourceDescriptor(ordinal:descriptor.ordinal,resourceType:resource.type.rawValue,uti:resource.uniformTypeIdentifier)==descriptor else{throw BackupFailure.sourceChanged};let options=PHAssetResourceRequestOptions();options.isNetworkAccessAllowed=allowNetwork;options.progressHandler=progress;let writer=try PhotoResourceWriter(url:url);do{try await withTaskCancellationHandler(operation:{try await writer.write(resource,options:options)},onCancel:{writer.cancel()})}catch{let e=error as NSError;if e.domain==PHPhotosErrorDomain&&e.code==PHPhotosError.Code.networkAccessRequired.rawValue{throw BackupFailure.waitingForOriginal};throw error}}
}
#endif
