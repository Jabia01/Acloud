import Foundation
import CryptoKit
public struct SavedThumbnail:Decodable,Sendable {
 public let assetId:UUID,cloudVersionId:String,sourceSha256:String,thumbnailSha256:String,mimeType:String
 public let width:Int,height:Int,dataBase64:String
 public func verifiedBytes(asset:UUID,sourceChecksum:String?)throws->Data {
  guard assetId==asset,mimeType=="image/jpeg",(1...240).contains(width),(1...240).contains(height),
        [cloudVersionId,sourceSha256,thumbnailSha256].allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}),
        sourceChecksum==nil || sourceChecksum==sourceSha256,dataBase64.utf8.count<=54616,
        let bytes=Data(base64Encoded:dataBase64),bytes.count>=4,bytes.count<=40*1024,
        bytes.starts(with:[0xff,0xd8]),bytes.suffix(2)==Data([0xff,0xd9]),
        SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==thumbnailSha256 else{throw RestoreFailure.integrity}
  return bytes
 }
}
