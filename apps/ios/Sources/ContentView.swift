import SwiftUI
import HealthClient
import Photos
import UIKit
import BackupEngine
import RestoreEngine

struct ContentView: View {
    @AppStorage("selectedTransferTab") private var selectedTab = "backup"
    @State private var status = "Checking..."

    var body: some View {
        TabView(selection: $selectedTab) {
            BackupQueueView().tag("backup").tabItem { Label("Backup", systemImage: "icloud.and.arrow.up") }
            DiscoveryView().tag("library").tabItem { Label("On device", systemImage: "photo.on.rectangle") }
            RestoreView().tag("restore").tabItem { Label("Saved", systemImage: "arrow.down.circle") }
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
        .task {
            // Queue recovery belongs to the app, independent of the selected tab.
            while !Task.isCancelled {
                await BackupQueueModel.shared.tick()
                try? await Task.sleep(for:.seconds(5))
            }
        }
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
enum AcloudPreviewSource { case device, backupVersion }
struct AcloudMediaHeader:View {
    let type:String
    let reference:UUID
    var localID:String?=nil
    var previewSource:AcloudPreviewSource = .device
    var sourceCaptureDate:Date?=nil
    var previewAccount:UUID?=nil
    var previewAsset:UUID?=nil
    var previewChecksum:String?=nil
    let dateLabel:String
    let date:Date?
    var detail:String?=nil
    @State private var capturedAt:Date?
    @State private var galleryViewer:AcloudGalleryPresentation?
    var body:some View {
        HStack(alignment:.top,spacing:14) {
            ZStack(alignment:.bottomTrailing) {
                RoundedRectangle(cornerRadius:12).fill(AcloudStyle.accent.opacity(0.1))
                Image(systemName:type == "video" ? "video.fill":type == "image" ? "photo.fill":"doc.fill").foregroundStyle(AcloudStyle.accent)
                if previewSource == .device {
                    AcloudLocalThumbnail(localID:localID,captureDate:$capturedAt).clipShape(RoundedRectangle(cornerRadius:12))
                }
                if previewSource == .backupVersion,["image","video"].contains(type),let account=previewAccount,let asset=previewAsset {
                    AcloudSavedThumbnail(account:account,asset:asset,checksum:previewChecksum).id(account.uuidString+asset.uuidString+(previewChecksum ?? ""))
                }
                if type == "video" {Image(systemName:"play.fill").font(.caption2).padding(6).foregroundStyle(.white).background(.black.opacity(0.65),in:Circle()).padding(5)}
            }.frame(width:76,height:76)
             .contentShape(Rectangle()).onTapGesture {
                if ["image","video"].contains(type) {
                    galleryViewer=AcloudGalleryPresentation(items:[AcloudGalleryEntry(id:reference.uuidString,type:type,date:sourceCaptureDate ?? date,localID:previewSource == .device ? localID:nil,account:previewAccount,asset:previewAsset,checksum:previewChecksum)],startID:reference.uuidString)
                }
             }.accessibilityLabel("Open \(type == "video" ? "video":"photo") preview").accessibilityAddTraits(.isButton)
             .sheet(item:$galleryViewer){presentation in AcloudGalleryViewer(items:presentation.items,startID:presentation.startID)}
            VStack(alignment:.leading,spacing:5) {
                Text("\(type == "video" ? "Video":type == "image" ? "Photo":"File") · \(reference.uuidString.prefix(6))")
                    .font(.headline).foregroundStyle(.primary)
                if let taken=sourceCaptureDate ?? (previewSource == .device ? capturedAt:nil) {Text("Taken \(taken.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))").font(.subheadline).foregroundStyle(.secondary)}
                if previewSource == .backupVersion {
                    Text("Saved version").font(.caption).foregroundStyle(.secondary)
                } else if localID != nil {
                    Text("Current device preview").font(.caption).foregroundStyle(.secondary)
                }
                if let date {Text("\(dateLabel) \(date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))").font(.caption).foregroundStyle(.secondary)}
                else {Text("\(dateLabel) date unavailable").font(.caption).foregroundStyle(.secondary)}
                if let detail {Text(detail).font(.caption).foregroundStyle(.secondary)}
            }.fixedSize(horizontal:false,vertical:true)
        }
        if previewSource == .backupVersion,["image","video"].contains(type),let account=previewAccount,let asset=previewAsset {
            AcloudSavedPreviewControl(account:account,asset:asset,checksum:previewChecksum).id(account.uuidString+asset.uuidString+(previewChecksum ?? ""))
        }
    }
}
struct AcloudLocalThumbnail:UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let localID:String?
    @Binding var captureDate:Date?
    var revision:Date?=nil
    var targetSize:CGFloat=320
    final class Coordinator {
        var identity:String?
        var displayedIdentity:String?
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
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UIImageView,context:Context)->CGSize? {
        guard let width=proposal.width,let height=proposal.height else{return nil}
        return CGSize(width:width,height:height)
    }
    func updateUIView(_ view:UIImageView,context:Context) {
        let status=PHPhotoLibrary.authorizationStatus(for:.readWrite)
        let identity=(localID ?? "none")+"|"+String(status.rawValue)+"|"+String(revision?.timeIntervalSince1970 ?? 0)+"|"+String(Double(targetSize))
        let coordinator=context.coordinator
        guard status == .authorized || status == .limited else {
            coordinator.manager.cancelImageRequest(coordinator.request);coordinator.token=UUID();coordinator.identity=nil;coordinator.displayedIdentity=nil;view.image=nil;return
        }
        guard scenePhase == .active else {
            coordinator.manager.cancelImageRequest(coordinator.request);coordinator.token=UUID();coordinator.identity=nil;return
        }
        guard identity != coordinator.identity else{return}
        coordinator.manager.cancelImageRequest(coordinator.request)
        coordinator.identity=identity;coordinator.token=UUID()
        if coordinator.displayedIdentity != identity{view.image=nil}
        let token=coordinator.token
        let asset:PHAsset?=(status == .authorized || status == .limited) ? localID.flatMap{PHAsset.fetchAssets(withLocalIdentifiers:[$0],options:nil).firstObject}:nil
        let binding=$captureDate
        DispatchQueue.main.async {if coordinator.token==token{binding.wrappedValue=asset?.creationDate}}
        guard let asset else{return}
        let options=PHImageRequestOptions();options.isNetworkAccessAllowed=false;options.deliveryMode = .opportunistic;options.resizeMode = .fast
        coordinator.request=coordinator.manager.requestImage(for:asset,targetSize:CGSize(width:targetSize,height:targetSize),contentMode:.aspectFill,options:options){[weak view,weak coordinator] image,_ in
            DispatchQueue.main.async {guard let coordinator,coordinator.token==token,let image else{return};coordinator.displayedIdentity=identity;view?.image=image}
        }
    }
    static func dismantleUIView(_ view:UIImageView,coordinator:Coordinator) {
        coordinator.token=UUID();coordinator.manager.cancelImageRequest(coordinator.request);view.image=nil
    }
}

// Transfer stages describe observed state only; a full byte bar never grants protection.
struct AcloudTransferProgress:View {
    let stages:[String]
    let stage:Int
    let bytes:Int
    let total:Int
    var activity="Waiting to start"
    var transferring=false
    var complete=false
    var stopped=false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.top,spacing:8) {
                ForEach(Array(stages.enumerated()),id:\.offset) { index,title in
                    VStack(spacing:5) {
                        Image(systemName:complete || index < stage ? "checkmark.circle.fill":index == stage ? "circle.inset.filled":"circle")
                            .foregroundStyle(complete || index <= stage ? AcloudStyle.accent:Color.secondary)
                        Text(title).font(.caption.weight(index == stage ? .semibold:.regular)).multilineTextAlignment(.center)
                    }.frame(maxWidth:.infinity)
                }
            }.accessibilityElement(children:.ignore)
             .accessibilityLabel(complete ? "Completed":stopped ? "Transfer stopped; completion unconfirmed":"Current stage: \(stages[min(max(stage,0),stages.count-1)])")
            if !complete {
                if transferring || stopped {
                    if total > 0 {
                        let fraction=min(1,max(0,Double(bytes)/Double(total)))
                        HStack {
                            Text("\(Int64(max(0,bytes)).formatted(.byteCount(style:.file))) of \(Int64(total).formatted(.byteCount(style:.file)))")
                            Spacer()
                            Text("\(Int(fraction*100))% transferred").monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                        ProgressView(value:fraction).accessibilityLabel("Bytes transferred").accessibilityValue("\(Int(fraction*100)) percent; completion unconfirmed")
                    } else {Text("Waiting for file size").font(.caption).foregroundStyle(.secondary)}
                } else {
                    HStack(spacing:10) {ProgressView();Text(activity).font(.caption).foregroundStyle(.secondary)}
                }
            }
        }.padding(12).background(AcloudStyle.accent.opacity(0.06),in:RoundedRectangle(cornerRadius:14))
    }
}

