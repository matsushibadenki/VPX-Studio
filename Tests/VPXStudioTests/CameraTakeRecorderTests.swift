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
        let recorder = try CameraTakeRecorder(request: studio.takeSnapshotRequest(), parent: parent,
            sourceID: sourceID, preserve10Bit: true)
        let buffer = try recordingBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        for index in 0..<2 {
            recorder.submitVideo(buffer, at: CMTime(value: Int64(index), timescale: 30))
        }
        let url = try await recorder.finish()
        let review = try await TakeReviewService().inspect(directory: url)
        XCTAssertTrue(review.allVerified)
        let statsURL = url.appendingPathComponent("recording.json")
        let stats = try JSONDecoder().decode(CameraTakeRecorder.Statistics.self, from: Data(contentsOf: statsURL))
        XCTAssertEqual(stats.encodedBitDepth, 10)
        XCTAssertEqual(stats.frames, 2)

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
        let recorder = try CameraTakeRecorder(request: StudioModel().takeSnapshotRequest(),
            parent: parent, sourceID: UUID(), composite: true, preserve10Bit: preserve10Bit)
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
        let auxiliary = TakeAuxiliaryFrame(sourceID: sourceID, inputSequence: 11, inputHostSeconds: 10, depth: depth, pose: pose)
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
        XCTAssertTrue(Set(review.manifest.assets.map(\.relativePath)).isSuperset(of: ["matte.f16le", "depth.bin", "frames.jsonl"]))
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
        let recorder = try CameraTakeRecorder(request: request, parent: parent, sourceID: source)
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
        store.put(frame(1), sourceID: source, sessionID: UUID())
        store.put(frame(2), sourceID: source, sessionID: session)
        store.put(frame(3), sourceID: source, sessionID: session)
        store.beginSession(sourceID: source, sessionID: UUID())
        store.put(frame(4), sourceID: source)
        _ = store.stopRecording()
        let url = try await recorder.finish()
        let review = try await TakeReviewService().inspect(directory: url)
        XCTAssertTrue(review.allVerified)
        XCTAssertEqual(review.manifest.provenance?.kind, .recording)
        let media = try review.manifest.verifiedPlaybackURL(relativePath: "camera.mov", in: url)
        let playable = try await AVURLAsset(url: media).load(.isPlayable)
        XCTAssertTrue(playable)
        let stats = try JSONDecoder().decode(CameraTakeRecorder.Statistics.self,
            from: Data(contentsOf: url.appendingPathComponent("recording.json")))
        XCTAssertEqual(stats.frames, 2)
        XCTAssertEqual(stats.sourceID, source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [url.lastPathComponent])
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
