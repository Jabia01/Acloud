import SwiftUI
import HealthClient
import Photos
import UIKit

struct ContentView: View {
    @AppStorage("selectedTransferTab") private var selectedTab = "backup"
    @State private var status = "Checking..."

    var body: some View {
        TabView(selection: $selectedTab) {
            BackupQueueView().tag("backup").tabItem { Label("Backup", systemImage: "icloud.and.arrow.up") }
            DiscoveryView().tag("library").tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            RestoreView().tag("restore").tabItem { Label("Restore", systemImage: "arrow.down.circle") }
            StorageView().tag("storage").tabItem { Label("Storage", systemImage: "externaldrive") }
            AccountView().tag("account").tabItem { Label("Account", systemImage: "person") }
            #if DEBUG
            VStack(spacing: 16) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Acloud")
                .font(.largeTitle)
            Text("Development Build")
            Text("API Status: \(status)")
                .accessibilityLabel("API Status: \(status)")
            }
            .padding()
            .tag("development").tabItem { Label("Development", systemImage: "heart.text.square") }
            #endif
        }
        .tint(AcloudStyle.accent)
        .task { await checkHealth() }
    }

    @MainActor
    private func checkHealth() async {
        guard BetaReleaseSafety.acceptedConfiguration, let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              let url = URL(string: value) else {
            status = "Unavailable"
            return
        }
        status = await HealthAPI(baseURL: url).isConnected() ? "Connected" : "Unavailable"
    }
}


// Shared presentation only. These views never grant protection or change transfer state.
enum AcloudStyle {
    static let accent = Color(red:0.12, green:0.40, blue:0.46)
    static let canvas = Color(uiColor:.systemGroupedBackground)
}

struct AcloudHero:View {
    let icon:String
    let eyebrow:String
    let title:String
    let message:String
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:10) {
                Image(systemName:icon).font(.title2).accessibilityHidden(true)
                Text(eyebrow.uppercased()).font(.caption.weight(.semibold)).tracking(1.5)
            }.foregroundStyle(.white.opacity(0.85))
            Text(title).font(.system(.largeTitle,design:.rounded).weight(.bold)).fixedSize(horizontal:false,vertical:true)
            Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal:false,vertical:true)
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(24)
        .foregroundStyle(.white)
        .background(LinearGradient(colors:[AcloudStyle.accent,Color(red:0.08,green:0.22,blue:0.31)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:24))
    }
}

struct AcloudMetric:View {
    let title:String
    let value:String
    let icon:String
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Image(systemName:icon).foregroundStyle(AcloudStyle.accent).font(.title3).accessibilityHidden(true)
            Text(value).font(.system(.title,design:.rounded).weight(.bold)).foregroundStyle(.primary)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18)
        .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20))
        .accessibilityElement(children:.combine)
    }
}

struct AcloudMediaIcon:View {
    let video:Bool
    var body:some View {
        Image(systemName:video ? "play.rectangle.fill":"photo.fill")
            .font(.title2).foregroundStyle(AcloudStyle.accent)
            .frame(width:52,height:56)
            .background(AcloudStyle.accent.opacity(0.10),in:RoundedRectangle(cornerRadius:14))
            .accessibilityHidden(true)
    }
}

