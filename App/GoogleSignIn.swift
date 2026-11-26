import SwiftUI
import WebKit
import Core

/// Signs in to YouTube with a Google account inside a web view and keeps the youtube.com cookies
/// (shared with the share extension through the Keychain). Needed for age-restricted / members-only videos.
enum GoogleAccount {
    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Dm%26hl%3Den%26next%3Dhttps%253A%252F%252Fm.youtube.com%252F")!
    /// A plain Mobile Safari UA — Google refuses sign-in from user agents it recognises as embedded web views.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    @MainActor static func currentJar() async -> CookieJar {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return CookieJar(cookies: cookies.map { StoredCookie(name: $0.name, value: $0.value, domain: $0.domain) })
    }

    /// YouTube rotates session cookies; refresh the shared copy from the web view's store on launch.
    @MainActor static func refresh() async {
        guard AccountStore.load() != nil else { return }
        let jar = await currentJar()
        if jar.isSignedIn { AccountStore.save(jar) }
    }

    @MainActor static func signOut() async {
        AccountStore.clear()
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") })
    }
}

struct GoogleSignInView: View {
    var onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInWebView { dismiss(); onSignedIn() }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in with Google")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    var onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = GoogleAccount.userAgent
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: GoogleAccount.signInURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () -> Void
        var finished = false
        init(onSignedIn: @escaping () -> Void) { self.onSignedIn = onSignedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, webView.url?.host?.hasSuffix("youtube.com") == true else { return }
            Task { @MainActor in
                let jar = await GoogleAccount.currentJar()
                guard jar.isSignedIn, !finished else { return }
                finished = true
                AccountStore.save(jar)
                onSignedIn()
            }
        }
    }
}
