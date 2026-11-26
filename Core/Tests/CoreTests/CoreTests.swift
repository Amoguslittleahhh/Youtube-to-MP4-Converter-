import XCTest
@testable import Core

final class CoreTests: XCTestCase {
    func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)") }
    lazy var tmp: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("coretests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    // MARK: links

    func testVideoIDs() {
        let ok = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PL123",
            "https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?si=abcdef",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://www.youtube.com/live/dQw4w9WgXcQ?feature=shared",
            "https://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ&feature=share",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
            "youtu.be/dQw4w9WgXcQ",
            "Check this out! https://youtu.be/dQw4w9WgXcQ?si=x shared via YouTube",
        ]
        for s in ok { XCTAssertEqual(YouTubeID.extract(from: s), "dQw4w9WgXcQ", s) }
        let bad = ["https://www.youtube.com/@channel", "https://example.com/watch?v=dQw4w9WgXcQ",
                   "https://www.youtube.com/watch?v=short", "https://www.youtube.com/playlist?list=PL123", "hello"]
        for s in bad { XCTAssertNil(YouTubeID.extract(from: s), s) }
    }

    // MARK: format choice

    func fmt(_ itag: Int, _ mime: String, _ label: String?, w: Int? = nil, h: Int? = nil, fps: Int? = nil, br: Int, hdr: Bool = false,
             drc: Bool = false, def: Bool? = nil) -> StreamFormat {
        StreamFormat(itag: itag, url: URL(string: "https://x/\(itag)")!, mimeType: mime, width: w, height: h, fps: fps, bitrate: br,
                     contentLength: 1000, qualityLabel: label, isHDR: hdr, isDRC: drc, audioIsDefault: def)
    }

    func testFormatOptions() {
        let av1 = #"video/mp4; codecs="av01.0.12M.08""#, avc = #"video/mp4; codecs="avc1.640028""#
        let vp9 = #"video/webm; codecs="vp9""#, aac = #"audio/mp4; codecs="mp4a.40.2""#
        let formats = [
            fmt(571, av1, "4320p60", w: 7680, h: 4320, fps: 60, br: 90_000_000),
            fmt(701, av1, "2160p60 HDR", w: 3840, h: 2160, fps: 60, br: 40_000_000, hdr: true),
            fmt(401, av1, "2160p60", w: 3840, h: 2160, fps: 60, br: 30_000_000),
            fmt(315, vp9, "2160p60", w: 3840, h: 2160, fps: 60, br: 35_000_000),
            fmt(400, av1, "1440p60", w: 2560, h: 1440, fps: 60, br: 15_000_000),
            fmt(399, av1, "1080p60", w: 1920, h: 1080, fps: 60, br: 5_000_000),
            fmt(299, avc, "1080p60", w: 1920, h: 1080, fps: 60, br: 6_000_000),
            fmt(136, avc, "720p", w: 1280, h: 720, fps: 30, br: 2_000_000),
            fmt(140, aac, nil, br: 130_000, def: true),
            fmt(141, aac, nil, br: 260_000, drc: true, def: true),
            fmt(139, aac, nil, br: 50_000, def: false),
        ]
        let info = VideoInfo(id: "x", title: "t", author: "a", duration: 60, isLive: false, formats: formats, hlsManifestURL: nil, mediaHeaders: [:], client: "visionos")

        let opts = FormatSelector.options(for: info, av1Decodable: true)
        XCTAssertEqual(opts.map(\.label), ["2160p60", "1440p60", "1080p60", "720p"])
        XCTAssertEqual(opts.map(\.video.itag), [401, 400, 299, 136])   // no 8K, no HDR, no VP9; H.264 preferred at 1080p
        XCTAssertEqual(opts.map(\.needsConversion), [true, true, false, false])
        XCTAssertEqual(opts.first?.audio.itag, 140)                   // default track, non-DRC

        let noAV1 = FormatSelector.options(for: info, av1Decodable: false)
        XCTAssertEqual(noAV1.map(\.video.itag), [299, 136])
    }

    func testVerticalShortsLabel() {
        let f = fmt(137, #"video/mp4; codecs="avc1.640028""#, "1080p", w: 1080, h: 1920, fps: 30, br: 1)
        XCTAssertEqual(f.resolutionClass, 1080)
    }

    // MARK: auth

    func testSHA1() {
        XCTAssertEqual(SHA1.hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA1.hex(String(repeating: "a", count: 1000)), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    func testCookiesAndAuthHeader() {
        let txt = """
        # Netscape HTTP Cookie File
        .youtube.com\tTRUE\t/\tTRUE\t1999999999\tSAPISID\tsapi/abc
        #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1999999999\tLOGIN_INFO\tlogin
        .youtube.com\tTRUE\t/\tTRUE\t1999999999\t__Secure-3PAPISID\tthree
        .google.com\tTRUE\t/\tTRUE\t1999999999\tSID\tnope
        """
        let jar = CookieJar.parseNetscape(txt)
        XCTAssertTrue(jar.isSignedIn)
        XCTAssertNil(jar.value("SID"))
        XCTAssertEqual(jar.cookieHeader, "LOGIN_INFO=login; SAPISID=sapi/abc; __Secure-3PAPISID=three")
        let h = jar.authorizationHeader(now: Date(timeIntervalSince1970: 1700000000))!
        XCTAssertEqual(h, "SAPISIDHASH 1700000000_\(SHA1.hex("1700000000 sapi/abc https://www.youtube.com")) SAPISID3PHASH 1700000000_\(SHA1.hex("1700000000 three https://www.youtube.com"))")
        XCTAssertFalse(CookieJar(cookies: [StoredCookie(name: "SAPISID", value: "x", domain: ".youtube.com")]).isSignedIn)
    }

    func testBundledConfigMatchesRepoFile() throws {
        let repoFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../clients.json").standardizedFileURL
        let a = try JSONSerialization.jsonObject(with: Data(contentsOf: repoFile)) as! NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(ClientConfig.builtInJSON.utf8)) as! NSDictionary
        XCTAssertEqual(a, b, "clients.json and ClientConfig.builtInJSON must match")
        XCTAssertEqual(ClientConfig.builtIn.anonymousClients.first, "visionos")
    }

    // MARK: muxing

    func testMuxH264AndAAC() throws {
        for v in ["v264_moof.mp4", "v264_bdo.mp4"] {
            let out = tmp.appendingPathComponent("out-\(v)")
            try FragmentedMP4.mux(video: fixture(v), audio: fixture("a_aac.mp4"), to: out)
            try assertPlayable(out, codecs: ["h264", "aac"], frames: [90, 131], duration: 3.0)
        }
    }

    func testMuxAV1() throws {
        let out = tmp.appendingPathComponent("av1.mp4")
        try FragmentedMP4.mux(video: fixture("vav1.mp4"), audio: fixture("a_aac.mp4"), to: out)
        try assertPlayable(out, codecs: ["av1", "aac"], frames: [48, 131], duration: 3.0)
    }

    func testTransportStreamToMP4() throws {
        let tracks = try TransportStream.readTracks(fixture("live.ts"), workDir: tmp, width: 320, height: 240)
        XCTAssertEqual(tracks.count, 2)
        let out = tmp.appendingPathComponent("live.mp4")
        try MP4Writer.write(tracks, to: out)
        try assertPlayable(out, codecs: ["h264", "aac"], frames: [120, 189], duration: 4.0)
    }

    func testHLSParsing() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30
        https://m/720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4500000,CODECS="avc1.64002a,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=60
        https://m/1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,CODECS="vp09.00.40.08,mp4a.40.2",RESOLUTION=2560x1440,FRAME-RATE=60
        https://m/1440.m3u8
        """
        let v = HLS.parseVariants(master, base: URL(string: "https://m/master.m3u8")!)
        XCTAssertEqual(v.map(\.label), ["1080p60", "720p"])
        let media = HLS.parseMedia("""
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:2.0,
        seg/100.ts
        #EXTINF:2.0,
        https://m/seg/101.ts
        """, base: URL(string: "https://m/live/index.m3u8")!)
        XCTAssertEqual(media.segments.map(\.seq), [100, 101])
        XCTAssertEqual(media.segments[0].url.absoluteString, "https://m/live/seg/100.ts")
        XCTAssertFalse(media.ended)
    }

    // MARK: ffprobe-based validation (skipped where ffmpeg isn't installed)

    func run(_ args: [String]) throws -> (String, String)? {
        guard let tool = ["/usr/bin/", "/opt/homebrew/bin/", "/usr/local/bin/"].map({ $0 + args[0] }).first(where: FileManager.default.fileExists) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = Array(args.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func assertPlayable(_ url: URL, codecs: [String], frames: [Int], duration: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        // faststart: moov must come before mdat
        let head = Array(try Data(contentsOf: url).prefix(4096))
        let ftypSize = Int(head[0]) << 24 | Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
        XCTAssertEqual(String(decoding: head[4..<8], as: UTF8.self), "ftyp", file: file, line: line)
        XCTAssertEqual(String(decoding: head[(ftypSize + 4)..<(ftypSize + 8)], as: UTF8.self), "moov", file: file, line: line)

        guard let (probe, _) = try run(["ffprobe", "-v", "error", "-count_frames", "-show_entries", "stream=codec_name,nb_read_frames:format=duration", "-of", "csv=p=0", url.path]) else {
            throw XCTSkip("ffprobe not installed")
        }
        let lines = probe.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.prefix(codecs.count).map { String($0.split(separator: ",")[0]) }, codecs, probe, file: file, line: line)
        XCTAssertEqual(lines.prefix(codecs.count).map { Int($0.split(separator: ",")[1]) ?? -1 }, frames, probe, file: file, line: line)
        let dur = Double(lines.last ?? "") ?? 0
        XCTAssertEqual(dur, duration, accuracy: 0.15, probe, file: file, line: line)
        let (_, decodeErrors) = try run(["ffmpeg", "-v", "error", "-i", url.path, "-f", "null", "-"])!
        XCTAssertEqual(decodeErrors, "", file: file, line: line)
    }
}
