import Foundation

public struct StoredCookie: Codable, Sendable, Hashable {
    public var name: String
    public var value: String
    public var domain: String
    public init(name: String, value: String, domain: String) {
        self.name = name; self.value = value; self.domain = domain
    }
}

/// The signed-in Google account's youtube.com cookies.
public struct CookieJar: Codable, Sendable, Equatable {
    public var cookies: [StoredCookie]
    public init(cookies: [StoredCookie]) {
        // keep only youtube.com cookies; later duplicates win
        var byName: [String: StoredCookie] = [:]
        for c in cookies where c.domain.lowercased().hasSuffix("youtube.com") { byName[c.name] = c }
        self.cookies = byName.values.sorted { $0.name < $1.name }
    }

    public func value(_ name: String) -> String? { cookies.first { $0.name == name }?.value }

    /// Same rule as yt-dlp: LOGIN_INFO plus one of the SAPISID cookies.
    public var isSignedIn: Bool {
        value("LOGIN_INFO") != nil && (value("SAPISID") ?? value("__Secure-3PAPISID") ?? value("__Secure-1PAPISID")) != nil
    }

    public var cookieHeader: String { cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }

    public func authorizationHeader(origin: String = "https://www.youtube.com", now: Date = Date()) -> String? {
        let ts = String(Int(now.timeIntervalSince1970.rounded()))
        let schemes: [(String, String?)] = [
            ("SAPISIDHASH", value("SAPISID") ?? value("__Secure-3PAPISID")),
            ("SAPISID1PHASH", value("__Secure-1PAPISID")),
            ("SAPISID3PHASH", value("__Secure-3PAPISID")),
        ]
        let parts = schemes.compactMap { scheme, sid -> String? in
            guard let sid else { return nil }
            return "\(scheme) \(ts)_\(SHA1.hex("\(ts) \(sid) \(origin)"))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Parses a Netscape cookies.txt export (e.g. from a Safari cookie extension).
    public static func parseNetscape(_ text: String) -> CookieJar {
        var out: [StoredCookie] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if line.hasPrefix("#HttpOnly_") { line.removeFirst("#HttpOnly_".count) }
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { continue }
            out.append(StoredCookie(name: f[5], value: f[6].trimmingCharacters(in: .whitespacesAndNewlines), domain: f[0]))
        }
        return CookieJar(cookies: out)
    }
}

/// Minimal SHA-1 (only used for the SAPISIDHASH header; runs on Linux tests too).
enum SHA1 {
    static func hex(_ s: String) -> String { digest(Array(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var m = message
        let ml = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }
        for chunk in stride(from: 0, to: m.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotl(b, 30), a, t)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