// Only verified upload bytes or a pinned, integrity-checked download can enter this cache.
typealias AcloudPreviewStore = VerifiedPreviewCache

struct AcloudPreviewPreparer:ResourcePreparer {
    let wrapped:any ResourcePreparer
    let queue:SQLiteBackupQueue
    let files:ManagedTemporaryFiles
    func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot)async throws->PreparedResource {try await wrapped.prepare(item,policy:policy,network:network)}
    func cleanup(_ item:BackupItem)async throws {
        // Re-read: the coordinator passes its pre-verification item to cleanup.
        if let verified=try? await queue.read(item.id),verified.state == .protected,
           let account=verified.accountID,let asset=verified.assetID,let checksum=verified.expectedChecksum,let size=verified.expectedSizeBytes,
           size>0,size<=BackupPreviewPolicy.maximumLocalBytes,["image","video"].contains(verified.mediaType) {
            if let data=try? await AcloudPreviewStore.shared.capture(file:files.url(item.id),account:account,asset:asset,checksum:checksum,size:size,mediaType:verified.mediaType) {
                await AcloudPreviewRegistry.shared.received(account:account,asset:asset,checksum:checksum,data:data)
            }
        }
        try await wrapped.cleanup(item)
    }
}

// Only fixed text and numeric status codes are shown; URLs and server error bodies stay private.
enum AcloudPreviewFailureMessage {
    static func describe(_ error:Error,step:String)->String {
        let reason:String
        if let failure=error as? RestoreFailure {
            switch failure {
            case .http(401),.http(403),.authorization,.disabled:reason="Preview access was refused. Sign in again or check test access."
            case .http(409):reason="This saved item is incomplete, has changed, or is not eligible for a thumbnail."
            case .http(let status):reason="The server returned HTTP \(status). Try again later."
            case .unsupported:reason="A thumbnail is unavailable for this file type or size."
            case .integrity,.versionChanged:reason="The saved file could not be verified. No preview was created."
            case .storage:reason="The app could not validate its temporary preview folder. No preview was created."
            default:reason="The saved preview could not be loaded."
            }
        } else if let failure=error as? AccountAPIError {
            switch failure {
            case .unauthorized:reason="Your sign-in has expired. Sign in again."
            case .invalidConfiguration:reason="The app could not confirm its staging configuration."
            case .requestFailed:reason="The account service could not confirm access. Try again later."
            }
        } else if let failure=error as? BackupFailure {
            switch failure {
            case .unsupported:reason="This saved file could not be decoded into a thumbnail. Your backup remains unchanged."
            case .sourceChanged:reason="The downloaded bytes did not match the saved version. No preview was created."
            default:reason="The thumbnail could not be created or saved on this device."
            }
        } else {
            let value=error as NSError
            if value.domain==NSURLErrorDomain {
                switch value.code {
                case NSURLErrorNotConnectedToInternet,NSURLErrorDataNotAllowed:reason="Downloads need an available Wi-Fi connection with Low Data Mode off."
                case NSURLErrorTimedOut:reason="The request timed out. Retry when your connection is stable."
                case NSURLErrorNetworkConnectionLost:reason="The connection was interrupted. Tap to retry."
                default:reason="A network request failed (code \(value.code))."
                }
            } else if value.domain==NSCocoaErrorDomain {reason="The device could not read or save the temporary preview file (code \(value.code))."}
            else {reason="The saved file could not be processed on this device."}
        }
        return "Failed while \(step). \(reason)"
    }
}

