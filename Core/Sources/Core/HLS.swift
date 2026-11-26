import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thread-safe stop switch for live recording.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func stop() { lock.lock(); stopped = true; lock.unlock() }
    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

public enum HLS {
    struct Segment { var seq: Int; var url: URL; var duration: Double }
    struct MediaPlaylist { var segments: [Segment]; var targetDuration: Double; var ended: Bool; var initURL: URL? }

    static func attributes(_ line: Substring) -> [String: String] {
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=("[^"]*"|[^,]*)"#)
        let s = String(line)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let k = Range(m.range(at: 1), in: s), let v = Range(m.range(at: 2), in: s) else { continue }
            out[String(s[k])] = String(s[v]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return out
    }

    /// H.264 variants of a master playlist, best first.
    public static func parseVariants(_ text: String, base: URL) -> [LiveVariant] {
        var out: [LiveVariant] = []
        var pending: [String: String]?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if let attrs = pending, !line.hasPrefix("#") {
                pending = nil
                let codecs = attrs["CODECS"] ?? "avc1"
                guard codecs.contains("avc1"), let url = URL(string: String(line), relativeTo: base)?.absoluteURL else { continue }
                let res = (attrs["RESOLUTION"] ?? "0x0").split(separator: "x").compactMap { Int($0) }
                out.append(LiveVariant(url: url, width: res.first ?? 0, height: res.last ?? 0,
                                       fps: Int(Double(attrs["FRAME-RATE"] ?? "30") ?? 30), bandwidth: Int(attrs["BANDWIDTH"] ?? "0") ?? 0))
            }
        }
        // one per resolution/fps, highest bandwidth
        var best: [String: LiveVariant] = [:]
        for v in out where (best[v.label]?.bandwidth ?? -1) < v.bandwidth { best[v.label] = v }
        return best.values.sorted { (min($0.width, $0.height), $0.fps) > (min($1.width, $1.height), $1.fps) }
    }

    static func parseMedia(_ text: String, base: URL) -> MediaPlaylist {
        var seq = 0, target = 5.0, ended = false, duration = 0.0
        var initURL: URL?
        var segments: [Segment] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { seq = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("#EXT-X-TARGETDURATION:") { target = Double(line.dropFirst(22)) ?? 5 }
            else if line.hasPrefix("#EXT-X-ENDLIST") { ended = true }
            else if line.hasPrefix("#EXT-X-MAP:") { initURL = attributes(line.dropFirst(11))["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } }
            else if line.hasPrefix("#EXTINF:") { duration = Double(line.dropFirst(8).prefix { $0 != "," }) ?? 0 }
            else if !line.hasPrefix("#"), let u = URL(string: String(line), relativeTo: base)?.absoluteURL {
                segments.append(Segment(seq: seq, url: u, duration: duration)); seq += 1
            }
        }
        return MediaPlaylist(segments: segments, targetDuration: target, ended: ended, initURL: initURL)
    }

    public static func variants(master: URL, headers: [String: String]) async throws -> [LiveVariant] {
        parseVariants(try await Net.text(master, headers: headers), base: master)
    }

    /// Records a live stream from the live edge until `stop` is set or the stream ends, then remuxes to MP4.
    public static func record(_ variant: LiveVariant, headers: [String: String], workDir: URL, output: URL, stop: StopFlag,
                              progress: @escaping @Sendable (_ seconds: Double, _ bytes: Int64) -> Void) async throws {
        let raw = workDir.appendingPathComponent("live.raw")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let out = try FileHandle(forWritingTo: raw)
        var lastSeq: Int?
        var isFMP4 = false
        var seconds = 0.0, bytes: Int64 = 0, failures = 0

        func append(_ url: URL) async throws {
            var req = URLRequest(url: url)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (file, r) = try await Net.file(req)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (200..<300).contains(r.statusCode) else { throw DownloadError.http(r.statusCode) }
            let d = try Data(contentsOf: file)
            try out.write(contentsOf: d)
            bytes += Int64(d.count)
        }

        while true {
            let playlist: MediaPlaylist
            do {
                playlist = parseMedia(try await Net.text(variant.url, headers: headers), base: variant.url)
                failures = 0
            } catch {
                failures += 1
                if failures >= 5 || stop.isStopped { if lastSeq == nil { throw error }; break }
                try await Task.sleep(nanoseconds: 2_000_000_000); continue
            }
            if lastSeq == nil, let initURL = playlist.initURL { try await append(initURL); isFMP4 = true }
            let fresh = lastSeq.map { last in playlist.segments.filter { $0.seq > last } } ?? Array(playlist.segments.suffix(1))
            for s in fresh {
                do { try await append(s.url) } catch where lastSeq != nil { continue }   // skip one missing segment
                lastSeq = s.seq; seconds += s.duration
                progress(seconds, bytes)
                if stop.isStopped { break }
            }
            if playlist.ended || stop.isStopped { break }
            for _ in 0..<Int(max(2, playlist.targetDuration)) {   // ~target/2 seconds, checking stop
                if stop.isStopped { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        try out.close()
        guard lastSeq != nil else { throw ExtractionError.unavailable("Nothing was recorded.") }
        let tracks = isFMP4
            ? try FragmentedMP4.readTracks(raw)
            : try TransportStream.readTracks(raw, workDir: workDir, width: variant.width, height: variant.height)
        try MP4Writer.write(tracks, to: output)
    }
}
