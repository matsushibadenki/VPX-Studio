import XCTest
import AVFoundation
import Metal
import VPXCaptureProtocol
import simd
@testable import VPXStudio

final class CameraTakeRecorderTests: XCTestCase {
    @MainActor
    func testMain10TakeVerifiesEncodedDepthAndRejectsEightBitInput() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let studio = StudioModel()
        let sourceID = UUID()
        let plugin = TakeProvenance.Plugin(name: "Test capture plug-in", version: "1.2.3")
        try studio.realtimeCore.attach(PluginTestSource(id: sourceID, plugin: plugin))
        try studio.realtimeCore.attach(PluginTestSource(id: UUID(), plugin: .init(name: "Unused", version: "9")))
        let request = try studio.takeSnapshotRequest(recordingSourceID: sourceID)
        XCTAssertEqual(request.manifest.provenance?.plugins, [plugin])
        XCTAssertNil(try studio.takeSnapshotRequest().manifest.provenance?.plugins)
        let recorder = try CameraTakeRecorder(request: request, parent: parent,
            sourceID: sourceID, preserve10Bit: true)
        let store = LatestVideoFrameStore()
        store.selectSource(sourceID)
        store.observeLocalInputLoss(.droppedFrame, sourceID: sourceID)
        XCTAssertTrue(store.startRecording(recorder, sourceID: sourceID, tracksLocalInputLoss: true))
        store.observeLocalInputLoss(.droppedFrame, sourceID: UUID())
        store.observeLocalInputLoss(.droppedFrame, sourceID: sourceID)
        store.observeLocalInputLoss(.discontinuity, sourceID: sourceID)
        store.observeLocalInputLoss(.unknownReason, sourceID: sourceID)
        recorder.dropVideoFrame()
        let buffer = try recordingBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        for index in 0..<2 {
            recorder.submitVideo(buffer, at: CMTime(value: Int64(index), timescale: 30))
        }
        _ = store.stopRecording()
        store.observeLocalInputLoss(.droppedFrame, sourceID: sourceID)
        let url = try await recorder.finish()
        let review = try await TakeReviewService().inspect(directory: url)
        XCTAssertTrue(review.allVerified)
        XCTAssertEqual(review.manifest.provenance?.plugins, [plugin])
        let statsURL = url.appendingPathComponent("recording.json")
        let stats = try JSONDecoder().decode(CameraTakeRecorder.Statistics.self, from: Data(contentsOf: statsURL))
        XCTAssertEqual(stats.encodedBitDepth, 10)
        XCTAssertEqual(stats.frames, 2)
        let loss = TakeProvenance.Recording.LocalInputLoss(droppedFrames: 1, discontinuities: 1, unknownReasonEvents: 1)
        XCTAssertEqual(stats.localInputLoss, loss)
        XCTAssertEqual(stats.dropped, 1)
        XCTAssertEqual(review.manifest.provenance?.recording?.localInputLoss, loss)
        XCTAssertEqual(review.manifest.provenance?.recording?.recorderDrops, 1)

