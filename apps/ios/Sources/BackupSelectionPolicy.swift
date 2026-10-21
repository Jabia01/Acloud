import Foundation

enum BackupSelectionOutcome { case added, existing, unsupported, inaccessible, failed; case rejected(Int) }
struct BackupSelectionSummary {
    var added=0, existing=0, unsupported=0, inaccessible=0, failed=0
    var statusCodes=Set<Int>()
    mutating func record(_ result: BackupSelectionOutcome) {
        switch result {
        case .added: added += 1
        case .existing: existing += 1
        case .unsupported: unsupported += 1
        case .inaccessible: inaccessible += 1
        case .failed: failed += 1
        case .rejected(let code): failed += 1; if (100...599).contains(code) { statusCodes.insert(code) }
        }
    }
    var message: String {
        var parts=["\(added) added to transfers."]
        if existing>0 { parts.append("\(existing) already in transfers; no duplicates added.") }
        if unsupported>0 { parts.append("\(unsupported) unsupported for this backup mode.") }
        if inaccessible>0 { parts.append("\(inaccessible) could not be accessed. Check Photos access and select those items again.") }
        if failed>0 {
            parts.append("\(failed) could not be added.")
            if !statusCodes.isEmpty {
                parts.append("Server response: "+statusCodes.sorted().map{"HTTP \($0)"}.joined(separator:", ")+".")
                if statusCodes.contains(401){parts.append("Sign in again, then retry the selection.")}
                else if statusCodes.contains(403){parts.append("The request was not permitted. Check your account access or contact support.")}
                else if statusCodes.contains(409){parts.append("Check existing transfers and available storage, then try again.")}
                else if statusCodes.contains(400){parts.append("The selection metadata was rejected. Contact support if this continues.")}
                else if statusCodes.contains(where:{$0>=500}){parts.append("The service could not process the request. Try again later.")}
            }else{parts.append("Try those items again; contact support if the problem continues.")}
        }
        return parts.joined(separator: " ")
    }
}
struct BackupPickerSelection {
    let identifiers: [String]
    let unavailableCount: Int
}
enum BackupSelectionPolicy {
    static let maximum=10
    static func normalized(_ identifiers: [String], unavailableCount: Int=0) -> [String]? {
        guard unavailableCount>=0, identifiers.count+unavailableCount>0,
              identifiers.count+unavailableCount<=maximum, identifiers.allSatisfy({!$0.isEmpty}) else { return nil }
        var seen=Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }
    @MainActor static func process(_ identifiers:[String], unavailableCount:Int=0,
                                  operation:(String) async -> BackupSelectionOutcome) async -> BackupSelectionSummary? {
        guard let ids=normalized(identifiers,unavailableCount:unavailableCount) else{return nil}
        var summary=BackupSelectionSummary();summary.inaccessible=unavailableCount
        for (index,id) in ids.enumerated() {
            if Task.isCancelled { summary.failed += ids.count-index; break }
            summary.record(await operation(id))
        }
        return summary
    }
}
