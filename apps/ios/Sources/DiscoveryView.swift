import SwiftUI
import UIKit
import DiscoveryCore
import PhotoKitDiscovery
import Photos
import AVKit

@MainActor final class DiscoveryViewModel: ObservableObject {
    @Published private(set) var authorization: LibraryAuthorization = .notDetermined
    @Published private(set) var summary: DiscoverySummary?
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var status = "Not scanned"
    @Published private(set) var scanning = false
    @Published private(set) var gallery:[AcloudGalleryEntry]=[]
    @Published private(set) var galleryTotal=0
    @Published private(set) var galleryLoading=false
    private let galleryStore=AcloudDeviceGalleryStore()
    private var galleryGeneration=UUID()
    private var galleryOrder:AcloudGalleryOrder = .newest
    func accessibleSelection(_ ids:Set<String>)async->Set<String>{
        guard ids.count<=BackupSelectionPolicy.maximum,authorization.canRead else{return []}
        return await galleryStore.accessibleIDs(ids)
    }
    func sortGallery(_ order:AcloudGalleryOrder){galleryOrder=order;Task{await reloadGallery()}}
    private func reloadGallery()async {
        galleryGeneration=UUID();let epoch=galleryGeneration
        guard authorization.canRead else{gallery=[];galleryTotal=0;galleryLoading=false;return}
        let retainedCount=max(200,gallery.count)
        galleryLoading=true;defer{if galleryGeneration==epoch{galleryLoading=false}}
        let page=await galleryStore.page(order:galleryOrder,offset:0,reload:true,limit:retainedCount)
        guard galleryGeneration==epoch,authorization.canRead else{return}
        gallery=page.items;galleryTotal=page.total
    }
    func loadMorePhotos()async {
        guard authorization.canRead,!galleryLoading else{return}
        let epoch=galleryGeneration,start=gallery.count
        galleryLoading=true;defer{if galleryGeneration==epoch{galleryLoading=false}}
        let page=await galleryStore.page(order:galleryOrder,offset:start,reload:false)
        guard epoch==galleryGeneration,gallery.count==start,authorization.canRead else{return}
        gallery += page.items;galleryTotal=page.total
    }
    private let library = PhotoKitLibrary()
    private var scanner: PhotoLibraryScanner?
    private var scanTask: Task<Void,Never>?
    private var active = false
    private var pendingRescan = false
    private var initialized = false
    private var initialization: Task<SQLiteDiscoveredAssetStore,Error>?
    func activate() async {
        active = true
        // Browsing must not depend on the optional scan database opening successfully.
        await refresh(libraryChanged:false)
        do {
            if !initialized {
                // Opening/migrating SQLite is off the main actor.
                if initialization == nil {
                    initialization = Task.detached {
                        try SQLiteDiscoveredAssetStore(url:SQLiteDiscoveredAssetStore.applicationStoreURL())
                    }
                }
                guard let initialization else { return }
                let store = try await initialization.value
                if !initialized {
                    scanner = PhotoLibraryScanner(library:library,store:store)
                    initialized = true
                    await library.setChangeHandler { [weak self] in Task { @MainActor in await self?.refresh() } }
                }
                self.initialization = nil
            }
            if pendingRescan { start() }
        } catch { initialization = nil; status = "Local discovery storage unavailable. Unlock the device and try again." }
    }
    func deactivate() { active = false; pendingRescan = false; scanTask?.cancel() }
    func allowAccess() async {
        guard authorization == .notDetermined else { return }
        authorization = await library.requestAccess()
        await refresh()
    }
    func refresh(libraryChanged:Bool=true) async {
        // Revalidate visible membership synchronously before retaining device content.
        // Limited-access membership can change without changing the permission enum.
        let previous=authorization
        let accessStatus=PHPhotoLibrary.authorizationStatus(for:.readWrite)
        switch accessStatus {
        case .authorized:authorization = .authorized
        case .limited:authorization = .limited
        case .denied:authorization = .denied
        case .notDetermined:authorization = .notDetermined
        default:authorization = .restricted
        }
        let visibleIDs=Set(gallery.map(\.id))
        let accessible: Set<String>
        if authorization.canRead,!visibleIDs.isEmpty {
            let fetch=PHAsset.fetchAssets(withLocalIdentifiers:Array(visibleIDs),options:nil)
            var ids=Set<String>();fetch.enumerateObjects{asset,_,_ in ids.insert(asset.localIdentifier)}
            accessible=ids
        }else{accessible=[]}
        let retained=DiscoveryRefreshPolicy.retainedIDs(authorization:authorization,visible:visibleIDs,accessible:accessible)
        gallery.removeAll{!retained.contains($0.id)}
        let membershipChanged=retained != visibleIDs
        let changed=libraryChanged || previous != authorization || membershipChanged
        if changed || !authorization.canRead{summary=nil;progress=nil}
        if !authorization.canRead{galleryTotal=0}
        await reloadGallery()
        if changed{await library.invalidateSnapshots()}
        pendingRescan = active && authorization.canRead && (changed || summary == nil)
        if let scanTask { scanTask.cancel(); return }
        if pendingRescan { start() }
        else if !authorization.canRead {
            try? await scanner?.invalidateAccess()
            status = "Photo access unavailable"
        }
    }
    func start() {
        guard active, authorization.canRead, let scanner, scanTask == nil else { return }
        pendingRescan = false; scanning = true; summary = nil; status = "Scanning"
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await scanner.run { [weak self] value in
                    await MainActor.run {
                        guard let self, !self.pendingRescan, self.active, self.authorization.canRead else { return }
                        self.progress = value
                    }
                }
                // Never display counts from a permission/snapshot superseded by refresh.
                if !pendingRescan, active {
                    switch outcome {
                    case .complete(let value): summary = value; status = "Complete"
                    case .cancelled(let value): summary = value; status = "Cancelled — partial results"
                    case .libraryChanged: summary = nil; pendingRescan = true; status = "Library changed; refreshing"
                    case .noAccess(let value): summary = nil; authorization = value; status = "Photo access unavailable"
                    }
                }
            } catch { summary = nil; status = "Scan unavailable. Try again after unlocking the device." }
            scanning = false; scanTask = nil
            if pendingRescan && active { await refresh() }
            else if !authorization.canRead { try? await scanner.invalidateAccess() }
        }
    }
    func cancel() { pendingRescan = false; scanTask?.cancel() }
}

