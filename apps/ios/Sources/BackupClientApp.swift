import SwiftUI
import UIKit
import UserNotifications
final class BackgroundTransferDelegate:NSObject,UIApplicationDelegate,UNUserNotificationCenterDelegate {
 func application(_ application:UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool {
  UNUserNotificationCenter.current().delegate=self
  return true
 }
 func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping @Sendable(UNNotificationPresentationOptions)->Void) {
  let identifier=notification.request.identifier
  Task{@MainActor in
   guard TransferNotifications.shared.mayPresentForeground(identifier) else{completionHandler([]);return}
   completionHandler([.banner,.list,.sound])
  }
 }
 func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void) {
  if let tab=response.notification.request.content.userInfo["transferTab"] as? String,["backup","restore"].contains(tab) {
   UserDefaults.standard.set(tab,forKey:"selectedTransferTab")
  }
  completionHandler()
 }
 func application(_ application:UIApplication,handleEventsForBackgroundURLSession identifier:String,completionHandler:@escaping()->Void){
  guard identifier == "com.example.backupclient.dev.multipart" else{completionHandler();return}
  Task{@MainActor in await BackupQueueModel.shared.handleBackground(completion:completionHandler)}
 }
}
@main struct BackupClientApp:App {
 @UIApplicationDelegateAdaptor(BackgroundTransferDelegate.self) var delegate
 var body:some Scene {WindowGroup{ContentView()}}
}
