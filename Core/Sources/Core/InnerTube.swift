import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Client profiles (mirrors yt-dlp's INNERTUBE_CLIENTS; overridable via clients.json in the repo)

public struct ClientProfile: Codable, Sendable {
    public var clientName: String
    public var clientVersion: String
    public var clientId: Int
    public var userAgent: String
    public var deviceMake: String?
    public var deviceModel: String?
    public var osName: String?
    public var osVersion: String?
    /// Needs the JS player (signature + n challenges) — solved with yt-dlp's EJS solver in JavaScriptCore.
    public var requiresJS: Bool
}

public struct ClientConfig: Codable, Sendable {
    public var anonymousClients: [String]
    public var signedInClients: [String]
    public var playerJSVariant: String
    public var clients: [String: ClientProfile]

    public static let remoteURL = URL(string: "https://raw.githubusercontent.com/amoguslittleahhh/Youtube-to-MP4-Converter-/main/clients.json")!

    public static let builtIn: ClientConfig = try! JSONDecoder().decode(ClientConfig.self, from: Data(builtInJSON.utf8))

    /// Remote copy first (so YouTube changes can be fixed without a new build), bundled copy as fallback.
    public static func load() async -> ClientConfig {
        var req = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let (d, r) = try? await Net.data(req), r.statusCode == 200,
           let cfg = try? JSONDecoder().decode(ClientConfig.self, from: d), !cfg.anonymousClients.isEmpty {
            return cfg
        }
        return builtIn
    }

    // Keep in sync with /clients.json (a unit test checks this).
    static let builtInJSON = #"""
    {
      "anonymousClients": ["visionos", "tv_samsung", "ios_producer"],
      "signedInClients": ["tv_samsung"],
      "playerJSVariant": "tv-player-ias.vflset/tv-player-ias.js",
      "clients": {
        "visionos": {
          "clientName": "VISIONOS", "clientVersion": "1.02", "clientId": 101,
          "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
          "deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471",
          "requiresJS": false
        },
        "tv_samsung": {
          "clientName": "TVHTML5", "clientVersion": "5.20260707", "clientId": 7,
          "userAgent": "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
          "deviceMake": "Samsung", "deviceModel": "UKS9800", "osName": "Tizen", "osVersion": "2.4.0",
          "requiresJS": true
        },
        "ios_producer": {
          "clientName": "IOS_PRODUCER", "clientVersion": "0.147.945", "clientId": 92,
          "userAgent": "com.google.ios.youtubeproducer/0.147.945 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
          "deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82",
          "requiresJS": false
        }
      }
    }
    """#
}

public protocol ChallengeSolving: Sendable {
    /// Returns solved values keyed by challenge, for "n" and "sig" challenges.
    func solve(playerID: String, player: String, n: [String], sig: [String]) throws -> (n: [String: String], sig: [String: String])
}

// MARK: - Extractor

public final class YouTubeExtractor: @unchecked Sendable {
    let cookies: CookieJar?
    let solver: ChallengeSolving?
    let cacheDir: URL
    static let pageUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    public init(cookies: CookieJar?, solver: ChallengeSolving?, cacheDir: URL = FileManager.default.temporaryDirectory) {
        self.cookies = (cookies?.isSignedIn ?? false) ? cookies : nil
        self.solver = solver
        self.cacheDir = cacheDir
    }

    public func extract(_ id: String) async throws -> VideoInfo {
        let config = await ClientConfig.load()
        let page = try? await watchPage(id, auth: nil)
        var accountReason: String?
        var lastError: Error = ExtractionError.noFormats

        for name in config.anonymousClients {
            guard let profile = config.clients[name], !profile.requiresJS || solver != nil else { continue }
            do {
                switch try await attempt(id, name: name, profile: profile, config: config, page: page, auth: nil) {
                case .success(let info): return info
                case .needsAccount(let reason): accountReason = accountReason ?? reason
                case .fatal(let e): throw e
                case .retry(let e): lastError = e
                }
            } catch let e as ExtractionError {
                if case .network = e { lastError = e; continue }
                throw e
            } catch { lastError = error }
        }

        if let reason = accountReason {
            guard let cookies else { throw ExtractionError.needsSignIn(reason) }
            let authedPage = try? await watchPage(id, auth: cookies)
            for name in config.signedInClients {
                guard let profile = config.clients[name], !profile.requiresJS || solver != nil else { continue }
                switch try await attempt(id, name: name, profile: profile, config: config, page: authedPage ?? page, auth: cookies) {
                case .success(let info): return info
                case .needsAccount(let r): lastError = ExtractionError.unavailable(r)
                case .fatal(let e): throw e
                case .retry(let e): lastError = e
                }
            }
            if case ExtractionError.noFormats = lastError { throw ExtractionError.unavailable(reason) }
        }
        throw lastError
    }

    enum Attempt { case success(VideoInfo), needsAccount(String), fatal(Error), retry(Error) }

    func attempt(_ id: String, name: String, profile: ClientProfile, config: ClientConfig, page: String?, auth: CookieJar?) async throws -> Attempt {
        var player: (id: String, code: String, sts: Int)?
        if profile.requiresJS { player = try await playerJS(page: page, variant: config.playerJSVariant) }
        let pr = try await playerRequest(id, profile: profile, visitorData: page.flatMap { Self.match(#""VISITOR_DATA":"([^"]+)""#, $0) }, sts: player?.sts, auth: auth)

        let ps = pr["playabilityStatus"] as? [String: Any] ?? [:]
        let status = ps["status"] as? String ?? "ERROR"
        let reason = (ps["reason"] as? String) ?? ((ps["messages"] as? [String])?.first) ?? "This video is unavailable."
        let details = pr["videoDetails"] as? [String: Any] ?? [:]

        switch status {
        case "OK": break
        case "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED":
            return .needsAccount(reason)
        case "LIVE_STREAM_OFFLINE":
            return .fatal(ExtractionError.upcoming(Self.upcomingMessage(ps, reason)))
        case "UNPLAYABLE":
            let r = reason.lowercased()
            if r.contains("member") || r.contains("age") || r.contains("sign in") { return .needsAccount(reason) }
            return .retry(ExtractionError.unavailable(reason))   // e.g. made-for-kids on visionos → next client
        default:
            return .fatal(ExtractionError.unavailable(reason))
        }

        let sd = pr["streamingData"] as? [String: Any] ?? [:]
        let isLive = (details["isLive"] as? Bool) ?? false
        var formats = try parseFormats(sd["adaptiveFormats"] as? [[String: Any]] ?? [], profile: profile, player: player)
        if isLive { formats = [] }
        let hls = (sd["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
        let info = VideoInfo(
            id: id,
            title: details["title"] as? String ?? "YouTube video",
            author: details["author"] as? String ?? "",
            duration: Double(details["lengthSeconds"] as? String ?? "") ?? 0,
            isLive: isLive,
            formats: formats,
            hlsManifestURL: hls,
            mediaHeaders: ["User-Agent": profile.userAgent],
            client: name)
        if isLive { return hls == nil ? .retry(ExtractionError.noFormats) : .success(info) }
        guard FormatSelector.bestAudio(formats) != nil, formats.contains(where: { $0.isVideo && $0.isH264 }) else {
            if details["isLiveContent"] as? Bool == true, (sd["adaptiveFormats"] as? [[String: Any]])?.isEmpty == false {
                return .retry(ExtractionError.unavailable("This stream just ended and YouTube is still processing it. Try again in a little while."))
            }
            return .retry(ExtractionError.noFormats)
        }
        return .success(info)
    }

    static func upcomingMessage(_ ps: [String: Any], _ reason: String) -> String {
        let renderer = ((ps["liveStreamability"] as? [String: Any])?["liveStreamabilityRenderer"] as? [String: Any])?["offlineSlate"] as? [String: Any]
        let slate = renderer?["liveStreamOfflineSlateRenderer"] as? [String: Any]
        if let ts = (slate?["scheduledStartTime"] as? String).flatMap(Double.init) {
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .short
            return "This stream hasn't started yet. It starts \(f.string(from: Date(timeIntervalSince1970: ts)))."
        }
        return reason
    }

    // MARK: Requests

    func watchPage(_ id: String, auth: CookieJar?) async throws -> String {
        let url = URL(string: "https://www.youtube.com/watch?v=\(id)&bpctr=9999999999&has_verified=1")!
        var cookie = "SOCS=CAI; PREF=hl=en&tz=UTC"   // skips the EU/UK consent page
        if let auth { cookie += "; " + auth.cookieHeader }
        return try await Net.text(url, headers: ["User-Agent": Self.pageUA, "Cookie": cookie, "Accept-Language": "en-US,en;q=0.9"])
    }

    func playerRequest(_ id: String, profile: ClientProfile, visitorData: String?, sts: Int?, auth: CookieJar?) async throws -> [String: Any] {
        var client: [String: Any] = [
            "clientName": profile.clientName, "clientVersion": profile.clientVersion,
            "hl": "en", "gl": Locale.current.region?.identifier ?? "US", "userAgent": profile.userAgent,
        ]
        client["deviceMake"] = profile.deviceMake
        client["deviceModel"] = profile.deviceModel
        client["osName"] = profile.osName
        client["osVersion"] = profile.osVersion
        client["visitorData"] = visitorData
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        playback["signatureTimestamp"] = sts
        let body: [String: Any] = [
            "context": ["client": client, "user": ["lockedSafetyMode": false]],
            "videoId": id,
            "playbackContext": ["contentPlaybackContext": playback],
            "contentCheckOk": true, "racyCheckOk": true,
        ]
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var headers = [
            "Content-Type": "application/json",
            "User-Agent": profile.userAgent,
            "X-YouTube-Client-Name": String(profile.clientId),
            "X-YouTube-Client-Version": profile.clientVersion,
            "Origin": "https://www.youtube.com",
            "Cookie": "SOCS=CAI",
        ]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        if let auth {
            headers["Cookie"] = "SOCS=CAI; " + auth.cookieHeader
            headers["Authorization"] = auth.authorizationHeader()
            headers["X-Origin"] = "https://www.youtube.com"
            headers["X-Goog-AuthUser"] = "0"
            headers["X-Youtube-Bootstrap-Logged-In"] = "true"
        }
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (d, r) = try await Net.data(req)
        guard r.statusCode == 200, let json = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw ExtractionError.network("YouTube returned HTTP \(r.statusCode). Check your connection and try again.")
        }
        return json
    }

    func playerJS(page: String?, variant: String) async throws -> (id: String, code: String, sts: Int) {
        var pid = page.flatMap { Self.match(#"/s/player/([0-9a-fA-F]{8,})/"#, $0) }
        if pid == nil {
            let api = try await Net.text(URL(string: "https://www.youtube.com/iframe_api")!, headers: ["User-Agent": Self.pageUA])
            pid = Self.match(#"player\\?/([0-9a-fA-F]{8,})\\?/"#, api)
        }
        guard let pid else { throw ExtractionError.network("Couldn't find YouTube's player version.") }
        let cache = cacheDir.appendingPathComponent("player-\(pid)-\(variant.split(separator: "/").last ?? "js")")
        var code = (try? String(contentsOf: cache, encoding: .utf8)) ?? ""
        if code.isEmpty {
            code = try await Net.text(URL(string: "https://www.youtube.com/s/player/\(pid)/\(variant)")!, headers: ["User-Agent": Self.pageUA])
            try? code.write(to: cache, atomically: true, encoding: .utf8)
        }
        guard let sts = Self.match(#"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#, code).flatMap(Int.init) else {
            throw ExtractionError.network("Couldn't read YouTube's player signature timestamp.")
        }
        return (pid, code, sts)
    }

    // MARK: Formats

    func parseFormats(_ raw: [[String: Any]], profile: ClientProfile, player: (id: String, code: String, sts: Int)?) throws -> [StreamFormat] {
        struct Pending { var dict: [String: Any]; var url: URLComponents; var sig: String?; var sp: String; var n: String? }
        var pending: [Pending] = []
        for f in raw {
            if f["targetDurationSec"] != nil || f["drmFamilies"] != nil { continue }   // live/post-live fragments, DRM
            var comps: URLComponents?
            var sig: String?
            var sp = "signature"
            if let u = f["url"] as? String {
                comps = URLComponents(string: u)
            } else if let cipher = f["signatureCipher"] as? String {
                let q = URLComponents(string: "?" + cipher)?.queryItems ?? []
                comps = q.first { $0.name == "url" }?.value.flatMap(URLComponents.init(string:))
                sig = q.first { $0.name == "s" }?.value
                sp = q.first { $0.name == "sp" }?.value ?? "signature"
                if sig == nil || !profile.requiresJS { continue }
            }
            guard let comps else { continue }
            let n = profile.requiresJS ? comps.queryItems?.first { $0.name == "n" }?.value : nil
            pending.append(Pending(dict: f, url: comps, sig: sig, sp: sp, n: n))
        }

        var nMap: [String: String] = [:], sigMap: [String: String] = [:]
        let ns = Array(Set(pending.compactMap(\.n))), sigs = Array(Set(pending.compactMap(\.sig)))
        if !ns.isEmpty || !sigs.isEmpty {
            guard let solver, let player else { throw ExtractionError.network("This video needs YouTube's player code, which couldn't be loaded.") }
            (nMap, sigMap) = try solver.solve(playerID: player.id, player: player.code, n: ns, sig: sigs)
        }

        return pending.compactMap { p in
            // Edit the raw query so the other (already encoded) parameters stay byte-identical.
            var comps = p.url
            var items = (comps.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
            if let n = p.n {
                guard let solved = nMap[n] else { return nil }
                items = items.map { $0.hasPrefix("n=") ? "n=" + Self.encode(solved) : $0 }
            }
            if let s = p.sig {
                guard let solved = sigMap[s] else { return nil }
                items.append(p.sp + "=" + Self.encode(solved))
            }
            comps.percentEncodedQuery = items.joined(separator: "&")
            guard let url = comps.url, let itag = p.dict["itag"] as? Int, let mime = p.dict["mimeType"] as? String else { return nil }
            let transfer = ((p.dict["colorInfo"] as? [String: Any])?["transferCharacteristics"] as? String) ?? ""
            let label = p.dict["qualityLabel"] as? String
            return StreamFormat(
                itag: itag, url: url, mimeType: mime,
                width: p.dict["width"] as? Int, height: p.dict["height"] as? Int, fps: p.dict["fps"] as? Int,
                bitrate: p.dict["bitrate"] as? Int ?? 0,
                contentLength: (p.dict["contentLength"] as? String).flatMap { Int64($0) },
                qualityLabel: label,
                isHDR: transfer.contains("SMPTEST2084") || transfer.contains("ARIB_STD_B67") || (label?.contains("HDR") ?? false),
                isDRC: p.dict["isDrc"] as? Bool ?? false,
                audioIsDefault: (p.dict["audioTrack"] as? [String: Any])?["audioIsDefault"] as? Bool)
        }
    }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    static func match(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
