import Foundation

public enum FormatSelector {
    public static let maxResolution = 2160

    /// One option per resolution/fps, best first. H.264 is preferred (no conversion needed);
    /// AV1 is used only where YouTube has no H.264 (1440p/2160p) and the device can decode it.
    public static func options(for info: VideoInfo, av1Decodable: Bool) -> [QualityOption] {
        guard let audio = bestAudio(info.formats) else { return [] }
        let videos = info.formats.filter {
            $0.isVideo && $0.container == "video/mp4" && !$0.isHDR
                && ($0.isH264 || ($0.isAV1 && av1Decodable))
                && $0.resolutionClass > 0 && $0.resolutionClass <= maxResolution
        }
        var best: [String: StreamFormat] = [:]
        for v in videos {
            let key = "\(v.resolutionClass)x\(v.fps ?? 30)"
            if let cur = best[key] {
                if better(v, than: cur) { best[key] = v }
            } else {
                best[key] = v
            }
        }
        return best.values
            .sorted { ($0.resolutionClass, $0.fps ?? 30) > ($1.resolutionClass, $1.fps ?? 30) }
            .map { QualityOption(video: $0, audio: audio, duration: info.duration) }
    }

    static func better(_ a: StreamFormat, than b: StreamFormat) -> Bool {
        if a.isH264 != b.isH264 { return a.isH264 }
        return a.bitrate > b.bitrate
    }

    public static func bestAudio(_ formats: [StreamFormat]) -> StreamFormat? {
        formats
            .filter { $0.isAudio && $0.container == "audio/mp4" && $0.isAAC }
            .max { a, b in
                // original/default language first, then non-DRC, then bitrate
                ((a.audioIsDefault ?? true) ? 1 : 0, a.isDRC ? 0 : 1, a.bitrate)
                    < ((b.audioIsDefault ?? true) ? 1 : 0, b.isDRC ? 0 : 1, b.bitrate)
            }
    }
}
