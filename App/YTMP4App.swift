import SwiftUI
import UniformTypeIdentifiers
import Core

@main
struct YTMP4App: App {
    var body: some Scene {
        WindowGroup { HomeView() }
    }
}

struct Job: Identifiable {
    let id = UUID()
    let videoID: String
    let quality: String?
    let autostart: Bool
}

struct HomeView: View {
    @State private var link = ""
    @State private var job: Job?
    @State private var signedIn = AccountStore.load()?.isSignedIn ?? false
    @State private var showSignIn = false
    @State private var showImporter = false
    @State private var alert: String?
    @FocusState private var focused: Bool

    private var videoID: String? { YouTubeID.extract(from: link) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .symbolRenderingMode(.hierarchical)
                        Text("YouTube to MP4").font(.largeTitle.bold())
                        Text("Up to 4K. Plays on WhatsApp, iMessage and everywhere else.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            TextField("Paste a YouTube link", text: $link)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .submitLabel(.go)
                                .focused($focused)
                                .onSubmit(go)
                            if !link.isEmpty {
                                Button("Clear", systemImage: "xmark.circle.fill") { link = "" }
                                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        HStack(spacing: 10) {
                            PasteButton(payloadType: String.self) { strings in
                                link = strings.first ?? ""
                                go()
                            }
                            .buttonBorderShape(.capsule)
                            .labelStyle(.titleAndIcon)

                            Button(action: go) {
                                Label("Get Video", systemImage: "arrow.right").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(videoID == nil)
                        }
                        .controlSize(.large)

                        if !link.isEmpty && videoID == nil {
                            Text("That isn't a YouTube video link.").font(.footnote).foregroundStyle(.red)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        tip("square.and.arrow.up", "From YouTube or Safari: tap **Share**, then **YT to MP4**. If you don't see it, tap **More** and add it to Favourites.")
                        tip("sparkles.tv", "Best quality is picked automatically (up to 4K). Pick another one from the Quality menu.")
                        tip("person.crop.circle", signedIn ? "Signed in with Google: age-restricted and members-only videos work." : "Sign in with Google (top right) to get age-restricted and members-only videos.")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { accountMenu }
            }
        }
        .sheet(item: $job) { job in
            DownloadView(model: DownloadModel(videoID: job.videoID, inExtension: false, preselect: job.quality, autostart: job.autostart)) {
                self.job = nil
            } onBusyChange: { busy in
                UIApplication.shared.isIdleTimerDisabled = busy
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSignIn) {
            GoogleSignInView { signedIn = true; alert = "Signed in. Age-restricted and members-only videos will now work." }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text, .data]) { result in importCookies(result) }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("OK", role: .cancel) {} }
        .onOpenURL(perform: handle)
        .task { await GoogleAccount.refresh() }
    }

    private var accountMenu: some View {
        Menu {
            if signedIn {
                Label("Signed in with Google", systemImage: "checkmark.circle")
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await GoogleAccount.signOut(); signedIn = false }
                }
            } else {
                Button("Sign in with Google", systemImage: "person.crop.circle.badge.plus") { showSignIn = true }
                Button("Import cookies.txt…", systemImage: "doc.badge.plus") { showImporter = true }
            }
        } label: {
            Image(systemName: signedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                .accessibilityLabel("Google account")
        }
    }

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }

    private func go() {
        guard let id = videoID else { return }
        focused = false
        job = Job(videoID: id, quality: nil, autostart: false)
    }

    private func handle(_ url: URL) {
        if url.host == "signin" { if !signedIn { showSignIn = true }; return }
        guard let (id, quality) = AppLinks.parse(url) else { return }
        job = nil
        DispatchQueue.main.async { job = Job(videoID: id, quality: quality, autostart: true) }
    }

    private func importCookies(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let jar = CookieJar.parseNetscape((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        if jar.isSignedIn {
            AccountStore.save(jar); signedIn = true
            alert = "Cookies imported. Age-restricted and members-only videos will now work."
        } else {
            alert = "That file has no signed-in youtube.com cookies (it needs LOGIN_INFO and SAPISID)."
        }
    }
}
