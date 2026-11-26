import Foundation

/// Reads fragmented MP4 (YouTube DASH streams, HLS fMP4) into sample tables without loading media data.
public enum FragmentedMP4 {
    struct Box { var type: String; var start: Int; var bodyStart: Int; var end: Int }

    static func children(_ d: [UInt8], _ from: Int, _ to: Int) throws -> [Box] {
        var out: [Box] = []
        var p = from
        while p + 8 <= to {
            var r = Reader(d, at: p)
            var size = Int(try r.u32())
            let type = String(decoding: try r.bytes(4), as: UTF8.self)
            var header = 8
            if size == 1 { size = Int(try r.u64()); header = 16 } else if size == 0 { size = to - p }
            guard size >= header, p + size <= to else { throw MP4Error.invalid("box \(type)") }
            out.append(Box(type: type, start: p, bodyStart: p + header, end: p + size))
            p += size
        }
        return out
    }

    struct Trex { var duration: UInt32 = 0; var size: UInt32 = 0; var flags: UInt32 = 0 }

    public static func readTracks(_ url: URL) throws -> [MediaTrack] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let fileSize = Int64(try fh.seekToEnd())

        var order: [UInt32] = []
        var tracks: [UInt32: MediaTrack] = [:]
        var trex: [UInt32: Trex] = [:]
        var nextDecode: [UInt32: Int64] = [:]

