import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DownloadError: LocalizedError {
    case forbidden
    case http(Int)
    case shortRead

    public var errorDescription: String? {
        switch self {
        case .forbidden: return "YouTube refused the download (HTTP 403). Try again — if it keeps happening, the app needs an update."
        case .http(let c): return "Download failed (HTTP \(c))."
        case .shortRead: return "The download was cut off. Try again."
        }
    }
}

/// Serialises writes into one output file.
actor FileSink {
    let handle: FileHandle
    init(url: URL, size: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
    }
    func write(from file: URL, at offset: Int64) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try handle.seek(toOffset: UInt64(offset))
        while let block = try input.read(upToCount: 1 << 20), !block.isEmpty {
            try handle.write(contentsOf: block)
        }
    }
    func close() throws { try handle.close() }
}

public enum Downloader {
    static let chunkSize: Int64 = 8 << 20
    static let parallel = 4

    /// Downloads `url` to `dest` with ranged requests (like yt-dlp's http_chunk_size, which avoids throttling).
    /// `progress` receives byte counts as chunks finish.
    public static func download(_ url: URL, length: Int64?, headers: [String: String], to dest: URL,
                                progress: @escaping @Sendable (Int64) -> Void) async throws {
        let total: Int64
        if let length, length > 0 { total = length } else { total = try await probeLength(url, headers: headers) }
        let sink = try FileSink(url: dest, size: total)
        let ranges: [(Int64, Int64)] = stride(from: Int64(0), to: total, by: Int(chunkSize)).map { ($0, Swift.min($0 + chunkSize, total) - 1) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < ranges.count else { return }
                let (start, end) = ranges[next]; next += 1
                group.addTask {
                    let tmp = try await fetchRange(url, start: start, end: end, headers: headers)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try await sink.write(from: tmp, at: start)
                    progress(end - start + 1)
                }
            }
            for _ in 0..<parallel { addNext() }
            while try await group.next() != nil { addNext() }
        }
        try await sink.close()
    }

    static func fetchRange(_ url: URL, start: Int64, end: Int64, headers: [String: String]) async throws -> URL {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                var req = URLRequest(url: url)
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                let (file, r) = try await Net.file(req)
                guard r.statusCode != 403 else { throw DownloadError.forbidden }
                guard r.statusCode == 206 || (r.statusCode == 200 && start == 0) else { throw DownloadError.http(r.statusCode) }
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                guard size == end - start + 1 else { try? FileManager.default.removeItem(at: file); throw DownloadError.shortRead }
                return file
            } catch DownloadError.forbidden {
                throw DownloadError.forbidden
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= 5 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    static func probeLength(_ url: URL, headers: [String: String]) async throws -> Int64 {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, r) = try await Net.data(req)
        if r.statusCode == 403 { throw DownloadError.forbidden }
        guard let cr = r.value(forHTTPHeaderField: "Content-Range"), let total = cr.split(separator: "/").last.flatMap({ Int64($0) }) else {
            throw DownloadError.http(r.statusCode)
        }
        return total
    }
}
