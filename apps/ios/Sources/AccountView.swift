import SwiftUI
import HealthClient

@MainActor private enum AccountScreen {
    static let tokens = KeychainSessionStore(service: (Bundle.main.bundleIdentifier ?? "com.example.backupclient") + ".session")
    static let api: AuthAPI? = {
        guard BetaReleaseSafety.acceptedConfiguration,
              let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              let url = URL(string: value) else { return nil }
        return AuthAPI(baseURL: url, store: tokens)
    }()
    static let model = AccountRefreshModel(readSession: { try tokens.read() }, load: {
        guard let api else { throw AccountAPIError.invalidConfiguration }
        return try await api.me()
    })
}

struct AccountView: View {
    @AppStorage("showDeveloperTools") private var showDeveloperTools=false
    private let api: AuthAPI?
    @ObservedObject private var model = AccountScreen.model
    @Environment(\.scenePhase) private var scenePhase
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var message = ""
    @State private var busy = false
    private let deviceIdentifier: String
    init() {
        api = AccountScreen.api
        // This is non-secret device metadata; authentication tokens use Keychain only.
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "backup_device_identifier") { deviceIdentifier = existing }
        else { let created = UUID().uuidString; defaults.set(created, forKey: "backup_device_identifier"); deviceIdentifier = created }
    }
    var body: some View {
        Form {
            Section {
                AcloudHero(icon:"person.crop.circle",eyebrow:"Your Acloud",title:"A little peace of mind.",message:"Manage your sign-in and find help with backup, restore or privacy.").acloudFeatureRow()
            }

            if let account = model.account {
                Section("Your account") {
                    Label(account.email,systemImage:"person.crop.circle.fill").font(.headline)
                    Label(account.emailVerified ? "Email verified" : "Email unverified",systemImage:account.emailVerified ? "checkmark.seal.fill":"envelope.badge").foregroundStyle(account.emailVerified ? AcloudStyle.accent:Color.secondary)
                    Button("Sign Out") { Task { await signOut() } }.disabled(busy)
                }
            } else if model.hasSession {
                Section("Your account") {
                    Text("Your account details are currently unavailable.")
                }
            } else {
                Section("Account") {
                    TextField("Email", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).textContentType(.username)
                    if showPassword {TextField("Password",text:$password).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.password)}else{SecureField("Password", text: $password).textContentType(.password)}
                    Toggle("Show password",isOn:$showPassword)
                    Button("Sign In") { Task { await signIn() } }.disabled(busy)
                    Link("Forgot password?",destination:URL(string:"https://staging.useacloud.com/forgot-password")!)
                    Button("Create invited account") { Task { await register() } }.disabled(busy)
                    Text("New passwords require at least 12 characters. Verification and recovery links open on the Acloud website.").font(.footnote)
                }
            }
            Section {
                if model.refreshing { ProgressView("Updating account…") }
                if !model.message.isEmpty { Text(model.message).font(.footnote) }
                Button("Refresh account") { Task { await model.refresh(force: true) } }
                    .disabled(busy || model.refreshing)
            }
            TransferNotificationSettings()
            Section("Help") {
                Link("Contact support", destination: URL(string:"mailto:Support247.acloud@useacloud.com")!)
                Link("Privacy requests", destination: URL(string:"mailto:Privacy247.acloud@useacloud.com")!)
                Text("Never share passwords, verification codes or private photos with support.").font(.footnote)
            }
            Section("About Acloud") {
                Text("Beta · Keep another copy of your photos and videos.").font(.footnote).foregroundStyle(.secondary)
                #if DEBUG
                DisclosureGroup("Diagnostics") {
                    Toggle("Show developer tools",isOn:$showDeveloperTools)
                }
                #endif
            }
            if !message.isEmpty { Text(message).accessibilityLabel(message) }
        }.acloudCanvas()
        .task { await model.refresh() }
        .refreshable { await model.refresh(force: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
    @MainActor private func signIn() async {
        guard let api else { message = "API configuration unavailable."; return }
        busy = true; defer { busy = false }
        model.invalidate()
        TransferNotifications.shared.signOut()
        AcloudPreviewRegistry.shared.clear()
        await RestoreModel.shared.invalidate()
        await StorageScreen.model.invalidate()
        do { try await BackupQueueModel.shared.stopForSignOut(); let signedIn = try await api.login(email: email, password: password, deviceIdentifier: deviceIdentifier); model.accept(signedIn); BackupQueueModel.shared.resumeAfterSignIn(); password = ""; message = "" }
        catch { message = "Unable to sign in. Check your credentials or connection." }
    }
    @MainActor private func register() async {
        guard let api else { message = "API configuration unavailable."; return }
        busy = true; defer { busy = false }
        do { try await api.register(email: email, password: password); password = ""; message = "If eligible, a verification email has been sent." }
        catch { message = "Unable to register. Use a valid email and at least 12 password characters." }
    }
    @MainActor private func signOut() async {
        guard let api else { return }
        busy = true; defer { busy = false }
        AcloudPreviewRegistry.shared.clear()
        await RestoreModel.shared.invalidate()
        await StorageScreen.model.invalidate()
        do { try await BackupQueueModel.shared.stopForSignOut(); try await api.logout(); TransferNotifications.shared.signOut(); model.invalidate(); message = "Signed out." }
        catch { message = "Sign out could not be confirmed. Retry when connected." }
    }
}