extension View {
    func acloudCanvas()->some View {
        self.scrollContentBackground(.hidden).background(AcloudStyle.canvas)
            .listStyle(.insetGrouped).tint(AcloudStyle.accent)
    }
    func acloudFeatureRow()->some View {
        self.listRowInsets(EdgeInsets(top:8,leading:0,bottom:8,trailing:0))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

// Media-list presentation stays local. Preview requests never download iCloud originals.
enum AcloudMediaFilter:String,CaseIterable,Identifiable {
    case all="All", photos="Photos", videos="Videos"
    var id:String {rawValue}
    func includes(_ type:String)->Bool {self == .all || (self == .photos && type == "image") || (self == .videos && type == "video")}
}
struct AcloudDatedMediaGroup<Item>:Identifiable {
    let id:String
    let mediaType:String
    let day:Date?
    let items:[Item]
    var title:String {mediaType == "image" ? "Photos" : mediaType == "video" ? "Videos" : "Other files"}
}
func acloudMediaGroups<Item>(_ items:[Item],type:(Item)->String,date:(Item)->Date?)->[AcloudDatedMediaGroup<Item>] {
    let calendar=Calendar.current
    let grouped=Dictionary(grouping:items){item in
        let kind=["image","video"].contains(type(item)) ? type(item):"other"
        let day=date(item).map{String(calendar.startOfDay(for:$0).timeIntervalSince1970)} ?? "undated"
        return kind+"|"+day
    }
    return grouped.map{key,values in
        AcloudDatedMediaGroup(id:key,mediaType:key.components(separatedBy:"|")[0],day:date(values[0]).map{calendar.startOfDay(for:$0)},items:values.sorted{(date($0) ?? .distantPast) > (date($1) ?? .distantPast)})
    }.sorted{a,b in
        let rank:[String:Int]=["image":0,"video":1,"other":2]
        if a.mediaType != b.mediaType{return rank[a.mediaType,default:2] < rank[b.mediaType,default:2]}
        return (a.day ?? .distantPast) > (b.day ?? .distantPast)
    }
}
struct AcloudMediaGroupTitle:View {
    let title:String
    let date:Date?
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title)
            if let date {Text(date,format:.dateTime.month(.wide).day().year()).font(.caption)}
            else {Text("Date unavailable").font(.caption)}
        }
    }
}
struct AcloudMediaHeader:View {
    let type:String
    let reference:UUID
    var localID:String?=nil
    let dateLabel:String
    let date:Date?
    var detail:String?=nil
    @State private var capturedAt:Date?
    var body:some View {
        HStack(alignment:.top,spacing:14) {
            ZStack(alignment:.bottomTrailing) {
                RoundedRectangle(cornerRadius:12).fill(AcloudStyle.accent.opacity(0.1))
                Image(systemName:type == "video" ? "video.fill":type == "image" ? "photo.fill":"doc.fill").foregroundStyle(AcloudStyle.accent)
                AcloudLocalThumbnail(localID:localID,captureDate:$capturedAt).clipShape(RoundedRectangle(cornerRadius:12))
                if type == "video" {Image(systemName:"play.fill").font(.caption2).padding(6).foregroundStyle(.white).background(.black.opacity(0.65),in:Circle()).padding(5)}
            }.frame(width:76,height:76).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:5) {
                Text("\(type == "video" ? "Video":type == "image" ? "Photo":"File") · \(reference.uuidString.prefix(6))")
                    .font(.headline).foregroundStyle(.primary)
                if let capturedAt {Text("Taken \(capturedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))").font(.subheadline).foregroundStyle(.secondary)}
                if let date {Text("\(dateLabel) \(date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))").font(.caption).foregroundStyle(.secondary)}
                else {Text("\(dateLabel) date unavailable").font(.caption).foregroundStyle(.secondary)}
                if let detail {Text(detail).font(.caption).foregroundStyle(.secondary)}
            }.fixedSize(horizontal:false,vertical:true)
        }
    }
}
private struct AcloudLocalThumbnail:UIViewRepresentable {
    let localID:String?
    @Binding var captureDate:Date?
    final class Coordinator {
        var identity:String?
        var token=UUID()
        var request:PHImageRequestID=PHInvalidImageRequestID
        let manager=PHImageManager.default()
    }
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeUIView(context:Context)->UIImageView {
        let view=UIImageView();view.contentMode = .scaleAspectFill;view.clipsToBounds=true
        view.setContentHuggingPriority(.defaultLow,for:.horizontal)
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
    }
    func updateUIView(_ view:UIImageView,context:Context) {
        let status=PHPhotoLibrary.authorizationStatus(for:.readWrite)
        let identity=(localID ?? "none")+"|"+String(status.rawValue)
        let coordinator=context.coordinator
        guard identity != coordinator.identity else{return}
        coordinator.manager.cancelImageRequest(coordinator.request)
        coordinator.identity=identity;coordinator.token=UUID();view.image=nil
        let token=coordinator.token
        let asset:PHAsset?=(status == .authorized || status == .limited) ? localID.flatMap{PHAsset.fetchAssets(withLocalIdentifiers:[$0],options:nil).firstObject}:nil
        let binding=$captureDate
        DispatchQueue.main.async {if coordinator.token==token{binding.wrappedValue=asset?.creationDate}}
        guard let asset else{return}
        let options=PHImageRequestOptions();options.isNetworkAccessAllowed=false;options.deliveryMode = .opportunistic;options.resizeMode = .fast
        coordinator.request=coordinator.manager.requestImage(for:asset,targetSize:CGSize(width:160,height:160),contentMode:.aspectFill,options:options){[weak view,weak coordinator] image,_ in
            DispatchQueue.main.async {guard let coordinator,coordinator.token==token else{return};view?.image=image}
        }
    }
    static func dismantleUIView(_ view:UIImageView,coordinator:Coordinator) {
        coordinator.token=UUID();coordinator.manager.cancelImageRequest(coordinator.request);view.image=nil
    }
}
