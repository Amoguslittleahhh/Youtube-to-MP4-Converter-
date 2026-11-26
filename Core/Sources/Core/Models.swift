import Foundation

public struct StreamFormat: Sendable, Hashable {
    public var itag: Int
    public var url: URL
    public var mimeType: String          // e.g. video/mp4; codecs="av01.0.12M.08"
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var bitrate: Int
    public var contentLength: Int64?
    public var qualityLabel: String?
    public var isHDR: Bool
    public var isDRC: Bool
    public var audioIsDefault: Bool?

    public var container: String { String(mimeType.split(separator: ";").first ?? "") }
    public var codecs: String {
        guard let r = mimeType.range(of: "codecs=\"") else { return "" }
        return String(mimeType[r.upperBound...].prefix { $0 != "\"" })
    }
    public var isVideo: Bool { container.hasPrefix("video/") }
    public var isAudio: Bool { container.hasPrefix("audio/") }
    public var isH264: Bool { codecs.hasPrefix("avc1") }
    public var isAV1: Bool { codecs.hasPrefix("av01") }
    public var isAAC: Bool { codecs.hasPrefix("mp4a") }

    /// Vertical resolution class ("1080" for 1080p), taken from YouTube's label when present.
    public var resolutionClass: Int {
        if let label = qualityLabel, let n = Int(label.prefix { $0.isNumber }) { return n }
        return min(width ?? 0, height ?? 0)
    }
}

public struct VideoInfo: Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var duration: Double
    public var isLive: Bool
    public var formats: [StreamFormat]
    public var hlsManifestURL: URL?
    /// Headers every media request must carry (User-Agent of the client that produced the URLs).
    public var mediaHeaders: [String: String]
    public var client: String

    public var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
}

public struct QualityOption: Sendable, Hashable, Identifiable {
    public var video: StreamFormat
    public var audio: StreamFormat
    public var duration: Double
    public var id: Int { video.itag }
    /// AV1 sources are converted to H.264 so the file plays everywhere (WhatsApp etc.).
    public var needsConversion: Bool { !video.isH264 }
    public var label: String {
        let fps = video.fps ?? 30
        return "\(video.resolutionClass)p" + (fps > 30 ? "\(fps)" : "")
    }
    public var estimatedBytes: Int64 {
        let audioBytes = audio.contentLength ?? Int64(Double(audio.bitrate) * duration / 8)
        if needsConversion {
            return Int64(Double(Transcode.bitrate(width: video.width ?? 3840, height: video.height ?? 2160, fps: video.fps ?? 30)) * duration / 8) + audioBytes
        }
        return (video.contentLength ?? Int64(Double(video.bitrate) * duration / 8)) + audioBytes
    }
}

public enum Transcode {
    /// H.264 target bitrate: ~0.1 bits per pixel per frame (≈40 Mbps for 4K60, ≈25 Mbps for 4K30).
    public static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let bpp = 0.1 * (fps > 30 ? 0.65 : 1.0)
        return min(Int(Double(width * height * max(fps, 24)) * bpp), 60_000_000)
    }
}

public struct LiveVariant: Sendable, Hashable, Identifiable {
    public var url: URL
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bandwidth: Int
    public var id: String { url.absoluteString }
    public var label: String { "\(min(width, height))p" + (fps > 30 ? "\(fps)" : "") }
}

public enum ExtractionError: LocalizedError, Equatable {
    case unavailable(String)
    case needsSignIn(String)
    case upcoming(String)
    case noFormats
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let r): return r
        case .needsSignIn(let r): return "\(r)\n\nOpen YT to MP4 and tap Sign in with Google to download this video."
        case .upcoming(let r): return r
        case .noFormats: return "YouTube didn't return a downloadable MP4 version of this video."
        case .network(let r): return r
        }
    }
}
