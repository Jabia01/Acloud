import XCTest
import ImageIO
import CoreGraphics
import AVFoundation
import CoreVideo
@testable import BackupEngine
final class VerifiedPreviewCacheTests:XCTestCase {
 func fixture(_ url:URL,red:CGFloat)throws {
  let context=CGContext(data:nil,width:480,height:320,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.setFillColor(CGColor(red:red,green:0.2,blue:1-red,alpha:1));context.fill(CGRect(x:0,y:0,width:480,height:320))
  let output=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
  CGImageDestinationAddImage(output,context.makeImage()!,nil)
  XCTAssertTrue(CGImageDestinationFinalize(output))
 }
 func testSavedThumbnailSurvivesSourceEditAndRejectsMismatchedBytes()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let source=root.appendingPathComponent("fixture.png"),account=UUID(),asset=UUID(),cache=VerifiedPreviewCache(directory:root.appendingPathComponent("cache"))
  try fixture(source,red:1);let original=try StreamingIntegrity.inspect(source)
  let first=try await cache.capture(file:source,account:account,asset:asset,checksum:original.checksum,size:original.sizeBytes,mediaType:"image")
  let decoded=CGImageSourceCreateWithData(first as CFData,nil)!,image=CGImageSourceCreateImageAtIndex(decoded,0,nil)!
  XCTAssertEqual(image.width,240);XCTAssertEqual(image.height,160)
  XCTAssertLessThan(first.count,256*1024)
  try fixture(source,red:0)
  do{_=try await cache.capture(file:source,account:account,asset:asset,checksum:original.checksum,size:original.sizeBytes,mediaType:"image");XCTFail("Changed source must not replace saved preview")}catch{}
  let stillSaved=try await cache.cached(account:account,asset:asset,checksum:original.checksum)
  XCTAssertEqual(first,stillSaved)
  let wrongOwner=try await cache.cached(account:UUID(),asset:asset,checksum:original.checksum)
  XCTAssertNil(wrongOwner)
  let wrongVersion=try await cache.cached(account:account,asset:asset,checksum:String(repeating:"b",count:64))
  XCTAssertNil(wrongVersion)
  let file=root.appendingPathComponent("cache").appendingPathComponent(BackupPreviewPolicy.key(account:account,asset:asset,checksum:original.checksum)!)
  let permissions=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? Int
  XCTAssertEqual(permissions,0o600)
 }
 func testSavedPreviewCanBeReloadedByNewCacheInstance()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let source=root.appendingPathComponent("generated.png"),directory=root.appendingPathComponent("cache"),account=UUID(),asset=UUID()
  try fixture(source,red:1);let proof=try StreamingIntegrity.inspect(source)
  let first=try await VerifiedPreviewCache(directory:directory).capture(file:source,account:account,asset:asset,checksum:proof.checksum,size:proof.sizeBytes,mediaType:"image")
  try FileManager.default.removeItem(at:source)
  let reloaded=try await VerifiedPreviewCache(directory:directory).cached(account:account,asset:asset,checksum:proof.checksum)
  XCTAssertEqual(first,reloaded,"Reopening the gallery must use the saved-version thumbnail without a source or download")
 }
 func testSmallCloudDerivativeIsDecodedAndCachedWithoutOriginal()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let source=root.appendingPathComponent("generated.png"),account=UUID(),asset=UUID(),cache=VerifiedPreviewCache(directory:root.appendingPathComponent("first"))
  try fixture(source,red:1);let proof=try StreamingIntegrity.inspect(source)
  let data=try await cache.capture(file:source,account:account,asset:asset,checksum:proof.checksum,size:proof.sizeBytes,mediaType:"image")
  XCTAssertLessThanOrEqual(data.count,40*1024)
  let destination=VerifiedPreviewCache(directory:root.appendingPathComponent("second"))
  try await destination.storeThumbnail(data,account:account,asset:asset,checksum:proof.checksum)
  let loaded=try await destination.cached(account:account,asset:asset,checksum:proof.checksum)
  XCTAssertEqual(loaded,data)
  do{try await destination.storeThumbnail(Data("generated invalid thumbnail".utf8),account:account,asset:asset,checksum:proof.checksum);XCTFail("Invalid bytes must be rejected")}catch{}
  let retained=try await destination.cached(account:account,asset:asset,checksum:proof.checksum)
  XCTAssertEqual(retained,data)
 }
 func testCorruptInputDoesNotCreateThumbnail()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let file=root.appendingPathComponent("not-image.bin"),cache=VerifiedPreviewCache(directory:root.appendingPathComponent("cache")),account=UUID(),asset=UUID()
  try Data("generated invalid image".utf8).write(to:file);let proof=try StreamingIntegrity.inspect(file)
  do{_=try await cache.capture(file:file,account:account,asset:asset,checksum:proof.checksum,size:proof.sizeBytes,mediaType:"image");XCTFail("Invalid image must fail")}catch{}
  let missing=try await cache.cached(account:account,asset:asset,checksum:proof.checksum)
  XCTAssertNil(missing)
 }
 func testVideoFrameFromVerifiedExtensionlessUpload()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let movie=root.appendingPathComponent("generated.mov"),writer=try AVAssetWriter(outputURL:movie,fileType:.mov)
  let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
  let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
  writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
  var buffer:CVPixelBuffer?
  XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,64,64,kCVPixelFormatType_32ARGB,nil,&buffer),kCVReturnSuccess)
  let frame=buffer!;CVPixelBufferLockBaseAddress(frame,[])
  memset(CVPixelBufferGetBaseAddress(frame),127,CVPixelBufferGetDataSize(frame));CVPixelBufferUnlockBaseAddress(frame,[])
  for index in 0..<3 {
   let deadline=Date().addingTimeInterval(10)
   while !input.isReadyForMoreMediaData && Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
   XCTAssertTrue(input.isReadyForMoreMediaData)
   XCTAssertTrue(adaptor.append(frame,withPresentationTime:CMTime(value:Int64(index),timescale:3)))
  }
  input.markAsFinished();await writer.finishWriting();XCTAssertEqual(writer.status,.completed)
  let source=root.appendingPathComponent("upload.bin");try FileManager.default.moveItem(at:movie,to:source)
  let proof=try StreamingIntegrity.inspect(source),cache=VerifiedPreviewCache(directory:root.appendingPathComponent("cache"))
  let result=try await cache.capture(file:source,account:UUID(),asset:UUID(),checksum:proof.checksum,size:proof.sizeBytes,mediaType:"video")
  let decoded=CGImageSourceCreateWithData(result as CFData,nil)
  XCTAssertNotNil(decoded)
  let image=CGImageSourceCreateImageAtIndex(decoded!,0,nil)!
  XCTAssertLessThanOrEqual(image.width,240);XCTAssertLessThanOrEqual(image.height,240)
  XCTAssertEqual(try StreamingIntegrity.inspect(source).checksum,proof.checksum)
 }

}
