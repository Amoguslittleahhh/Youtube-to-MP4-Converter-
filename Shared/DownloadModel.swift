import SwiftUI
import Core

@MainActor @Observable
final class DownloadModel {
    enum Phase: Equatable {
        case loading
        case ready
        case working(title: String, detail: String, progress: Double?)
        case done(URL)
        case failed(String, needsSignIn: Bool)
    }

    let videoID: String
    let inExtension: Bool
    var info: VideoInfo?
    var options: [QualityOption] = []
    var liveVariants: [LiveVariant] = []
    var selectedItag: Int?
    var selectedLive: LiveVariant?
    var phase: Phase = .loading
    var savedToPhotos = false
    var message: String?

    private var preselect: String?
    private var autostart: Bool
    private var job: Task<Void, Never>?
    private var stopFlag = StopFlag()
    private let workDir: URL

    init(videoID: String, inExtension: Bool, preselect: String? = nil, autostart: Bool = false) {
        self.videoID = videoID
        self.inExtension = inExtension
        self.preselect = preselect
        self.autostart = autostart
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("job-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    var isBusy: Bool { if case .working = phase { return true }; return false }
    var isLive: Bool { info?.isLive ?? false }
    var selected: QualityOption? { options.first { $0.video.itag == selectedItag } }

    /// In the share extension, 1440p/4K conversion and live recording run in the app (no extension memory/time limits).
    var mustContinueInApp: Bool { inExtension && (isLive || (selected?.needsConversion ?? false)) }

    var selectionKey: String? { isLive ? selectedLive?.label : selectedItag.map(String.init) }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let extractor = YouTubeExtractor(cookies: AccountStore.load(), solver: JSChallengeSolver(cacheDir: caches), cacheDir: caches)
            let info = try await extractor.extract(videoID)
            self.info = info
            if info.isLive, let hls = info.hlsManifestURL {
                liveVariants = try await HLS.variants(master: hls, headers: info.mediaHeaders)
                guard !liveVariants.isEmpty else { throw ExtractionError.noFormats }
                selectedLive = liveVariants.first { $0.label == preselect } ?? liveVariants.first
            } else {
                options = FormatSelector.options(for: info, av1Decodable: Device.av1Decodable)
                guard !options.isEmpty else { throw ExtractionError.noFormats }
                selectedItag = options.first { String($0.video.itag) == preselect }?.video.itag ?? options.first?.video.itag
            }
            phase = .ready
            if autostart { autostart = false; start() }
        } catch {
            fail(error)
        }
    }

    // MARK: Work

    func start() {
        guard let info else { return }
        savedToPhotos = false
        stopFlag = StopFlag()
        if isLive, let variant = selectedLive {
            job = Task { await record(info, variant) }
        } else if let option = selected {
            job = Task { await download(info, option) }
        }
    }

    func cancel() { job?.cancel(); stopFlag.stop() }
    func stopRecording() { stopFlag.stop() }

    private var outputURL: URL {
        let name = (info?.title ?? "video")
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(80)
        return workDir.appendingPathComponent((name.isEmpty ? "video" : String(name)) + ".mp4")
    }

    private func download(_ info: VideoInfo, _ option: QualityOption) async {
        let total = Double(max((option.video.contentLength ?? 0) + (option.audio.contentLength ?? 0), 1))
        let counter = ByteCounter()
        let videoPart = workDir.appendingPathComponent("video.part"), audioPart = workDir.appendingPathComponent("audio.part")
        let muxed = option.needsConversion ? workDir.appendingPathComponent("source.mp4") : outputURL
        let output = outputURL
        phase = .working(title: "Downloading", detail: option.label, progress: 0)
        do {
            let report: @Sendable (Int64) -> Void = { n in
                let done = counter.add(n)
                Task { @MainActor in
                    self.phase = .working(title: "Downloading", detail: "\(Self.bytes(done)) of \(Self.bytes(Int64(total)))", progress: min(Double(done) / total, 1))
                }
            }
            async let v: Void = Downloader.download(option.video.url, length: option.video.contentLength, headers: info.mediaHeaders, to: videoPart, progress: report)
            async let a: Void = Downloader.download(option.audio.url, length: option.audio.contentLength, headers: info.mediaHeaders, to: audioPart, progress: report)
            _ = try await (v, a)

            phase = .working(title: "Finishing", detail: "Building MP4…", progress: nil)
            try await Task.detached { try FragmentedMP4.mux(video: videoPart, audio: audioPart, to: muxed) }.value
            try? FileManager.default.removeItem(at: videoPart); try? FileManager.default.removeItem(at: audioPart)

            if option.needsConversion {
                phase = .working(title: "Converting for WhatsApp", detail: "\(option.label) → H.264", progress: 0)
                try await Transcoder.toH264(input: muxed, output: output) { p in
                    Task { @MainActor in self.phase = .working(title: "Converting for WhatsApp", detail: "\(option.label) → H.264", progress: p) }
                }
                try? FileManager.default.removeItem(at: muxed)
            }
            phase = .done(output)
        } catch {
            fail(error)
        }
    }

    private func record(_ info: VideoInfo, _ variant: LiveVariant) async {
        phase = .working(title: "Recording live", detail: "Waiting for the stream…", progress: nil)
        let output = outputURL
        do {
            try await HLS.record(variant, headers: info.mediaHeaders, workDir: workDir, output: output, stop: stopFlag) { seconds, bytes in
                Task { @MainActor in
                    if case .working(let t, _, _) = self.phase, t != "Recording live" { return }
                    self.phase = .working(title: "Recording live", detail: "\(Self.clock(seconds)) · \(Self.bytes(bytes))", progress: nil)
                }
            }
            phase = .done(output)
        } catch {
            fail(error)
        }
    }

    func finishRecordingTapped() {
        stopRecording()
        phase = .working(title: "Saving recording", detail: "Building MP4…", progress: nil)
    }

    private func fail(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            phase = info == nil ? .loading : .ready
            return
        }
        if case ExtractionError.needsSignIn = error {
            phase = .failed(error.localizedDescription, needsSignIn: true)
        } else {
            phase = .failed(error.localizedDescription, needsSignIn: false)
        }
    }

    // MARK: Saving

    func saveToPhotos(_ url: URL) async {
        do {
            try await PhotoSaver.save(url)
            savedToPhotos = true
            message = "Saved to Photos"
        } catch {
            message = error.localizedDescription
        }
    }

    /// A copy for the Files mover (it moves the file, and we keep ours for Photos/Share).
    func exportCopy(_ url: URL) -> URL? {
        let dir = workDir.appendingPathComponent("export-\(UUID().uuidString)")
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func cleanUp() { cancel(); try? FileManager.default.removeItem(at: workDir) }

    // MARK: Formatting

    nonisolated static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    nonisolated static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ n: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; value += n; return value }
}
