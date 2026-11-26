import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 8
        c.httpCookieAcceptPolicy = .never   // cookies are sent explicitly
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    static func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        let (d, r): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { d, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r!)) }
            }.resume()
        }
        #else
        let (d, r) = try await session.data(for: request)
        #endif
        guard let http = r as? HTTPURLResponse else { throw ExtractionError.network("Bad response") }
        return (d, http)
    }

    /// Downloads to a temporary file (keeps memory flat — important in the share extension).
    static func file(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        let (d, r) = try await data(request)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try d.write(to: tmp)
        return (tmp, r)
        #else
        let (u, r) = try await session.download(for: request)
        guard let http = r as? HTTPURLResponse else { throw ExtractionError.network("Bad response") }
        return (u, http)
        #endif
    }

    static func text(_ url: URL, headers: [String: String] = [:]) async throws -> String {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (d, r) = try await data(req)
        guard (200..<300).contains(r.statusCode) else { throw ExtractionError.network("HTTP \(r.statusCode) for \(url.host ?? "")") }
        return String(decoding: d, as: UTF8.self)
    }
}