        let rejected = try CameraTakeRecorder(request: studio.takeSnapshotRequest(), parent: parent,
            sourceID: sourceID, preserve10Bit: true)
        rejected.submitVideo(try recordingBuffer(kCVPixelFormatType_32BGRA), at: .zero)
        do {
            _ = try await rejected.finish()
            XCTFail("An 8-bit input must not publish a Main10 Take")
        } catch CameraTakeRecorder.Failure.requires10BitInput {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix("VPX-Take-") }, [url.lastPathComponent])
    }

    private func recordingBuffer(_ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 128, 128, format, attributes, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        if CVPixelBufferIsPlanar(result) {
            CVPixelBufferLockBaseAddress(result, [])
            defer { CVPixelBufferUnlockBaseAddress(result, []) }
            for plane in 0..<2 {
                let words = CVPixelBufferGetBytesPerRowOfPlane(result, plane) / 2
                let count = words * CVPixelBufferGetHeightOfPlane(result, plane)
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(result, plane))
                let samples = base.assumingMemoryBound(to: UInt16.self)
                for index in 0..<count {
                    samples[index] = UInt16(plane == 0 ? 480 + index % 11 : 512) << 6
                }
            }
        }
        return result
    }

    @MainActor
    func testCompositeMetalCopyAndPCMProduceOneSealedMovieWithBothTracks() async throws {
        try await verifyCompositeTake(preserve10Bit: false)
        try await verifyCompositeTake(preserve10Bit: true)
    }

    @MainActor
    private func verifyCompositeTake(preserve10Bit: Bool) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let lutBytes = Data(("LUT_3D_SIZE 2\n" + String(repeating: "0.1 0.2 0.3\n", count: 8)).utf8)
        let sourceLUT = try CompositeLUT.parse(lutBytes, name: "Test.cube")
        let recorder = try CameraTakeRecorder(request: StudioModel().takeSnapshotRequest(),
            parent: parent, sourceID: UUID(), composite: true, preserve10Bit: preserve10Bit, compositeLUT: sourceLUT)
        let capture = CompositeCapture(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: preserve10Bit ? .rgba16Float : .bgra8Unorm_srgb,
            width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 1)
        try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        let hostTime = CMTime(value: 10, timescale: 1)
        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
            width: 64, height: 64, mipmapped: false)
        maskDescriptor.usage = .renderTarget
        let mask = try XCTUnwrap(device.makeTexture(descriptor: maskDescriptor))
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0, 0, 1)
        try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass)).endEncoding()

        let depthBytes = Data([0, 0, 128, 63])
        let packet = try CaptureDepthPacket(header: .init(sequence: 7, captureTimeNanoseconds: 10,
            width: 1, height: 1, depthEncoding: "depth-float32-le", confidenceEncoding: "confidence-uint8"),
            depth: depthBytes, confidence: Data([2]))
        let sourceID = UUID()
        let depth = DepthPreviewInput(sourceID: sourceID, packet: packet, capturedHostSeconds: 10)
        let pose = TakeAuxiliaryFrame.Pose(.init(transform: matrix_identity_float4x4, mode: .measured, horizonMilliseconds: 0))
        let lut = CompositeLUT.Usage(reference: sourceLUT.reference, applied: true)
        let auxiliary = TakeAuxiliaryFrame(sourceID: sourceID, inputSequence: 11, inputHostSeconds: 10, depth: depth, pose: pose,
            colorConversion: .init(requested: .automatic, applied: .rec709), lut: lut)
        capture.encode(texture, on: command, to: recorder, at: hostTime, auxiliary: auxiliary, matte: mask)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        XCTAssertEqual(command.status, .completed)
        let pcm = try makePCM()
        recorder.submitAudio(pcm, at: CMTimeAdd(hostTime, CMTime(value: 1, timescale: 100)))
        let directory = try await recorder.finish()
        let review = try await TakeReviewService().inspect(directory: directory)
        XCTAssertTrue(review.allVerified)
        let url = try review.manifest.verifiedPlaybackURL(relativePath: "composite.mov", in: directory)
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let stats = try JSONDecoder().decode(CameraTakeRecorder.Statistics.self,
            from: Data(contentsOf: directory.appendingPathComponent("recording.json")))
        XCTAssertEqual(stats.encodedBitDepth, preserve10Bit ? 10 : nil)
        let summary = try XCTUnwrap(review.manifest.provenance?.recording)
        XCTAssertEqual(summary.sourceID, stats.sourceID)
        XCTAssertEqual(summary.width, 64)
        XCTAssertEqual(summary.height, 64)
        XCTAssertEqual(summary.encodedBitDepth, stats.encodedBitDepth)
        XCTAssertEqual(summary.writerPixelFormat, stats.pixelFormat)
        XCTAssertEqual(summary.writtenFrames, 1)
        XCTAssertEqual(summary.recorderDrops, stats.dropped)
        var expectedCoverage = TakeProvenance.Recording.PoseCoverage()
        expectedCoverage.record(pose.mode)
        XCTAssertEqual(summary.pose, expectedCoverage)
        XCTAssertEqual(summary.lutUsage, [lut])
        XCTAssertEqual(summary.colorConversion, .init(requested: [.automatic], applied: [.rec709]))
        XCTAssertTrue(Set(review.manifest.assets.map(\.relativePath)).isSuperset(of: ["matte.f16le", "depth.bin", "frames.jsonl"]))
        let frameRows = try await TakeReviewService().loadFrameIndex(directory: directory, manifest: review.manifest)
        XCTAssertEqual(frameRows.map(\.frameIndex), [0])
        XCTAssertEqual(frameRows.first?.inputSequence, 11)
        XCTAssertEqual(frameRows.first?.colorConversion?.requested, .automatic)
        XCTAssertEqual(frameRows.first?.colorConversion?.applied, .rec709)
        XCTAssertEqual(frameRows.first?.lut, lut)
        let lutPath = CompositeLUT.takeAssetPath
        XCTAssertEqual(review.manifest.assets.first { $0.role == .lut }?.sha256, sourceLUT.reference.sha256)
        let service = TakeReviewService()
        let restoredLUT = try await service.restoreLUT(directory: directory, manifest: review.manifest, relativePath: lutPath)
        XCTAssertEqual(restoredLUT.reference, sourceLUT.reference)
        XCTAssertEqual(restoredLUT.originalBytes, lutBytes)
        let model = StudioModel()
        XCTAssertTrue(model.restoreTakeLUT(restoredLUT))
        XCTAssertEqual(model.renderSettings.compositeLUT?.reference, sourceLUT.reference)
        try Data("altered LUT".utf8).write(to: directory.appendingPathComponent(lutPath))
        do {
            _ = try await service.restoreLUT(directory: directory, manifest: review.manifest, relativePath: lutPath)
            XCTFail("A LUT modified after inspection must not be restored")
        } catch TakeManifest.PlaybackError.modified {}
        let index = try Data(contentsOf: directory.appendingPathComponent("frames.jsonl"))
        let row = try JSONDecoder().decode(TakeAuxiliaryTracks.Row.self, from: index)
        let range = try await video[0].load(.timeRange)
        XCTAssertEqual(CMTime(value: row.ptsValue, timescale: row.ptsTimescale), range.start)
        XCTAssertEqual(row.inputSequence, 11)
        XCTAssertEqual(row.pose?.worldFromCamera, pose.worldFromCamera)
        XCTAssertEqual(row.depth?.sequence, 7)
        XCTAssertEqual(row.depth?.confidence.offset, 4)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("depth.bin")), depthBytes + Data([2]))
        let matteFile = directory.appendingPathComponent("matte.f16le")
        let matte = try Data(contentsOf: matteFile)
        XCTAssertEqual(row.matte?.length, 64 * 64 * 2)
        XCTAssertEqual(matte, Data(Array(repeating: [UInt8(0), 0x38], count: 64 * 64).joined()))
        try Data([0]).write(to: matteFile)
        let modified = try await TakeReviewService().inspect(directory: directory)
        XCTAssertEqual(modified.results.first { $0.relativePath == "matte.f16le" }?.status, .modified)
    }

    private func makePCM() throws -> CMSampleBuffer {
        let count = 4800
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var data: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &data), noErr)
        let block = try XCTUnwrap(data)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2), noErr)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
            formatDescription: try XCTUnwrap(description), sampleCount: count, presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    @MainActor
    func testRecordsOnlySelectedSessionAndPublishesPlayableSealedTake() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = try StudioModel().takeSnapshotRequest()
        let source = UUID(), session = UUID()
        let scene = StudioScene.demo
        let recorder = try CameraTakeRecorder(request: request, parent: parent, sourceID: source,
            sceneSnapshot: TakeSceneSnapshot(scene: scene))
        let store = LatestVideoFrameStore()
        store.selectSource(source)
        store.beginSession(sourceID: source, sessionID: session)
        XCTAssertTrue(store.startRecording(recorder, sourceID: source))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        func frame(_ i: Int64) -> VideoFrame {
            let time = CMTime(value: i, timescale: 30)
            return VideoFrame(identifier: UInt64(i), captureTime: time, hostReceiveTime: time,
                colorMetadata: .init(colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil),
                pixelBuffer: pixelBuffer, quality: .nominal)
        }
        store.observeRecordingClock(sourceID: UUID(), freshness: .current, uncertaintyMilliseconds: 100)
        store.observeRecordingClock(sourceID: source, freshness: .current, uncertaintyMilliseconds: 4)
        store.observeRecordingClock(sourceID: source, freshness: .current, uncertaintyMilliseconds: 2)
        store.observeRecordingClock(sourceID: source, freshness: .stale, uncertaintyMilliseconds: 10)
        store.put(frame(1), sourceID: source, sessionID: UUID())
        store.put(frame(2), sourceID: source, sessionID: session)
        store.put(frame(5), sourceID: source, sessionID: session)
        store.beginSession(sourceID: source, sessionID: UUID())
        store.put(frame(4), sourceID: source)
        store.observeRecordingClock(sourceID: source, freshness: .unmeasured, uncertaintyMilliseconds: nil)
        _ = store.stopRecording()
        let url = try await recorder.finish()
        let review = try await TakeReviewService().inspect(directory: url)
        XCTAssertTrue(review.allVerified)
        XCTAssertEqual(review.manifest.provenance?.kind, .recording)
        XCTAssertEqual(review.manifest.provenance?.recording?.inputSequenceGaps, 2)
        let clock = try XCTUnwrap(review.manifest.provenance?.recording?.clock)
        XCTAssertEqual(clock, .init(current: 2, stale: 1, unmeasured: 1, peakUncertaintyMilliseconds: 4))
        let sceneAsset = try XCTUnwrap(review.manifest.assets.first { $0.role == .scene })
        let archived = try JSONDecoder().decode(TakeSceneSnapshot.self,
            from: Data(contentsOf: url.appendingPathComponent(sceneAsset.relativePath)))
        let service = TakeReviewService()
        let restored = try await service.restoreScene(directory: url, manifest: review.manifest,
            relativePath: sceneAsset.relativePath)
        XCTAssertEqual(restored.id, scene.id)
        XCTAssertTrue(StudioModel().restoreTakeScene(restored))
        XCTAssertEqual(archived.id, scene.id)
        XCTAssertEqual(archived.meshes.map { $0.vertices.count }, scene.meshes.map { $0.vertices.count })
        XCTAssertEqual(archived.meshes.first?.vertices.first?.position, scene.meshes.first?.vertices.first?.position)

        let media = try review.manifest.verifiedPlaybackURL(relativePath: "camera.mov", in: url)
        let playable = try await AVURLAsset(url: media).load(.isPlayable)
        XCTAssertTrue(playable)
        let stats = try JSONDecoder().decode(CameraTakeRecorder.Statistics.self,
            from: Data(contentsOf: url.appendingPathComponent("recording.json")))
        XCTAssertEqual(stats.frames, 2)
        XCTAssertEqual(stats.sourceID, source)
        XCTAssertEqual(stats.clock, clock)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [url.lastPathComponent])
        try Data("altered scene".utf8).write(to: url.appendingPathComponent(sceneAsset.relativePath))
        do {
            _ = try await service.restoreScene(directory: url, manifest: review.manifest,
                relativePath: sceneAsset.relativePath)
            XCTFail("A scene changed after review must be rejected")
        } catch TakeManifest.PlaybackError.modified {}

    }

    @MainActor
    func testEmptyRecordingDoesNotPublishTake() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        var recorder: CameraTakeRecorder? = try CameraTakeRecorder(request: StudioModel().takeSnapshotRequest(),
            parent: parent, sourceID: UUID())
        do { _ = try await recorder?.finish(); XCTFail("Empty recording") }
        catch CameraTakeRecorder.Failure.noFrames {}
        recorder = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).allSatisfy { $0.hasPrefix(".") })
    }
}

private final class PluginTestSource: VideoSource {
    let descriptor: DeviceDescriptor
    let recordingPlugins: [TakeProvenance.Plugin]

    init(id: UUID, plugin: TakeProvenance.Plugin) {
        descriptor = .init(id: id, displayName: plugin.name, capabilities: [.video])
        recordingPlugins = [plugin]
    }

    func start() throws {}
    func stop() {}
}
