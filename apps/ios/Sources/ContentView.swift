import SwiftUI
import HealthClient

struct ContentView: View {
    @State private var status = "Checking..."

    var body: some View {
        TabView {
            BackupQueueView().tabItem { Label("Backup", systemImage: "icloud.and.arrow.up") }
            DiscoveryView().tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            RestoreView().tabItem { Label("Restore", systemImage: "arrow.down.circle") }
            StorageView().tabItem { Label("Storage", systemImage: "externaldrive") }
            AccountView().tabItem { Label("Account", systemImage: "person") }
            #if DEBUG
            VStack(spacing: 16) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Acloud")
                .font(.largeTitle)
            Text("Development Build")
            Text("API Status: \(status)")
                .accessibilityLabel("API Status: \(status)")
            }
            .padding()
            .tabItem { Label("Development", systemImage: "heart.text.square") }
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