private struct LimitedAccessPicker: UIViewControllerRepresentable {
    let completed: @MainActor @Sendable () -> Void
    func makeUIViewController(context: Context) -> PickerController { PickerController(completed:completed) }
    func updateUIViewController(_ uiViewController: PickerController, context: Context) {}
    final class PickerController: UIViewController {
        private let completed: @MainActor @Sendable () -> Void
        private var presented = false
        init(completed: @escaping @MainActor @Sendable () -> Void) { self.completed = completed; super.init(nibName:nil,bundle:nil) }
        required init?(coder: NSCoder) { fatalError("Unavailable") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }; presented = true
            PhotoLibraryAccessUI.manageLimitedAccess(from:self,completion:completed)
        }
    }
}


struct DiscoveryView: View {
    @StateObject private var model=DiscoveryViewModel()
    @ObservedObject private var backup=BackupQueueModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("selectedTransferTab") private var selectedTab="library"
    @State private var managingAccess=false
    @State private var selecting=false
    @State private var selected=Set<String>()
    @State private var filter:AcloudGalleryFilter = .all
    @State private var order:AcloudGalleryOrder = .newest
    @State private var size:AcloudGallerySize = .medium
    @State private var viewer:AcloudGalleryPresentation?
    @State private var notice:String?
    private var visible:[AcloudGalleryEntry]{model.gallery.filter{filter.includes($0)}}
    var body:some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment:.leading,spacing:18) {
                    AcloudHero(icon:"photo.on.rectangle",eyebrow:"On your device",title:"Your library. Your choice.",message:"See the photos and videos you allow Acloud to access. Scanning your library never uploads or deletes an original.")
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text("On this device").font(.title2.bold())
                            Text("Browse your Photos library. Back up only what you choose.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.authorization.canRead {Button(selecting ? "Done":"Select"){selecting.toggle()}.buttonStyle(.bordered)}
                    }
                    accessControls
                    if model.authorization.canRead {
                        AcloudGalleryControls(filter:$filter,order:$order,size:$size)
                        if selecting {
                            HStack {
                                Text("\(selected.count) of 10 selected").font(.headline)
                                Spacer()
                                Button("Select up to 10"){selected=Set(visible.prefix(10).map(\.id))}
                                Button("Clear"){selected=[]}.disabled(selected.isEmpty)
                            }.font(.subheadline)
                        }
                        if model.galleryLoading && visible.isEmpty {ProgressView("Loading photos…")}
                        else if visible.isEmpty {ContentUnavailableView("No matching items",systemImage:"photo.on.rectangle",description:Text("Try another media filter or load more photos."))}
                        AcloudGalleryGrid(items:visible,order:order,size:size,selecting:selecting,selected:selected,onSelect:select,onOpen:{entry in viewer=AcloudGalleryPresentation(items:visible,startID:entry.id)})
                        HStack {
                            Text("\(model.gallery.count.formatted()) of \(model.galleryTotal.formatted()) accessible items loaded").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if model.gallery.count<model.galleryTotal {Button("Load more"){Task{await model.loadMorePhotos()}}.disabled(model.galleryLoading)}
                        }
                        Text("Device previews stay local. iCloud-only originals are not downloaded for browsing.").font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Library scan details") {
                            if let summary=model.summary {Text("\(summary.images.formatted()) photos · \(summary.videos.formatted()) videos")}
                            if model.scanning,let progress=model.progress {ProgressView(value:Double(progress.processed),total:Double(max(1,progress.total)));Text("\(progress.processed.formatted()) of \(progress.total.formatted()) scanned")}
                            Text(model.status).font(.caption)
                            Button(model.scanning ? "Cancel scan":"Scan again"){if model.scanning{model.cancel()}else{model.start()}}
                        }.font(.subheadline)
                    }
                }.padding()
            }.background(AcloudStyle.canvas).navigationTitle("Library")
             .toolbar{ToolbarItem(placement:.topBarTrailing){Button{Task{await model.refresh()}}label:{Image(systemName:"arrow.clockwise")}.accessibilityLabel("Refresh library")}}
             .safeAreaInset(edge:.bottom) {
                if selecting || !selected.isEmpty {
                    HStack {
                        Button("Cancel"){selected=[];selecting=false}
                        Spacer()
                        Button{let ids=model.gallery.filter{selected.contains($0.id)}.map(\.id);Task{await backup.refresh();await backup.enqueueSelected(ids);notice=backup.selectionNotice ?? backup.message}}label:{Label("Back up \(selected.count) selected",systemImage:"icloud.and.arrow.up")}
                            .buttonStyle(.borderedProminent).disabled(selected.isEmpty || backup.busy)
                    }.padding().background(.regularMaterial)
                }
             }
        }
        .task{await model.activate()}
        .onChange(of:order){_,value in model.sortGallery(value)}
         .onChange(of:model.galleryLoading){_,loading in if !loading{reconcileSelection()}}
        .onChange(of:model.authorization){_,access in if !access.canRead{selected=[];viewer=nil}}
        .onChange(of:model.gallery.map(\.id)){_,ids in
            guard let viewer else{return}
            if !Set(viewer.items.map(\.id)).isSubset(of:Set(ids)){self.viewer=nil}
        }
        .onChange(of:scenePhase){_,phase in if phase == .active{Task{await model.activate()}}else{model.deactivate()}}
        .sheet(isPresented:$managingAccess,onDismiss:{Task{await model.refresh()}}){LimitedAccessPicker{managingAccess=false}}
        .sheet(item:$viewer){presentation in AcloudGalleryViewer(items:presentation.items,startID:presentation.startID)}
        .alert("Backup selection",isPresented:Binding(get:{notice != nil},set:{if !$0{notice=nil}})){Button("OK"){notice=nil};Button("View transfers"){UserDefaults.standard.set("transfers",forKey:"backupBrowserMode");selectedTab="backup";notice=nil}}message:{Text(notice ?? "")}
    }
    private func reconcileSelection(){
        guard !selected.isEmpty else{return}
        let before=selected
        Task{let allowed=await model.accessibleSelection(before);guard selected==before else{return};selected=allowed}
    }
    private func select(_ entry:AcloudGalleryEntry){
        if selected.contains(entry.id){selected.remove(entry.id)}
        else if selected.count<BackupSelectionPolicy.maximum{selected.insert(entry.id)}
        else{notice="Select up to 10 photos or videos per backup batch."}
    }
    @ViewBuilder private var accessControls:some View {
        switch model.authorization {
        case .notDetermined:Button("Allow photo access"){Task{await model.allowAccess()}}.buttonStyle(.borderedProminent)
        case .denied,.restricted:
            Text("Allow Photos access in Settings to browse your library.").foregroundStyle(.secondary)
            settingsButton
        case .limited:
            HStack{Label("Selected Photos access",systemImage:"photo.badge.checkmark");Spacer();Button("Manage"){managingAccess=true}}.font(.subheadline)
        case .authorized:EmptyView()
        }
    }
    private var settingsButton:some View {Button("Open Settings"){if let url=URL(string:UIApplication.openSettingsURLString){UIApplication.shared.open(url)}}}
}

