import Foundation
@main struct BackupSelectionTests {
 @MainActor static func main() async {
  precondition(BackupSelectionPolicy.normalized([])==nil)
  precondition(BackupSelectionPolicy.normalized([""])==nil)
  precondition(BackupSelectionPolicy.normalized(Array(repeating:"one",count:11))==nil)
  precondition(BackupSelectionPolicy.normalized(["one","two","one"])==["one","two"])
  precondition(BackupSelectionPolicy.normalized(["one"],unavailableCount:-1)==nil)
  precondition(BackupSelectionPolicy.normalized(Array(repeating:"one",count:10),unavailableCount:1)==nil)
  var visited:[String]=[]
  let result=await BackupSelectionPolicy.process(["good","unsupported","existing","blocked","failed","last","good"],unavailableCount:1){id in
   visited.append(id)
   switch id {case "unsupported":return .unsupported;case "existing":return .existing;case "blocked":return .inaccessible;case "failed":return .failed;default:return .added}
  }
  precondition(visited==["good","unsupported","existing","blocked","failed","last"])
  precondition(result?.added==2 && result?.existing==1 && result?.unsupported==1 && result?.inaccessible==2 && result?.failed==1)
  precondition(result!.message.contains("2 added") && !result!.message.contains("unsupported existing"))
  let inaccessible=await BackupSelectionPolicy.process([],unavailableCount:2){_ in fatalError("Unavailable identifiers must never be queued")}
  precondition(inaccessible?.added==0 && inaccessible?.inaccessible==2)
  let ten=await BackupSelectionPolicy.process((0..<10).map{String($0)}){_ in .added}
  precondition(ten?.added==10)
  var called=false
  let invalid=await BackupSelectionPolicy.process((0..<11).map{String($0)}){_ in called=true;return .added}
  precondition(invalid==nil && !called)
  print("PASS: 10-item bound, stable deduplication, missing access, mixed outcomes and continuation after individual failure")
 }
}
