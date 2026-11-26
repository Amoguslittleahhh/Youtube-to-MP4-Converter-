import Foundation

/// Minimal MPEG-TS demuxer for YouTube live HLS (H.264 + ADTS AAC) → sample tables for MP4Writer.
public enum TransportStream {
    struct Frame { var pts: Int64; var dts: Int64; var size: UInt32; var sync: Bool }

    final class ES {
        let url: URL
        let handle: FileHandle
        var buffer = Data()
        var written: Int64 = 0
        init(_ url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.url = url
            handle = try FileHandle(forWritingTo: url)
        }
        func append(_ bytes: [UInt8]) throws {
            buffer.append(contentsOf: bytes); written += Int64(bytes.count)
            if buffer.count > 1 << 20 { try flush() }
        }
        func flush() throws { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
    }

    public static func readTracks(_ url: URL, workDir: URL, width: Int, height: Int) throws -> [MediaTrack] {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let vES = try ES(workDir.appendingPathComponent("ts-video.es"))
        let aES = try ES(workDir.appendingPathComponent("ts-audio.es"))
        defer { try? vES.handle.close(); try? aES.handle.close() }

        var pmtPID: Int?, videoPID: Int?, audioPID: Int?
        var pes: [Int: [UInt8]] = [:]
        var sps: [UInt8]?, pps: [UInt8]?
        var video: [Frame] = [], audio: [Frame] = []
        var audioConfig: (aot: Int, sfi: Int, chan: Int)?
        var unwrapState: [Int: Int64] = [:]

        func unwrap(_ v: Int64, _ pid: Int) -> Int64 {
            guard let last = unwrapState[pid] else { unwrapState[pid] = v; return v }
            var x = v
            while x < last - (1 << 32) { x += 1 << 33 }
            while x > last + (1 << 32) { x -= 1 << 33 }
            unwrapState[pid] = x
            return x
        }

        func flushPES(_ pid: Int) throws {
            guard let p = pes[pid], p.count > 9, p[0] == 0, p[1] == 0, p[2] == 1 else { return }
            let flags = p[7] >> 6
            let hlen = Int(p[8])
            guard 9 + hlen <= p.count, flags & 2 != 0 else { return }
            func ts(_ o: Int) -> Int64 {
                Int64(p[o] >> 1 & 0x07) << 30 | Int64(p[o + 1]) << 22 | Int64(p[o + 2] >> 1) << 15 | Int64(p[o + 3]) << 7 | Int64(p[o + 4] >> 1)
            }
            let pts = unwrap(ts(9), pid * 2)
            let dts = flags == 3 ? unwrap(ts(14), pid * 2 + 1) : pts
            let payload = Array(p[(9 + hlen)...])
            if pid == videoPID {
                var sample: [UInt8] = []
                var sync = false
                for nal in splitNALs(payload) where !nal.isEmpty {
                    switch nal[0] & 0x1F {
                    case 7: if sps == nil { sps = nal }
                    case 8: if pps == nil { pps = nal }
                    case 9, 12: break   // access unit delimiter, filler
                    default:
                        if nal[0] & 0x1F == 5 { sync = true }
                        let n = UInt32(nal.count)
                        sample += [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + nal
                    }
                }
                guard !sample.isEmpty else { return }
                try vES.append(sample)
                video.append(Frame(pts: pts, dts: dts, size: UInt32(sample.count), sync: sync))
            } else if pid == audioPID {
                var i = 0, k: Int64 = 0
                while i + 7 <= payload.count, payload[i] == 0xFF, payload[i + 1] & 0xF0 == 0xF0 {
                    let headerLen = payload[i + 1] & 1 == 1 ? 7 : 9
                    let sfi = Int(payload[i + 2] >> 2 & 0x0F)
                    let len = Int(payload[i + 3] & 3) << 11 | Int(payload[i + 4]) << 3 | Int(payload[i + 5] >> 5)
                    guard len > headerLen, i + len <= payload.count, sfi < sampleRates.count else { break }
                    if audioConfig == nil {
                        audioConfig = (Int(payload[i + 2] >> 6) + 1, sfi, Int(payload[i + 2] & 1) << 2 | Int(payload[i + 3] >> 6))
                    }
                    let raw = Array(payload[(i + headerLen)..<(i + len)])
                    try aES.append(raw)
                    let t = pts + k * 1024 * 90000 / Int64(sampleRates[sfi])
                    audio.append(Frame(pts: t, dts: t, size: UInt32(raw.count), sync: true))
                    i += len; k += 1
                }
            }
        }

        var carry = Data()
        while let block = try input.read(upToCount: 188 * 4096), !block.isEmpty {
            carry.append(block)
            let bytes = [UInt8](carry)
            var i = 0
            while i + 188 <= bytes.count {
                guard bytes[i] == 0x47 else { i += 1; continue }   // resync
                let pusi = bytes[i + 1] & 0x40 != 0
                let pid = Int(bytes[i + 1] & 0x1F) << 8 | Int(bytes[i + 2])
                let afc = bytes[i + 3] >> 4 & 3
                var start = i + 4
                if afc & 2 != 0 { start += 1 + Int(bytes[i + 4]) }
                if afc & 1 != 0, start < i + 188 {
                    let payload = Array(bytes[start..<(i + 188)])
                    if pid == 0, pusi, pmtPID == nil {
                        let s = 1 + Int(payload[0])
                        if s + 12 <= payload.count { pmtPID = Int(payload[s + 10] & 0x1F) << 8 | Int(payload[s + 11]) }
                    } else if pid == pmtPID, pusi, videoPID == nil && audioPID == nil {
                        let s = 1 + Int(payload[0])
                        if s + 12 <= payload.count {
                            let sectionEnd = min(payload.count, s + 3 + (Int(payload[s + 1] & 0x0F) << 8 | Int(payload[s + 2])) - 4)
                            var j = s + 12 + (Int(payload[s + 10] & 0x0F) << 8 | Int(payload[s + 11]))
                            while j + 5 <= sectionEnd {
                                let type = payload[j]
                                let epid = Int(payload[j + 1] & 0x1F) << 8 | Int(payload[j + 2])
                                if type == 0x1B, videoPID == nil { videoPID = epid }
                                if type == 0x0F, audioPID == nil { audioPID = epid }
                                j += 5 + (Int(payload[j + 3] & 0x0F) << 8 | Int(payload[j + 4]))
                            }
                        }
                    } else if pid == videoPID || pid == audioPID {
                        if pusi { try flushPES(pid); pes[pid] = payload } else { pes[pid, default: []] += payload }
                    }
                }
                i += 188
            }
            carry = Data(bytes[i...])
        }
        for pid in [videoPID, audioPID].compactMap({ $0 }) { try flushPES(pid) }
        try vES.flush(); try aES.flush()

        var tracks: [MediaTrack] = []
        let videoStart = video.map(\.pts).min()
        let audioStart = audio.first?.pts
        let globalStart = [videoStart, audioStart].compactMap { $0 }.min() ?? 0

        if let sps, let pps, sps.count >= 4, !video.isEmpty {
            var t = MediaTrack(kind: .video, timescale: 90000, sampleEntry: avc1Entry(sps: sps, pps: pps, width: width, height: height),
                               width: UInt32(width) << 16, height: UInt32(height) << 16)
            let dts0 = video[0].dts
            for (i, f) in video.enumerated() {
                let next = i + 1 < video.count ? video[i + 1].dts : f.dts + (i > 0 ? f.dts - video[i - 1].dts : 3000)
                t.samples.append(SampleInfo(size: f.size, duration: UInt32(clamping: max(1, next - f.dts)),
                                            cto: Int32(clamping: f.pts - f.dts), sync: f.sync))
            }
            t.chunks = chunks(frames: video, file: vES.url, perChunk: 30, base: dts0, scale: { $0 })
            t.mediaTime = (videoStart ?? dts0) - dts0
            t.startDelay = Double((videoStart ?? globalStart) - globalStart) / 90000
            tracks.append(t)
        }
        if let cfg = audioConfig, !audio.isEmpty {
            let rate = sampleRates[cfg.sfi]
            var t = MediaTrack(kind: .audio, timescale: UInt32(rate), sampleEntry: mp4aEntry(aot: cfg.aot, sfi: cfg.sfi, channels: cfg.chan, rate: rate))
            t.samples = audio.map { SampleInfo(size: $0.size, duration: 1024, cto: 0, sync: true) }
            let a0 = audio[0].dts
            t.chunks = chunks(frames: audio, file: aES.url, perChunk: 45, base: a0, scale: { $0 * Int64(rate) / 90000 })
            t.startDelay = Double(a0 - globalStart) / 90000
            tracks.append(t)
        }
        guard !tracks.isEmpty else { throw MP4Error.invalid("no H.264/AAC in live stream") }
        return tracks
    }

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    static func chunks(frames: [Frame], file: URL, perChunk: Int, base: Int64, scale: (Int64) -> Int64) -> [ChunkRef] {
        var out: [ChunkRef] = []
        var offset: Int64 = 0
        for start in stride(from: 0, to: frames.count, by: perChunk) {
            let slice = frames[start..<min(start + perChunk, frames.count)]
            let len = slice.reduce(Int64(0)) { $0 + Int64($1.size) }
            out.append(ChunkRef(file: file, offset: offset, length: len, sampleCount: slice.count, decodeTime: scale(slice.first!.dts - base)))
            offset += len
        }
        return out
    }

    static func splitNALs(_ d: [UInt8]) -> [[UInt8]] {
        var nals: [[UInt8]] = []
        var i = 0, start = -1
        while i + 2 < d.count {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, d[end - 1] == 0 { end -= 1 }   // trailing zero of a 4-byte start code
                    nals.append(Array(d[start..<end]))
                }
                i += 3; start = i
            } else { i += 1 }
        }
        if start >= 0, start < d.count { nals.append(Array(d[start...])) }
        return nals
    }

