import MediaPreservation

// Test selection only. Never grants server access, restore fidelity, or cleanup eligibility.
public enum OwnerComplexBackupPolicy {
 public static func permits(_ snapshot:MediaSourceSnapshot)->Bool {
  guard snapshot.mediaType=="image",[MediaKind.livePhoto,.edited].contains(snapshot.kind),
        snapshot.enumerationValid,snapshot.shapeComplete,
        !snapshot.resources.contains(where:{$0.role == .raw || $0.resourceClass == .unknown}) else{return false}
  let roles=snapshot.resources.map(\.role)
  if roles.contains(.edited)||roles.contains(.adjustment) {
   guard roles.contains(.edited),roles.contains(.adjustment) else{return false}
  }
  return true
 }
}
