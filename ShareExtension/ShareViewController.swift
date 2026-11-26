import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Core

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { @MainActor in
            let text = await sharedText()
            if let id = YouTubeID.extract(from: text) {
                show(DownloadView(model: DownloadModel(videoID: id, inExtension: true), onClose: { [weak self] in self?.close() },
                                  onBusyChange: { [weak self] busy in self?.isModalInPresentation = busy },
                                  openInApp: { [weak self] url in self?.openContainingApp(url) ?? false }))
            } else {
                show(NotYouTubeView { [weak self] in self?.close() })
            }
        }
    }

    private func show<V: View>(_ root: V) {
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func close() { extensionContext?.completeRequest(returningItems: nil) }

    /// Collects every URL / text the host app shared.
    private func sharedText() async -> String {
        var parts: [String] = []
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            if let s = item.attributedContentText?.string { parts.append(s) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                    if let url = value as? URL { parts.append(url.absoluteString) } else if let s = value as? String { parts.append(s) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    if let s = value as? String { parts.append(s) } else if let d = value as? Data { parts.append(String(decoding: d, as: UTF8.self)) }
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Share extensions have no public "open app" API; the standard workaround walks the responder chain to
    /// UIApplication and calls openURL:options:completionHandler: through its implementation pointer.
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if r is UIApplication, let method = class_getInstanceMethod(type(of: r), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(method_getImplementation(method), to: Open.self)(r, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}

private struct NotYouTubeView: View {
    var onClose: () -> Void
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Not a YouTube video", systemImage: "link.badge.plus",
                                   description: Text("Share a YouTube video link (youtube.com or youtu.be) to download it as MP4."))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark", action: onClose) } }
        }
    }
}