@MainActor final class AcloudPreviewLoader:ObservableObject {
    @Published var data:Data?
    @Published var loading=false
    @Published var message:String?
    @Published var previewBytes=0
    @Published var previewSize=0
    @Published var previewStage=""
    private static var downloadBusy=false
    private static var thumbnailRequests=0
    private var thumbnailRetryAt:Date?
    private var activeDownload:FileRestoreDownloader?
    private var generation=UUID()
    func invalidate(){generation=UUID();data=nil;loading=false;message=nil;previewBytes=0;previewSize=0;previewStage="";thumbnailRetryAt=nil;if let activeDownload{Task{await activeDownload.cancel()}};activeDownload=nil}
    func cancelPreview(){invalidate();message="Preview loading cancelled. Your saved backup is unchanged."}
    private func connection(account:UUID,wifiOnly:Bool=false)async throws->HTTPRestoreAPI {
        guard BetaReleaseSafety.acceptedConfiguration,let value=Bundle.main.object(forInfoDictionaryKey:"APIBaseURL") as? String,let base=URL(string:value) else{throw RestoreFailure.authorization}
        let tokens=KeychainSessionStore(service:(Bundle.main.bundleIdentifier ?? "com.example.backupclient")+".session")
        guard UUID(uuidString:try await AuthAPI(baseURL:base,store:tokens).me().id)==account else{throw RestoreFailure.authorization}
        return try HTTPRestoreAPI(base:base,tokens:tokens,allowLocalHTTP:_isDebugAssertConfiguration(),wifiOnly:wifiOnly)
    }
    func load(account:UUID,asset:UUID,checksum:String?,download:Bool=false)async {
        if !download{while loading{do{try await Task.sleep(for:.milliseconds(100))}catch{return}}}
        guard !loading else{return};if !download,data != nil{return};let epoch=generation;loading=true;defer{if epoch==generation{loading=false}}
        var step="checking access"
        if download {message=nil;previewBytes=0;previewSize=0;previewStage="Checking access"}
        do {
            if let checksum,!download {
                let cached=try await AcloudPreviewStore.shared.cached(account:account,asset:asset,checksum:checksum)
                try Task.checkCancellation();guard epoch==generation else{return};if let cached{data=cached;return}
            }
            if !download,let retry=thumbnailRetryAt,Date()<retry{return}
            while Self.thumbnailRequests>=3{try await Task.sleep(for:.milliseconds(200));guard epoch==generation else{return}}
            do {
                Self.thumbnailRequests+=1;defer{Self.thumbnailRequests-=1}
                thumbnailRetryAt=Date().addingTimeInterval(10);previewStage="Loading small thumbnail"
                let thumbnailAPI=try await connection(account:account,wifiOnly:true)
                let thumbnail=try await thumbnailAPI.thumbnail(asset)
                let bytes=try thumbnail.verifiedBytes(asset:asset,sourceChecksum:checksum)
                try Task.checkCancellation();guard epoch==generation else{return}
                try await AcloudPreviewStore.shared.storeThumbnail(bytes,account:account,asset:asset,checksum:thumbnail.sourceSha256)
                guard epoch==generation else{return};data=bytes;message=nil;return
            }catch RestoreFailure.http(404){
                thumbnailRetryAt=Date().addingTimeInterval(60)
                if !download{message="No small thumbnail is saved yet. You can explicitly load the saved original over Wi-Fi.";return}
            }
            guard download else{return}
            let api=try await connection(account:account)
            step="checking the saved file"
            let proof=try await api.previewEvidence(asset)
            previewSize=proof.expectedSize
            guard proof.id==asset,proof.previewSupported,checksum==nil || checksum==proof.expectedSha256 else{throw RestoreFailure.versionChanged}
            if let cached=try await AcloudPreviewStore.shared.cached(account:account,asset:asset,checksum:proof.expectedSha256) {try Task.checkCancellation();guard epoch==generation else{return};data=cached;return}
            guard download else{return}
            guard epoch==generation else{return}
            guard proof.expectedSize<=BackupPreviewPolicy.maximumDownloadBytes else{message="This original is too large for preview loading. New backups capture a thumbnail on this device.";return}
            guard let value=Bundle.main.object(forInfoDictionaryKey:"StorageOrigin") as? String,let origin=URL(string:value) else{throw RestoreFailure.authorization}
            guard !Self.downloadBusy else{message="Another saved preview is loading. Try again when it finishes.";return}
            Self.downloadBusy=true;defer{Self.downloadBusy=false;activeDownload=nil}
            step="requesting download access"
            let authorization=try await api.previewAuthorize(proof)
            guard authorization.evidence==proof else{throw RestoreFailure.versionChanged}
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("Preview-"+UUID().uuidString,isDirectory:true)
            let files=try RestoreFiles(directory:directory),id=UUID()
            defer{try? FileManager.default.removeItem(at:directory)}
            guard epoch==generation else{return}
            let downloader=try FileRestoreDownloader(origin:origin,allowLocalHTTP:_isDebugAssertConfiguration());activeDownload=downloader
            step="downloading the saved file";previewStage="Downloading saved file"
            try await downloader.download(authorization.authorization,to:files.url(id),expectedSize:proof.expectedSize,progress:{[weak self] count in Task{@MainActor in guard let self,self.generation==epoch else{return};self.previewBytes=count}})
            step="verifying the downloaded file";previewStage="Verifying saved file"
            try files.verify(RestoreItem(accountID:account,libraryID:UUID(),evidence:proof,id:id))
            step="confirming the saved version"
            guard try await api.previewRecheck(proof)==proof else{throw RestoreFailure.versionChanged}
            _=try await connection(account:account);try Task.checkCancellation()
            step="creating the thumbnail";previewStage="Creating preview"
            let preview=try await AcloudPreviewStore.shared.capture(file:files.url(id),account:account,asset:asset,checksum:proof.expectedSha256,size:proof.expectedSize,mediaType:proof.mediaType)
            try Task.checkCancellation();guard epoch==generation else{return};data=preview;message=nil
            try? await api.saveThumbnail(proof,data:preview)
        } catch is CancellationError {return}
        catch {
            guard epoch==generation else{return}
            message=AcloudPreviewFailureMessage.describe(error,step:step)
        }
    }
}

