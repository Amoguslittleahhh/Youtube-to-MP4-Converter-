import Foundation

// MARK: - Byte helpers

struct Bytes {
    var d: [UInt8] = []
    mutating func u8(_ v: UInt8) { d.append(v) }
    mutating func u16(_ v: UInt16) { d += [UInt8(v >> 8), UInt8(v & 0xff)] }
    mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { d.append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((v >> UInt64(s)) & 0xff)) } }
    mutating func fourcc(_ s: String) { d += Array(s.utf8.prefix(4)) }
    mutating func zeros(_ n: Int) { d += [UInt8](repeating: 0, count: n) }
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        var b = Bytes(); b.u32(UInt32(8 + body.count)); b.fourcc(type); b.d += body; return b.d
    }
    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ body: [UInt8]) -> [UInt8] {
        var b = Bytes(); b.u8(version); b.u8(UInt8((flags >> 16) & 0xff)); b.u16(UInt16(flags & 0xffff)); b.d += body
        return box(type, b.d)
    }
}

struct Reader {
    let d: [UInt8]
    var p = 0
    init(_ d: [UInt8], at p: Int = 0) { self.d = d; self.p = p }
    var remaining: Int { d.count - p }
    mutating func u8() throws -> UInt8 { guard p < d.count else { throw MP4Error.truncated }; defer { p += 1 }; return d[p] }
    mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    mutating func u32() throws -> UInt32 { var v: UInt32 = 0; for _ in 0..<4 { v = v << 8 | UInt32(try u8()) }; return v }
    mutating func u64() throws -> UInt64 { var v: UInt64 = 0; for _ in 0..<8 { v = v << 8 | UInt64(try u8()) }; return v }
    mutating func skip(_ n: Int) throws { guard p + n <= d.count else { throw MP4Error.truncated }; p += n }
    mutating func bytes(_ n: Int) throws -> [UInt8] { guard p + n <= d.count else { throw MP4Error.truncated }; defer { p += n }; return Array(d[p..<p + n]) }
}

public enum MP4Error: LocalizedError {
    case truncated, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .truncated: return "The downloaded video is incomplete."
        case .invalid(let s): return "The downloaded video couldn't be read (\(s))."
        }
    }
}

// MARK: - Track model shared by the fMP4 and MPEG-TS readers

public struct SampleInfo: Sendable {
    var size: UInt32
    var duration: UInt32
    var cto: Int32
    var sync: Bool
}

/// A run of samples stored contiguously in a source file.
public struct ChunkRef: Sendable {
    var file: URL
    var offset: Int64
    var length: Int64
    var sampleCount: Int
    var decodeTime: Int64   // in track timescale
}

public struct MediaTrack: Sendable {
    public enum Kind: Sendable { case video, audio }
    var kind: Kind
    var timescale: UInt32
    var sampleEntry: [UInt8]      // full stsd box
    var width: UInt32 = 0         // 16.16 fixed
    var height: UInt32 = 0
    var language: UInt16 = 0x55C4 // "und"
    var startDelay: Double = 0    // seconds of empty edit before the track starts
    var mediaTime: Int64 = 0      // first presented media time (edit list)
    var samples: [SampleInfo] = []
    var chunks: [ChunkRef] = []
    var isAV1: Bool { sampleEntry.count > 20 && String(decoding: sampleEntry[12..<16], as: UTF8.self) == "av01" }

    var mediaDuration: UInt64 { samples.reduce(0) { $0 + UInt64($1.duration) } }

    /// End of the last presented frame on the media timeline (decode time + composition offset + duration).
    var compositionEnd: Int64 {
        var t: Int64 = 0, end: Int64 = 0
        for s in samples { end = max(end, t + Int64(s.cto) + Int64(s.duration)); t += Int64(s.duration) }
        return end
    }

    /// Presented length in seconds, after the edit list's start offset.
    var presentedSeconds: Double { Double(compositionEnd - mediaTime) / Double(timescale) }
}

// MARK: - Writer: standard (non-fragmented) MP4, moov first ("faststart")

public enum MP4Writer {
    static let movieTimescale: UInt32 = 1000

