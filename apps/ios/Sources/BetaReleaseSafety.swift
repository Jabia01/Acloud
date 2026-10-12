import Foundation
// Build flags never grant server authorization. Release blocks development endpoints/adapters.
enum BetaReleaseSafety {
 static var acceptedConfiguration: Bool {
 #if DEBUG
 return true
 #else
 let info=Bundle.main.infoDictionary ?? [:]
 guard info["BetaRelease"] as? Bool == true,
       info["EnableFreeUpSpace"] as? Bool != true,
       info["DisposableCleanupContext"] as? Bool != true,
       info["DevelopmentBackgroundTransfers"] as? Bool != true,
       info["BetaEnvironment"] as? String == "staging",
       let fingerprint=info["BetaDeploymentFingerprint"] as? String,fingerprint.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
       let identifier=Bundle.main.bundleIdentifier,!identifier.hasSuffix(".dev") else{return false}
 for key in ["APIBaseURL","StorageOrigin"] {
  guard let value=info[key] as? String,let url=URL(string:value),url.scheme=="https",
        let host=url.host,host != "localhost",host != "127.0.0.1",!host.hasSuffix(".invalid"),
        url.user==nil,url.password==nil,url.query==nil,url.fragment==nil else{return false}
 }
 return true
 #endif
 }
}