struct AcloudGalleryEntry:Identifiable,Sendable {
    let id:String
    let type:String
    let date:Date?
    var duration:Double?=nil
    var live=false
    var localID:String?=nil
    var revision:Date?=nil
    var account:UUID?=nil
    var asset:UUID?=nil
    var checksum:String?=nil
}
struct AcloudGalleryPresentation:Identifiable {
    let id=UUID()
    let items:[AcloudGalleryEntry]
    let startID:String
}
enum AcloudGalleryOrder:String,CaseIterable,Sendable {case newest="Newest first",oldest="Oldest first"}
enum AcloudGallerySize:String,CaseIterable {
    case small="Small",medium="Medium",large="Large"
    var width:CGFloat{switch self{case .small:return 100;case .medium:return 150;case .large:return 220}}
}
enum AcloudGalleryFilter:String,CaseIterable {
    case all="All",photos="Photos",videos="Videos",live="Live Photos"
    func includes(_ entry:AcloudGalleryEntry)->Bool {switch self{case .all:return true;case .photos:return entry.type=="image";case .videos:return entry.type=="video";case .live:return entry.live}}
}
struct AcloudGalleryControls:View {
    @Binding var filter:AcloudGalleryFilter
    @Binding var order:AcloudGalleryOrder
    @Binding var size:AcloudGallerySize
    var includeLivePhotos=true
    var body:some View {
        VStack(spacing:12) {
            Picker("Media type",selection:$filter){ForEach(AcloudGalleryFilter.allCases.filter{includeLivePhotos || $0 != .live},id:\.self){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
            HStack {
                Picker("Sort by date",selection:$order){ForEach(AcloudGalleryOrder.allCases,id:\.self){Text($0.rawValue).tag($0)}}.pickerStyle(.menu)
                Spacer()
                Menu {Picker("Thumbnail size",selection:$size){ForEach(AcloudGallerySize.allCases,id:\.self){Text($0.rawValue).tag($0)}}}label:{Label("Size",systemImage:"square.grid.3x3")}
            }.font(.subheadline)
        }
    }
}
struct AcloudGalleryGrid:View {
    let items:[AcloudGalleryEntry]
    let order:AcloudGalleryOrder
    let size:AcloudGallerySize
    var selecting=false
    var selected=Set<String>()
    let onSelect:(AcloudGalleryEntry)->Void
    let onOpen:(AcloudGalleryEntry)->Void
    private var days:[Date]{Set(items.map{$0.date.map{Calendar.current.startOfDay(for:$0)} ?? .distantPast}).sorted{if $0 == .distantPast{return false};if $1 == .distantPast{return true};return order == .newest ? $0>$1:$0<$1}}
    var body:some View {
        ForEach(days,id:\.self){day in
            VStack(alignment:.leading,spacing:8) {
                Text(day == .distantPast ? "Date unavailable":day.formatted(.dateTime.month(.wide).day().year())).font(.headline).padding(.top,8)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:size.width),spacing:5)],spacing:5) {
                    ForEach(items.filter{($0.date.map{Calendar.current.startOfDay(for:$0)} ?? .distantPast)==day}){entry in
                        Button{if selecting{onSelect(entry)}else{onOpen(entry)}}label:{AcloudGalleryTile(entry:entry,selecting:selecting,selected:selected.contains(entry.id))}
                            .buttonStyle(.plain)
                            .disabled(selecting && selected.count>=10 && !selected.contains(entry.id))
                            .accessibilityLabel("\(entry.live ? "Live Photo":entry.type == "video" ? "Video":"Photo"), \(entry.date?.formatted(date:.abbreviated,time:.shortened) ?? "date unavailable")")
                            .accessibilityHint(selecting ? "Tap to select or deselect":"Tap to view")
                            .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected:[])
                    }
                }
            }
        }
    }
}
private struct AcloudGalleryTile:View {
    let entry:AcloudGalleryEntry
    let selecting:Bool
    let selected:Bool
    @State private var capturedAt:Date?
    var body:some View {
        GeometryReader{geometry in
            ZStack {
                Rectangle().fill(AcloudStyle.accent.opacity(0.10))
                Image(systemName:entry.type == "video" ? "video.fill":"photo.fill").foregroundStyle(AcloudStyle.accent).font(.title)
                if let local=entry.localID {AcloudLocalThumbnail(localID:local,captureDate:$capturedAt,revision:entry.revision).frame(width:geometry.size.width,height:geometry.size.width).id(local)}
                else if let account=entry.account,let asset=entry.asset {AcloudGallerySavedImage(account:account,asset:asset,checksum:entry.checksum,side:geometry.size.width)}
                VStack {
                    HStack {Spacer();if selecting {Image(systemName:selected ? "checkmark.circle.fill":"circle").font(.title2).foregroundStyle(.white).padding(3).background(selected ? AcloudStyle.accent:Color.black.opacity(0.3),in:Circle()).padding(6)}}
                    Spacer()
                    HStack {
                        if entry.live{Label("LIVE",systemImage:"livephoto").font(.caption2.bold())}
                        if entry.type == "video" {Label(entry.duration.map{String(format:"%d:%02d",Int($0)/60,Int($0)%60)} ?? "Video",systemImage:"play.fill").font(.caption.bold())}
                        Spacer()
                    }.foregroundStyle(.white).padding(7).background(entry.type == "video" || entry.live ? Color.black.opacity(0.5):Color.clear)
                }
            }.frame(width:geometry.size.width,height:geometry.size.width).clipped().clipShape(RoundedRectangle(cornerRadius:8))
             .overlay{RoundedRectangle(cornerRadius:8).strokeBorder(selected ? AcloudStyle.accent:Color.clear,lineWidth:4)}
        }.aspectRatio(1,contentMode:.fit)
    }
}
private struct AcloudGallerySavedImage:View {
    let account:UUID,asset:UUID
    let checksum:String?
    let side:CGFloat
    var body:some View {AcloudGallerySavedImageContent(loader:AcloudPreviewRegistry.shared.loader(account:account,asset:asset,checksum:checksum),account:account,asset:asset,checksum:checksum,side:side)}
}
private struct AcloudGallerySavedImageContent:View {
    @ObservedObject var loader:AcloudPreviewLoader
    let account:UUID,asset:UUID
    let checksum:String?
    let side:CGFloat
    var body:some View {AcloudPreviewImage(loader:loader,side:side).task{await loader.load(account:account,asset:asset,checksum:checksum)}}
}
struct AcloudGalleryViewer:View {
    let items:[AcloudGalleryEntry]
    @State private var index:Int
    @Environment(\.dismiss) private var dismiss
    init(items:[AcloudGalleryEntry],startID:String){self.items=items;_index=State(initialValue:items.firstIndex{$0.id==startID} ?? 0)}
    var body:some View {
        NavigationStack {
            VStack(spacing:12) {
                if !items.isEmpty {
                    TabView(selection:$index){ForEach(Array(items.enumerated()),id:\.element.id){offset,entry in AcloudGalleryViewerPage(entry:entry).tag(offset)}}.tabViewStyle(.page(indexDisplayMode:.never))
                    HStack {
                        Button{index=max(0,index-1)}label:{Image(systemName:"chevron.left")}.disabled(index==0).accessibilityLabel("Previous item")
                        Spacer()
                        Text("\(index+1) of \(items.count)").font(.subheadline).monospacedDigit()
                        Spacer()
                        Button{index=min(items.count-1,index+1)}label:{Image(systemName:"chevron.right")}.disabled(index==items.count-1).accessibilityLabel("Next item")
                    }.padding()
                }
            }.navigationTitle("Media viewer").navigationBarTitleDisplayMode(.inline)
             .toolbar{ToolbarItem(placement:.topBarTrailing){Button("Done"){dismiss()}}}
        }
    }
}
private struct AcloudGalleryViewerPage:View {
    let entry:AcloudGalleryEntry
    var body:some View {
        VStack(spacing:12) {
            if let local=entry.localID {AcloudDeviceViewer(localID:local,type:entry.type).id(local)}
            else if let account=entry.account,let asset=entry.asset {AcloudSavedViewer(account:account,asset:asset,checksum:entry.checksum,type:entry.type)}
            else {ContentUnavailableView("Preview unavailable",systemImage:"photo")}
            Text(entry.localID != nil ? "Current device version":"Saved backup version").font(.headline)
            if let date=entry.date{Text(date.formatted(date:.long,time:.shortened)).font(.subheadline).foregroundStyle(.secondary)}
        }.padding()
    }
}
@MainActor private final class AcloudDeviceViewerModel:ObservableObject {
    @Published var image:UIImage?
    @Published var player:AVPlayer?
    @Published var message="Loading device preview…"
    private var request:PHImageRequestID=PHInvalidImageRequestID
    private var generation=UUID()
    func stop(){generation=UUID();PHImageManager.default().cancelImageRequest(request);player?.pause();player=nil;image=nil}
    func load(_ id:String,type:String){
        stop();let epoch=generation,status=PHPhotoLibrary.authorizationStatus(for:.readWrite)
        guard status == .authorized || status == .limited,let asset=PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject else{message="This item is no longer accessible. Check Photos access.";return}
        message="Loading device preview…"
        if type=="video" {
            let options=PHVideoRequestOptions();options.isNetworkAccessAllowed=false
            request=PHImageManager.default().requestAVAsset(forVideo:asset,options:options){[weak self] asset,_,_ in
                Task{@MainActor in guard let self,self.generation==epoch else{return};if let asset=asset as? AVURLAsset,asset.url.isFileURL{self.player=AVPlayer(playerItem:AVPlayerItem(asset:asset));self.message=""}else{self.message="This video cannot be previewed here. Open it in Photos; iCloud-only originals may need downloading first."}}
            }
        } else {
            let options=PHImageRequestOptions();options.isNetworkAccessAllowed=false;options.deliveryMode = .highQualityFormat;options.resizeMode = .fast
            request=PHImageManager.default().requestImage(for:asset,targetSize:CGSize(width:1600,height:1600),contentMode:.aspectFit,options:options){[weak self] image,_ in
                Task{@MainActor in guard let self,self.generation==epoch else{return};self.image=image;self.message=image == nil ? "This preview is unavailable. If its original is in iCloud, open it in Photos to download first.":""}
            }
        }
    }
}
private struct AcloudDeviceViewer:View {
    let localID:String,type:String
    @StateObject private var model=AcloudDeviceViewerModel()
    @Environment(\.scenePhase) private var scenePhase
    var body:some View {
        Group {
            if let player=model.player{VideoPlayer(player:player)}
            else if let image=model.image{Image(uiImage:image).resizable().scaledToFit()}
            else{ContentUnavailableView("Device preview",systemImage:type=="video" ? "video":"photo",description:Text(model.message))}
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
         .onAppear{model.load(localID,type:type)}.onDisappear{model.stop()}
         .onChange(of:scenePhase){_,phase in if phase == .active{model.load(localID,type:type)}else{model.stop()}}
    }
}
private struct AcloudSavedViewer:View {
    let account:UUID,asset:UUID
    let checksum:String?
    let type:String
    var body:some View {AcloudSavedViewerContent(loader:AcloudPreviewRegistry.shared.loader(account:account,asset:asset,checksum:checksum),account:account,asset:asset,checksum:checksum,type:type)}
}
private struct AcloudSavedViewerContent:View {
    @ObservedObject var loader:AcloudPreviewLoader
    let account:UUID,asset:UUID
    let checksum:String?
    let type:String
    var body:some View {
        VStack(spacing:16) {
            if let data=loader.data,let image=UIImage(data:data){Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:.infinity)}
            else{ContentUnavailableView("Saved preview",systemImage:type=="video" ? "video":"photo")}
            if loader.loading{ProgressView("Loading saved preview…")}
            else if loader.data==nil{Button("Load saved thumbnail over Wi-Fi"){Task{await loader.load(account:account,asset:asset,checksum:checksum,download:true)}}.buttonStyle(.bordered)}
            Text(loader.message ?? "Reduced-resolution saved thumbnail. Restore a copy to Photos for the full-quality photo or video playback.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.task{await loader.load(account:account,asset:asset,checksum:checksum)}
    }
}

// PhotoKit metadata work stays off MainActor. No resource requests or uploads occur here.
private actor AcloudDeviceGalleryStore {
    private var result:PHFetchResult<PHAsset>?
    private var currentOrder:AcloudGalleryOrder?
    func accessibleIDs(_ ids:Set<String>)->Set<String>{
        let access=PHPhotoLibrary.authorizationStatus(for:.readWrite)
        guard access == .authorized || access == .limited,ids.count<=10 else{return []}
        let result=PHAsset.fetchAssets(withLocalIdentifiers:Array(ids),options:nil)
        var allowed=Set<String>();result.enumerateObjects{asset,_,_ in allowed.insert(asset.localIdentifier)}
        return allowed
    }
    func page(order:AcloudGalleryOrder,offset:Int,reload:Bool,limit:Int=200)->(items:[AcloudGalleryEntry],total:Int) {
        let access=PHPhotoLibrary.authorizationStatus(for:.readWrite)
        guard access == .authorized || access == .limited else{result=nil;return([],0)}
        if reload || result==nil || currentOrder != order {
            let options=PHFetchOptions();options.sortDescriptors=[NSSortDescriptor(key:"creationDate",ascending:order == .oldest)]
            options.predicate=NSPredicate(format:"mediaType == %d OR mediaType == %d",PHAssetMediaType.image.rawValue,PHAssetMediaType.video.rawValue)
            result=PHAsset.fetchAssets(with:options);currentOrder=order
        }
        guard let result,offset>=0,offset<result.count else{return([],result?.count ?? 0)}
        let items=(offset..<min(offset+max(200,limit),result.count)).map {index in
            let asset=result.object(at:index)
            return AcloudGalleryEntry(id:asset.localIdentifier,type:asset.mediaType == .video ? "video":"image",date:asset.creationDate,duration:asset.mediaType == .video ? asset.duration:nil,live:asset.mediaSubtypes.contains(.photoLive),localID:asset.localIdentifier,revision:asset.modificationDate)
        }
        return(items,result.count)
    }
}