    public static func write(_ tracks: [MediaTrack], to url: URL, progress: ((Double) -> Void)? = nil) throws {
        let tracks = tracks.filter { !$0.samples.isEmpty }
        guard !tracks.isEmpty else { throw MP4Error.invalid("no media") }

        // Interleave chunks by time so players don't seek back and forth.
        var order: [(track: Int, chunk: Int, time: Double)] = []
        for (ti, t) in tracks.enumerated() {
            for (ci, c) in t.chunks.enumerated() { order.append((ti, ci, Double(c.decodeTime) / Double(t.timescale))) }
        }
        order.sort { $0.time != $1.time ? $0.time < $1.time : $0.track < $1.track }

        let ftyp = ftypBox(av1: tracks.contains { $0.isAV1 })
        let moovSize = moovBox(tracks, offsets: tracks.map { [UInt64](repeating: 0, count: $0.chunks.count) }).count
        var offsets = tracks.map { [UInt64](repeating: 0, count: $0.chunks.count) }
        var cursor = UInt64(ftyp.count + moovSize + 16)
        var mdatPayload: UInt64 = 0
        for o in order {
            offsets[o.track][o.chunk] = cursor
            let len = UInt64(tracks[o.track].chunks[o.chunk].length)
            cursor += len; mdatPayload += len
        }
        let moov = moovBox(tracks, offsets: offsets)
        precondition(moov.count == moovSize)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var header = Bytes(); header.u32(1); header.fourcc("mdat"); header.u64(16 + mdatPayload)
        try out.write(contentsOf: Data(ftyp + moov + header.d))

        var inputs: [URL: FileHandle] = [:]
        defer { inputs.values.forEach { try? $0.close() } }
        var copied: UInt64 = 0
        for o in order {
            let c = tracks[o.track].chunks[o.chunk]
            let input = try inputs[c.file] ?? FileHandle(forReadingFrom: c.file)
            inputs[c.file] = input
            try input.seek(toOffset: UInt64(c.offset))
            var left = c.length
            while left > 0 {
                guard let block = try input.read(upToCount: Int(min(left, 1 << 20))), !block.isEmpty else { throw MP4Error.truncated }
                try out.write(contentsOf: block)
                left -= Int64(block.count)
            }
            copied += UInt64(c.length)
            progress?(Double(copied) / Double(max(mdatPayload, 1)))
        }
    }

    static func ftypBox(av1: Bool) -> [UInt8] {
        var b = Bytes()
        b.fourcc("isom"); b.u32(0x200)
        for brand in ["isom", "iso2", "mp41", av1 ? "av01" : "avc1"] { b.fourcc(brand) }
        return Bytes.box("ftyp", b.d)
    }

    static func presentationDuration(_ t: MediaTrack) -> UInt64 {
        UInt64(max(0, (t.presentedSeconds + t.startDelay) * Double(movieTimescale)).rounded())
    }

    static func moovBox(_ tracks: [MediaTrack], offsets: [[UInt64]]) -> [UInt8] {
        var mvhd = Bytes()
        mvhd.u32(0); mvhd.u32(0); mvhd.u32(movieTimescale)
        mvhd.u32(UInt32(min(tracks.map(presentationDuration).max() ?? 0, UInt64(UInt32.max))))
        mvhd.u32(0x0001_0000); mvhd.u16(0x0100); mvhd.zeros(10)
        matrix(&mvhd); mvhd.zeros(24); mvhd.u32(UInt32(tracks.count + 1))
        var body = Bytes.fullBox("mvhd", mvhd.d)
        for (i, t) in tracks.enumerated() { body += trak(t, id: UInt32(i + 1), offsets: offsets[i]) }
        return Bytes.box("moov", body)
    }

    static func matrix(_ b: inout Bytes) {
        for v: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { b.u32(v) }
    }

