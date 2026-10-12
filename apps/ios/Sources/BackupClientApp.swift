import SwiftUI
import UIKit
final class BackgroundTransferDelegate:NSObject,UIApplicationDelegate {
 func application(_ application:UIApplication,handleEventsForBackgroundURLSession identifier:String,completionHandler:@escaping()->Void){
  guard identifier == "com.example.backupclient.dev.multipart" else{completionHandler();return}
  Task{@MainActor in await BackupQueueModel.shared.handleBackground(completion:completionHandler)}
 }
}
@main struct BackupClientApp:App {
 @UIApplicationDelegateAdaptor(BackgroundTransferDelegate.self) var delegate
 var body:some Scene {WindowGroup{ContentView()}}
}
