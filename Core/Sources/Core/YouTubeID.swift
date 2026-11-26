import Foundation

public enum YouTubeID {
    private static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$")
    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com", "youtu.be", "www.youtu.be",
    ]

    /// Returns the 11-character video ID if `text` contains a YouTube video link, else nil.
    public static func extract(from text: String) -> String? {
        for candidate in urlCandidates(in: text) {
            if let id = videoID(from: candidate) { return id }
        }
        return nil
    }

    public static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        var id: String?
        if host.hasSuffix("youtu.be") {
            id = parts.first
        } else if let first = parts.first, ["shorts", "live", "embed", "v", "e"].contains(first), parts.count > 1 {
            id = parts[1]
        } else if parts.first == "watch" || parts.isEmpty {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        }
        guard let id, isValid(id) else { return nil }
        return id
    }

    public static func isValid(_ id: String) -> Bool {
        idPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    private static func urlCandidates(in text: String) -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var urls: [URL] = []
        if let u = URL(string: trimmed), u.scheme != nil { urls.append(u) }
        // Text shared by apps often wraps the link in a sentence.
        for word in trimmed.components(separatedBy: .whitespacesAndNewlines) where word.contains("youtu") {
            let w = word.hasPrefix("http") ? word : "https://" + word
            if let u = URL(string: w) { urls.append(u) }
        }
        return urls
    }
}