// Both controls observe the same account/asset-scoped loader within one row.
private struct AcloudSavedThumbnail:View {
    let account:UUID,asset:UUID
    let checksum:String?
    @ObservedObject private var registry=AcloudPreviewRegistry.shared
    var body:some View {AcloudSavedThumbnailContent(loader:registry.loader(account:account,asset:asset,checksum:checksum),account:account,asset:asset,checksum:checksum)}
}
private struct AcloudSavedThumbnailContent:View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var loader:AcloudPreviewLoader
    let account:UUID,asset:UUID
    let checksum:String?
    var body:some View {
        AcloudPreviewImage(loader:loader).task(id:account.uuidString+asset.uuidString+(checksum ?? "")+String(describing:scenePhase)){if scenePhase == .active{await loader.load(account:account,asset:asset,checksum:checksum)}}
    }
}
struct AcloudPreviewImage:View {
    @ObservedObject var loader:AcloudPreviewLoader
    var side:CGFloat=76
    var body:some View {
        // Keep a real view mounted while the disk read starts; EmptyView can prevent a gallery .task from running.
        ZStack {
            Color.clear
            if let data=loader.data,let image=UIImage(data:data) {Image(uiImage:image).resizable().scaledToFill()}
        }.frame(width:side,height:side).clipped().clipShape(RoundedRectangle(cornerRadius:12))
    }
}
@MainActor final class AcloudPreviewRegistry:ObservableObject {
    static let shared=AcloudPreviewRegistry()
    private var loaders:[String:AcloudPreviewLoader]=[:]
    func loader(account:UUID,asset:UUID,checksum:String?)->AcloudPreviewLoader {
        let key=account.uuidString+asset.uuidString+(checksum ?? "")
        if let loader=loaders[key]{return loader}
        if loaders.count>=256,let oldest=loaders.keys.sorted().first {loaders.removeValue(forKey:oldest)?.invalidate()}
        let loader=AcloudPreviewLoader();loaders[key]=loader;return loader
    }
    func received(account:UUID,asset:UUID,checksum:String,data:Data) {
        loaders[account.uuidString+asset.uuidString+checksum]?.data=data
    }
    func clear(){AcloudThumbnailPublisher.clear();for loader in loaders.values{loader.invalidate()};loaders=[:]}
}
private struct AcloudSavedPreviewControl:View {
    let account:UUID,asset:UUID
    let checksum:String?
    var body:some View {AcloudPreviewControl(loader:AcloudPreviewRegistry.shared.loader(account:account,asset:asset,checksum:checksum),account:account,asset:asset,checksum:checksum)}
}
private struct AcloudPreviewControl:View {
    @ObservedObject var loader:AcloudPreviewLoader
    let account:UUID,asset:UUID
    let checksum:String?
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            if loader.data==nil {
                if loader.loading {AcloudPreviewProgress(loader:loader)}
                else {Button("Load saved thumbnail over Wi-Fi"){Task{await loader.load(account:account,asset:asset,checksum:checksum,download:true)}}.font(.caption).buttonStyle(.borderless)}
                Text(loader.message ?? "Small saved thumbnails load automatically over Wi-Fi and are cached on this device. Older backups may need an explicit original download. Nothing is added to Photos.").font(.caption2).foregroundStyle(.secondary)
            }
        }.task {await loader.load(account:account,asset:asset,checksum:checksum)}
    }
}

