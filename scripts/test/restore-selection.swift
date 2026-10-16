import Foundation
@main struct RestoreSelectionTests {
 static func main() {
  let ids=(0..<11).map{_ in UUID()},allowed=Set(ids)
  precondition(!RestoreSelectionPolicy.accepts([],allowed:allowed))
  precondition(RestoreSelectionPolicy.accepts(Set(ids.prefix(1)),allowed:allowed))
  precondition(RestoreSelectionPolicy.accepts(Set(ids.prefix(10)),allowed:allowed))
  precondition(!RestoreSelectionPolicy.accepts(Set(ids),allowed:allowed))
  precondition(!RestoreSelectionPolicy.accepts([UUID()],allowed:allowed))
  precondition(!RestoreSelectionPolicy.accepts(Set(ids.prefix(3)),allowed:Set(ids.prefix(2))))
  print("PASS: batch bounds and owner/visible selection scope")
 }
}
