import Foundation

public enum StorageSpace {
 public static let margin:Int64=64*1024*1024
 public static func required(bytes:Int64,copies:Int64=2)->Int64 {
  guard bytes>=0,copies>=1 else{return Int64.max}
  let (total,overflow)=bytes.multipliedReportingOverflow(by:copies)
  let (result,added)=total.addingReportingOverflow(margin)
  return overflow || added ? Int64.max:result
 }
 public static func permits(available:Int64?,required:Int64)->Bool{guard let available else{return true};return available>=required}
 public static func isFull(_ error:Error)->Bool {
  var current: NSError?=error as NSError
  for _ in 0..<8 {guard let value=current else{return false};if value.domain==NSCocoaErrorDomain&&value.code==NSFileWriteOutOfSpaceError || value.domain==NSPOSIXErrorDomain&&value.code==28{return true};current=value.userInfo[NSUnderlyingErrorKey] as? NSError}
  return false
 }
}