// Display-only controls. These never authorize a download or modify Photos.
struct AcloudPreviewProgress:View {
 @ObservedObject var loader:AcloudPreviewLoader
 var body:some View {VStack(alignment:.leading,spacing:8){
  if loader.previewSize>0 {ProgressView(loader.previewStage.isEmpty ? "Loading saved preview":loader.previewStage,value:Double(loader.previewBytes),total:Double(loader.previewSize));Text("\(Int64(loader.previewBytes).formatted(.byteCount(style:.file))) of \(Int64(loader.previewSize).formatted(.byteCount(style:.file)))").font(.caption).foregroundStyle(.secondary)}
  else{ProgressView("Checking saved preview…")}
  Button("Cancel preview"){loader.cancelPreview()}.font(.caption)
 }}
}
struct AcloudZoomableImage:View {
 let image:UIImage
 @State private var scale:CGFloat=1
 @State private var savedScale:CGFloat=1
 @State private var offset:CGSize = .zero
 @State private var savedOffset:CGSize = .zero
 var body:some View {Image(uiImage:image).resizable().scaledToFit().scaleEffect(scale).offset(offset)
  .simultaneousGesture(DragGesture().onChanged{value in if scale>1 {offset=CGSize(width:savedOffset.width+value.translation.width,height:savedOffset.height+value.translation.height)}}.onEnded{_ in savedOffset=offset})
  .gesture(MagnificationGesture().onChanged{value in scale=min(5,max(1,savedScale*value))}.onEnded{_ in savedScale=scale;if scale==1{offset = .zero;savedOffset = .zero}})
  .onTapGesture(count:2){scale=scale>1 ? 1:2;savedScale=scale;if scale==1 {offset = .zero;savedOffset = .zero}}
  .accessibilityLabel("Photo preview")
  .accessibilityHint("Pinch or double tap to zoom. Double tap again to reset.")
  .accessibilityAction(named:"Reset zoom"){scale=1;savedScale=1;offset = .zero;savedOffset = .zero}
  .clipped()
 }
}
func acloudCapacity<T:BinaryInteger>(_ bytes:T)->String {
 let value=max(0,Double(bytes)),units=["B","KiB","MiB","GiB","TiB"]
 let unit=value>0 ? min(4,Int(log(value)/log(1024))):0
 return (value/pow(1024,Double(unit))).formatted(.number.precision(.fractionLength(unit==0 ? 0:1)))+" "+units[unit]
}