        var offset: Int64 = 0
        while offset + 8 <= fileSize {
            try fh.seek(toOffset: UInt64(offset))
            let head = Array(try fh.read(upToCount: 16) ?? Data())
            guard head.count >= 8 else { break }
            var r = Reader(head)
            var size = Int64(try r.u32())
            let type = String(decoding: try r.bytes(4), as: UTF8.self)
            if size == 1 { size = Int64(try r.u64()) } else if size == 0 { size = fileSize - offset }
            guard size >= 8, offset + size <= fileSize else {
                if type == "mdat" || type == "free" { break }  // tolerate a truncated trailing box
                throw MP4Error.truncated
            }
            if type == "moov" || type == "moof" {
                try fh.seek(toOffset: UInt64(offset))
                guard let data = try fh.read(upToCount: Int(size)), data.count == Int(size) else { throw MP4Error.truncated }
                let d = Array(data)
                let body = try children(d, 0, d.count)[0]
                if type == "moov" {
                    try parseMoov(d, body, order: &order, tracks: &tracks, trex: &trex)
                } else {
                    try parseMoof(d, body, moofOffset: offset, url: url, tracks: &tracks, trex: trex, nextDecode: &nextDecode)
                }
            }
            offset += size
        }
        return order.compactMap { tracks[$0] }.filter { !$0.samples.isEmpty }
    }

    static func parseMoov(_ d: [UInt8], _ moov: Box, order: inout [UInt32], tracks: inout [UInt32: MediaTrack], trex: inout [UInt32: Trex]) throws {
        var movieTimescale: UInt32 = 1000
        let kids = try children(d, moov.bodyStart, moov.end)
        if let mvhd = kids.first(where: { $0.type == "mvhd" }) {
            var r = Reader(d, at: mvhd.bodyStart)
            let v = try r.u8(); try r.skip(3 + (v == 1 ? 16 : 8))
            movieTimescale = try r.u32()
        }
        for box in kids {
            if box.type == "mvex" {
                for t in try children(d, box.bodyStart, box.end) where t.type == "trex" {
                    var r = Reader(d, at: t.bodyStart)
                    try r.skip(4)
                    let id = try r.u32(); try r.skip(4)
                    trex[id] = Trex(duration: try r.u32(), size: try r.u32(), flags: try r.u32())
                }
            }
            guard box.type == "trak" else { continue }
            var id: UInt32 = 0, width: UInt32 = 0, height: UInt32 = 0
            var timescale: UInt32 = 0, language: UInt16 = 0x55C4, handler = "", stsd: [UInt8] = []
            var startDelay = 0.0, mediaTime: Int64 = 0
            for c in try children(d, box.bodyStart, box.end) {
                switch c.type {
                case "tkhd":
                    var r = Reader(d, at: c.bodyStart)
                    let v = try r.u8(); try r.skip(3 + (v == 1 ? 16 : 8))
                    id = try r.u32()
                    var wr = Reader(d, at: c.end - 8)
                    width = try wr.u32(); height = try wr.u32()
                case "edts":
                    for e in try children(d, c.bodyStart, c.end) where e.type == "elst" {
                        var r = Reader(d, at: e.bodyStart)
                        let v = try r.u8(); try r.skip(3)
                        var foundMedia = false
                        for _ in 0..<(try r.u32()) {
                            let dur = v == 1 ? Int64(bitPattern: try r.u64()) : Int64(try r.u32())
                            let mt = v == 1 ? Int64(bitPattern: try r.u64()) : Int64(Int32(bitPattern: try r.u32()))
                            try r.skip(4)
                            if foundMedia { break }
                            if mt == -1 { startDelay += Double(dur) / Double(movieTimescale) } else { mediaTime = mt; foundMedia = true }
                        }
                    }
                case "mdia":
                    for m in try children(d, c.bodyStart, c.end) {
                        if m.type == "mdhd" {
                            var r = Reader(d, at: m.bodyStart)
                            let v = try r.u8(); try r.skip(3 + (v == 1 ? 16 : 8))
                            timescale = try r.u32(); try r.skip(v == 1 ? 8 : 4)
                            language = try r.u16()
                        } else if m.type == "hdlr" {
                            handler = String(decoding: d[(m.bodyStart + 8)..<(m.bodyStart + 12)], as: UTF8.self)
                        } else if m.type == "minf" {
                            for s in try children(d, m.bodyStart, m.end) where s.type == "stbl" {
                                if let box = try children(d, s.bodyStart, s.end).first(where: { $0.type == "stsd" }) {
                                    stsd = Array(d[box.start..<box.end])
                                }
                            }
                        }
                    }
                default: break
                }
            }
            guard handler == "vide" || handler == "soun", timescale > 0, !stsd.isEmpty else { continue }
            order.append(id)
            tracks[id] = MediaTrack(kind: handler == "vide" ? .video : .audio, timescale: timescale, sampleEntry: stsd,
                                    width: width, height: height, language: language, startDelay: startDelay, mediaTime: mediaTime)
        }
    }

    static func parseMoof(_ d: [UInt8], _ moof: Box, moofOffset: Int64, url: URL, tracks: inout [UInt32: MediaTrack],
                          trex: [UInt32: Trex], nextDecode: inout [UInt32: Int64]) throws {
        var previousTrafEnd = moofOffset
        for traf in try children(d, moof.bodyStart, moof.end) where traf.type == "traf" {
            let kids = try children(d, traf.bodyStart, traf.end)
            guard let tfhd = kids.first(where: { $0.type == "tfhd" }) else { continue }
            var r = Reader(d, at: tfhd.bodyStart)
            let tfFlags = try r.u32() & 0xFFFFFF
            let id = try r.u32()
            guard var track = tracks[id] else { continue }
            let defaults = trex[id] ?? Trex()
            var base: Int64 = tfFlags & 0x20000 != 0 ? moofOffset : previousTrafEnd
            if tfFlags & 0x1 != 0 { base = Int64(bitPattern: try r.u64()) }
            if tfFlags & 0x2 != 0 { try r.skip(4) }
            let defDuration = tfFlags & 0x8 != 0 ? try r.u32() : defaults.duration
            let defSize = tfFlags & 0x10 != 0 ? try r.u32() : defaults.size
            let defFlags = tfFlags & 0x20 != 0 ? try r.u32() : defaults.flags

            var decode = nextDecode[id] ?? 0
            if let tfdt = kids.first(where: { $0.type == "tfdt" }) {
                var tr = Reader(d, at: tfdt.bodyStart)
                let v = try tr.u8(); try tr.skip(3)
                decode = v == 1 ? Int64(bitPattern: try tr.u64()) : Int64(try tr.u32())
            }

            var dataCursor = base
            for trun in kids where trun.type == "trun" {
                var t = Reader(d, at: trun.bodyStart)
                let version = try t.u8()
                let f = UInt32(try t.u8()) << 16 | UInt32(try t.u16())
                let count = Int(try t.u32())
                if f & 0x1 != 0 { dataCursor = base + Int64(Int32(bitPattern: try t.u32())) }
                let firstFlags: UInt32? = f & 0x4 != 0 ? try t.u32() : nil
                guard count > 0 else { continue }
                let chunkStart = dataCursor
                let chunkDecode = decode
                var length: Int64 = 0
                for i in 0..<count {
                    let dur = f & 0x100 != 0 ? try t.u32() : defDuration
                    let size = f & 0x200 != 0 ? try t.u32() : defSize
                    var flags = f & 0x400 != 0 ? try t.u32() : defFlags
                    if i == 0, let firstFlags { flags = firstFlags }
                    let raw = f & 0x800 != 0 ? try t.u32() : 0
                    let cto = version == 0 ? Int32(clamping: Int64(raw)) : Int32(bitPattern: raw)
                    let sync = track.kind == .audio || (flags >> 16) & 1 == 0
                    track.samples.append(SampleInfo(size: size, duration: dur, cto: cto, sync: sync))
                    length += Int64(size)
                    decode += Int64(dur)
                }
                track.chunks.append(ChunkRef(file: url, offset: chunkStart, length: length, sampleCount: count, decodeTime: chunkDecode))
                dataCursor = chunkStart + length
            }
            nextDecode[id] = decode
            previousTrafEnd = dataCursor
            tracks[id] = track
        }
    }

    /// Merges YouTube's separate video and audio downloads into one faststart MP4.
    public static func mux(video: URL, audio: URL, to output: URL, progress: ((Double) -> Void)? = nil) throws {
        let v = try readTracks(video).filter { $0.kind == .video }
        let a = try readTracks(audio).filter { $0.kind == .audio }
        guard let vt = v.first, let at = a.first else { throw MP4Error.invalid("missing video or audio track") }
        try MP4Writer.write([vt, at], to: output, progress: progress)
    }
}
