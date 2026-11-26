#if canImport(AVFoundation) && canImport(JavaScriptCore)
import XCTest
import AVFoundation
@testable import Core

/// Runs on the macOS CI runner (not Linux): the real JavaScriptCore solver and the AVFoundation transcoder.
final class AppleTests: XCTestCase {
    func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)") }

    /// Downloads YouTube's current TV player and solves n/sig challenges exactly like the app does.
    func testSolverAgainstLivePlayer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("solver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let extractor = YouTubeExtractor(cookies: nil, solver: nil, cacheDir: dir)
        let player = try await extractor.playerJS(page: nil, variant: ClientConfig.builtIn.playerJSVariant)
        XCTAssertGreaterThan(player.sts, 19000)

        let solver = JSChallengeSolver(cacheDir: dir)
        let n = "ZdZIqFPQK-Ty8wId"
        let sig = String(repeating: "AOq0QJ8wRgIhAL-_xyz0123456789", count: 4)
        let first = try solver.solve(playerID: player.id, player: player.code, n: [n], sig: [sig])
        let solvedN = try XCTUnwrap(first.n[n]); let solvedSig = try XCTUnwrap(first.sig[sig])
        XCTAssertFalse(solvedN.isEmpty); XCTAssertNotEqual(solvedN, n)
        XCTAssertFalse(solvedSig.isEmpty); XCTAssertNotEqual(solvedSig, sig)

        // second run uses the cached preprocessed player and must agree
        let second = try solver.solve(playerID: player.id, player: player.code, n: [n], sig: [sig])
        XCTAssertEqual(second.n[n], solvedN)
        XCTAssertEqual(second.sig[sig], solvedSig)
    }

    func testTranscodeToH264KeepsAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let muxed = dir.appendingPathComponent("in.mp4"), out = dir.appendingPathComponent("out.mp4")
        try FragmentedMP4.mux(video: fixture("v264_moof.mp4"), audio: fixture("a_aac.mp4"), to: muxed)
        try await Transcoder.toH264(input: muxed, output: out) { _ in }

        let asset = AVURLAsset(url: out)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let codec = try await video[0].load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        XCTAssertEqual(codec, kCMVideoCodecType_H264)
        XCTAssertEqual(try await video[0].load(.naturalSize), CGSize(width: 320, height: 240))
        XCTAssertEqual(try await asset.load(.duration).seconds, 3.0, accuracy: 0.2)
    }

    /// AVFoundation itself must accept our muxer's output (what Photos and WhatsApp use).
    func testAVFoundationReadsMuxedFile() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("av-\(UUID().uuidString).mp4")
        try FragmentedMP4.mux(video: fixture("v264_bdo.mp4"), audio: fixture("a_aac.mp4"), to: out)
        let asset = AVURLAsset(url: out)
        XCTAssertTrue(try await asset.load(.isPlayable))
        XCTAssertEqual(try await asset.load(.duration).seconds, 3.0, accuracy: 0.1)
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(frames, 90)
    }
}
#endif