// Derived-preview sync is opportunistic and never owns or advances backup work.
@MainActor enum AcloudThumbnailPublisher {
    private static var worker:Task<Void,Never>?
    private static var epoch=UUID()
    private static var stored=Set<String>()
    private static var attempted:[String:Date]=[:]
    static func clear(){epoch=UUID();worker?.cancel();worker=nil;stored=[];attempted=[:]}
    static func sync(account:UUID,entries:[(UUID,String)]) {
        guard worker==nil,!entries.isEmpty else{return};let generation=epoch
        worker=Task {
            defer{if generation==epoch{worker=nil}}
            guard BetaReleaseSafety.acceptedConfiguration,let value=Bundle.main.object(forInfoDictionaryKey:"APIBaseURL") as? String,let base=URL(string:value) else{return}
            let tokens=KeychainSessionStore(service:(Bundle.main.bundleIdentifier ?? "com.example.backupclient")+".session")
            guard let user=try? await AuthAPI(baseURL:base,store:tokens).me(),UUID(uuidString:user.id)==account,
                  let api=try? HTTPRestoreAPI(base:base,tokens:tokens,allowLocalHTTP:_isDebugAssertConfiguration(),wifiOnly:true) else{return}
            var count=0
            for (asset,checksum) in entries {
                guard !Task.isCancelled,generation==epoch else{return}
                let key=account.uuidString+asset.uuidString+checksum
                guard !stored.contains(key),attempted[key].map({Date().timeIntervalSince($0)>60}) ?? true else{continue}
                guard let bytes=try? await AcloudPreviewStore.shared.cached(account:account,asset:asset,checksum:checksum),bytes.count<=40*1024 else{continue}
                attempted[key]=Date();count+=1
                do {
                    let bytes=try PreviewJPEG.withoutMetadata(bytes)
                    let proof=try await api.thumbnailEvidence(asset)
                    guard proof.id==asset,proof.expectedSha256==checksum,generation==epoch,!Task.isCancelled else{continue}
                    try await api.saveThumbnail(proof,data:bytes)
                    guard generation==epoch else{return};stored.insert(key)
                    if stored.count>512{stored=[key]};if attempted.count>512{attempted=[key:Date()]}
                }catch{} // Optional derivative failure cannot fail a protected original.
                if count>=4{return}
            }
        }
    }
}
