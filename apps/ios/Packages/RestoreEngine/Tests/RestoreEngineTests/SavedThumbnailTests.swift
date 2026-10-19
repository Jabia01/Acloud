import XCTest
import Foundation
import CryptoKit
@testable import RestoreEngine
final class SavedThumbnailTests:XCTestCase {
 func payload(asset:UUID,bytes:Data,source:String=String(repeating:"b",count:64),hash:String?=nil,width:Int=240)throws->SavedThumbnail {
  let v:[String:Any]=["assetId":asset.uuidString,"cloudVersionId":String(repeating:"a",count:64),"sourceSha256":source,"thumbnailSha256":hash ?? SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),"mimeType":"image/jpeg","width":width,"height":160,"dataBase64":bytes.base64EncodedString()]
  return try JSONDecoder().decode(SavedThumbnail.self,from:JSONSerialization.data(withJSONObject:v))
 }
 func testSmallDerivativeChecksIdentitySourceAndOwnChecksum()throws {
  let asset=UUID(),bytes=Data([255,216,1,2,3,255,217]),source=String(repeating:"b",count:64)
  let thumbnail=try payload(asset:asset,bytes:bytes)
  XCTAssertEqual(try thumbnail.verifiedBytes(asset:asset,sourceChecksum:source),bytes)
  XCTAssertThrowsError(try thumbnail.verifiedBytes(asset:UUID(),sourceChecksum:source))
  XCTAssertThrowsError(try thumbnail.verifiedBytes(asset:asset,sourceChecksum:String(repeating:"c",count:64)))
  XCTAssertThrowsError(try payload(asset:asset,bytes:bytes,hash:String(repeating:"c",count:64)).verifiedBytes(asset:asset,sourceChecksum:source))
 }
 func testOversizedInvalidAndExcessDimensionsAreRejected()throws {
  let asset=UUID()
  for bytes in [Data(),Data("<svg>generated</svg>".utf8),Data(repeating:0,count:40961)] {
   XCTAssertThrowsError(try payload(asset:asset,bytes:bytes).verifiedBytes(asset:asset,sourceChecksum:nil))
  }
  XCTAssertThrowsError(try payload(asset:asset,bytes:Data([255,216,255,217]),width:241).verifiedBytes(asset:asset,sourceChecksum:nil))
 }
}