    static func avc1Entry(sps: [UInt8], pps: [UInt8], width: Int, height: Int) -> [UInt8] {
        var avcC = Bytes()
        avcC.u8(1); avcC.u8(sps[1]); avcC.u8(sps[2]); avcC.u8(sps[3]); avcC.u8(0xFF); avcC.u8(0xE1)
        avcC.u16(UInt16(sps.count)); avcC.d += sps
        avcC.u8(1); avcC.u16(UInt16(pps.count)); avcC.d += pps
        var e = Bytes()
        e.zeros(6); e.u16(1); e.zeros(16); e.u16(UInt16(width)); e.u16(UInt16(height))
        e.u32(0x0048_0000); e.u32(0x0048_0000); e.u32(0); e.u16(1); e.zeros(32); e.u16(0x0018); e.u16(0xFFFF)
        e.d += Bytes.box("avcC", avcC.d)
        var stsd = Bytes(); stsd.u32(1); stsd.d += Bytes.box("avc1", e.d)
        return Bytes.fullBox("stsd", stsd.d)
    }

    static func mp4aEntry(aot: Int, sfi: Int, channels: Int, rate: Int) -> [UInt8] {
        let asc = UInt16(aot << 11 | sfi << 7 | channels << 3)
        func desc(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
        var dcd = Bytes()
        dcd.u8(0x40); dcd.u8(0x15); dcd.u8(0); dcd.u16(0); dcd.u32(0); dcd.u32(0)
        dcd.d += desc(0x05, [UInt8(asc >> 8), UInt8(asc & 0xff)])
        var es = Bytes(); es.u16(1); es.u8(0)
        es.d += desc(0x04, dcd.d) + desc(0x06, [0x02])
        var e = Bytes()
        e.zeros(6); e.u16(1); e.zeros(8); e.u16(UInt16(max(channels, 1))); e.u16(16); e.u16(0); e.u16(0); e.u32(UInt32(rate) << 16)
        e.d += Bytes.fullBox("esds", desc(0x03, es.d))
        var stsd = Bytes(); stsd.u32(1); stsd.d += Bytes.box("mp4a", e.d)
        return Bytes.fullBox("stsd", stsd.d)
    }
}
