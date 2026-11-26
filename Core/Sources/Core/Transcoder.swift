#if canImport(AVFoundation)
import AVFoundation

/// Re-encodes the video track to H.264 (hardware) and copies the AAC audio, producing an MP4 that every
/// messaging app (WhatsApp, iMessage, Telegram, Discord…) can play. Used for YouTube's AV1-only 1440p/4K.
public enum Transcoder {
    public static func toH264(input: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw fail("No video track") }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let size = try await vTrack.load(.naturalSize)
        let fps = try await vTrack.load(.nominalFrameRate)
        let transform = try await vTrack.load(.preferredTransform)
        let audioFormat = try await aTrack?.load(.formatDescriptions).first

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let aTrack {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)   // passthrough
            o.alwaysCopiesSampleData = false
            reader.add(o); aOut = o
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // moov first: instant previews in chat apps
        let w = Int(size.width), h = Int(size.height), rate = Int(fps.rounded())
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Transcode.bitrate(width: w, height: h, fps: rate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: max(rate, 1),
                AVVideoMaxKeyFrameIntervalKey: max(rate, 1) * 2,
            ],
        ])
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            i.expectsMediaDataInRealTime = false
            writer.add(i); aIn = i
        }

        guard reader.startReading() else { throw reader.error ?? fail("Couldn't read the video") }
        guard writer.startWriting() else { throw writer.error ?? fail("Couldn't write the video") }
        writer.startSession(atSourceTime: .zero)

        let cancelled = StopFlag()
        try await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump(vOut, into: vIn, label: "video", cancelled: cancelled) { t in progress(min(t / max(duration, 0.001), 1)) } }
                if let aOut, let aIn { group.addTask { await pump(aOut, into: aIn, label: "audio", cancelled: cancelled, onTime: nil) } }
            }
        } onCancel: { cancelled.stop() }

        if cancelled.isStopped || Task.isCancelled {
            reader.cancelReading(); writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? fail("Reading failed") }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? fail("Conversion failed") }
    }

    private static func pump(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String,
                             cancelled: StopFlag, onTime: ((Double) -> Void)?) async {
        let queue = DispatchQueue(label: "transcode.\(label)")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finished = StopFlag()
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished.isStopped else { return }
                while input.isReadyForMoreMediaData {
                    if cancelled.isStopped { finished.stop(); input.markAsFinished(); done.resume(); return }
                    guard let buffer = output.copyNextSampleBuffer() else {
                        finished.stop(); input.markAsFinished(); done.resume(); return
                    }
                    if !input.append(buffer) {
                        finished.stop(); done.resume(); return
                    }
                    onTime?(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                }
            }
        }
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "YTMP4", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
