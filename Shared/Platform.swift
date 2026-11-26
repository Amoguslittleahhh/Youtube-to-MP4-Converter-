import Foundation
import Security
import VideoToolbox
import Photos
import Core

enum Device {
    /// AV1 hardware decode (iPhone 15 Pro and newer) — needed to convert YouTube's 1440p/4K streams.
    static var av1Decodable: Bool { VTIsHardwareDecodeSupported(0x6176_3031 /* 'av01' */) }
}

enum AppLinks {
    static let scheme = "ytmp4"
    /// ytmp4://download?v=<id>&q=<itag or live-label>
    static func url(videoID: String, quality: String?) -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = "download"
        c.queryItems = [URLQueryItem(name: "v", value: videoID)] + (quality.map { [URLQueryItem(name: "q", value: $0)] } ?? [])
        return c.url!
    }
    static func parse(_ url: URL) -> (id: String, quality: String?)? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "v" })?.value, YouTubeID.isValid(id) else { return nil }
        return (id, items.first { $0.name == "q" }?.value)
    }
}

/// Google account cookies, shared between the app and the share extension through a Keychain access group.
enum AccountStore {
    private static let account = "youtube-cookies"
    private static var group: String? {
        (Bundle.main.object(forInfoDictionaryKey: "KeychainGroup") as? String).flatMap { $0.hasPrefix(".") || $0.contains("$(") ? nil : $0 }
    }

    private static func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ytmp4", kSecAttrAccount as String: account]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func load() -> CookieJar? {
        var q = query()
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(CookieJar.self, from: data)
    }

    static func save(_ jar: CookieJar) {
        guard let data = try? JSONEncoder().encode(jar) else { return }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(query() as CFDictionary) }
}

enum PhotoSaver {
    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "YTMP4", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow “Add Photos Only” access for YT to MP4 in Settings › Privacy › Photos."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