    static func trak(_ t: MediaTrack, id: UInt32, offsets: [UInt64]) -> [UInt8] {
        let dur = presentationDuration(t)
        var tkhd = Bytes()
        tkhd.u64(0); tkhd.u64(0); tkhd.u32(id); tkhd.u32(0); tkhd.u64(dur)
        tkhd.zeros(8); tkhd.u16(0); tkhd.u16(0); tkhd.u16(t.kind == .audio ? 0x0100 : 0); tkhd.u16(0)
        matrix(&tkhd); tkhd.u32(t.width); tkhd.u32(t.height)
        var trak = Bytes.fullBox("tkhd", version: 1, flags: 3, tkhd.d)

        // Always state the presented range when it differs from the media length (B-frames shift it),
        // otherwise AVFoundation trims the last frames.
        if t.startDelay > 0 || t.mediaTime != 0 || t.compositionEnd != Int64(t.mediaDuration) {
            var elst = Bytes()
            let entries: [(UInt64, Int64)] = (t.startDelay > 0 ? [(UInt64((t.startDelay * Double(movieTimescale)).rounded()), Int64(-1))] : [])
                + [(UInt64((t.presentedSeconds * Double(movieTimescale)).rounded()), t.mediaTime)]
            elst.u32(UInt32(entries.count))
            for (d, m) in entries { elst.u64(d); elst.u64(UInt64(bitPattern: m)); elst.u32(0x0001_0000) }
            trak += Bytes.box("edts", Bytes.fullBox("elst", version: 1, elst.d))
        }

        var mdhd = Bytes()
        mdhd.u64(0); mdhd.u64(0); mdhd.u32(t.timescale); mdhd.u64(t.mediaDuration); mdhd.u16(t.language); mdhd.u16(0)
        var hdlr = Bytes()
        hdlr.u32(0); hdlr.fourcc(t.kind == .video ? "vide" : "soun"); hdlr.zeros(12)
        hdlr.d += Array((t.kind == .video ? "VideoHandler" : "SoundHandler").utf8) + [0]

        let header = t.kind == .video
            ? Bytes.fullBox("vmhd", flags: 1, [UInt8](repeating: 0, count: 8))
            : Bytes.fullBox("smhd", [0, 0, 0, 0])
        var dref = Bytes(); dref.u32(1); dref.d += Bytes.fullBox("url ", flags: 1, [])
        let minf = header + Bytes.box("dinf", Bytes.fullBox("dref", dref.d)) + stbl(t, offsets: offsets)
        let mdia = Bytes.fullBox("mdhd", version: 1, mdhd.d) + Bytes.fullBox("hdlr", hdlr.d) + Bytes.box("minf", minf)
        trak += Bytes.box("mdia", mdia)
        return Bytes.box("trak", trak)
    }

    static func stbl(_ t: MediaTrack, offsets: [UInt64]) -> [UInt8] {
        var out = t.sampleEntry

        var runs: [(count: UInt32, delta: UInt32)] = []
        for s in t.samples {
            if let last = runs.last, last.delta == s.duration { runs[runs.count - 1].count += 1 } else { runs.append((1, s.duration)) }
        }
        var stts = Bytes(); stts.u32(UInt32(runs.count))
        for r in runs { stts.u32(r.count); stts.u32(r.delta) }
        out += Bytes.fullBox("stts", stts.d)

        if t.samples.contains(where: { $0.cto != 0 }) {
            var cruns: [(count: UInt32, off: Int32)] = []
            for s in t.samples {
                if let last = cruns.last, last.off == s.cto { cruns[cruns.count - 1].count += 1 } else { cruns.append((1, s.cto)) }
            }
            var ctts = Bytes(); ctts.u32(UInt32(cruns.count))
            for r in cruns { ctts.u32(r.count); ctts.u32(UInt32(bitPattern: r.off)) }
            out += Bytes.fullBox("ctts", version: t.samples.contains { $0.cto < 0 } ? 1 : 0, ctts.d)
        }

        if t.samples.contains(where: { !$0.sync }) {
            let syncs = t.samples.indices.filter { t.samples[$0].sync }
            var stss = Bytes(); stss.u32(UInt32(syncs.count))
            for i in syncs { stss.u32(UInt32(i + 1)) }
            out += Bytes.fullBox("stss", stss.d)
        }

        var stsc = Bytes()
        var entries: [(first: UInt32, count: UInt32)] = []
        for (i, c) in t.chunks.enumerated() where entries.last?.count != UInt32(c.sampleCount) {
            entries.append((UInt32(i + 1), UInt32(c.sampleCount)))
        }
        stsc.u32(UInt32(entries.count))
        for e in entries { stsc.u32(e.first); stsc.u32(e.count); stsc.u32(1) }
        out += Bytes.fullBox("stsc", stsc.d)

        var stsz = Bytes(); stsz.u32(0); stsz.u32(UInt32(t.samples.count))
        for s in t.samples { stsz.u32(s.size) }
        out += Bytes.fullBox("stsz", stsz.d)

        var co64 = Bytes(); co64.u32(UInt32(offsets.count))
        for o in offsets { co64.u64(o) }
        out += Bytes.fullBox("co64", co64.d)
        return Bytes.box("stbl", out)
    }
}
