import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import VPXCaptureProtocol

enum MacHEVCVideoDecoderError: LocalizedError {
    case missingParameterSets
    case formatDescriptionCreationFailed(OSStatus)
    case decompressionSessionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodingFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingParameterSets:
            "A key frame with HEVC parameter sets is required before decoding."
        case .formatDescriptionCreationFailed(let status):
            "Could not create an HEVC format description (" + String(status) + ")."
        case .decompressionSessionCreationFailed(let status):
            "Could not create the HEVC decompression session (" + String(status) + ")."
        case .sampleBufferCreationFailed(let status):
            "Could not create an HEVC sample buffer (" + String(status) + ")."
        case .decodingFailed(let status):
            "Could not decode the HEVC access unit (" + String(status) + ")."
        }
    }
}

/// Decodes VideoToolbox HEVC access units received from a Capture Node. The
/// caller owns jitter buffering and transport; this type only converts an
/// authenticated, ordered stream into CVPixelBuffers for the Metal pipeline.
final class MacHEVCVideoDecoder {
    var onDecodedFrame: ((CaptureVideoFrameHeader, CVPixelBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var activeParameterSets: [Data] = []

    deinit {
        invalidate()
    }

    func decode(_ frame: CaptureEncodedVideoFrame) throws {
        if frame.header.isKeyFrame, !frame.parameterSets.isEmpty {
            try configureIfNeeded(parameterSets: frame.parameterSets)
        }
        guard let decompressionSession, let formatDescription else {
            throw MacHEVCVideoDecoderError.missingParameterSets
        }

        var blockBuffer: CMBlockBuffer?
        let blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.encodedData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.encodedData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockBufferStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw MacHEVCVideoDecoderError.sampleBufferCreationFailed(blockBufferStatus)
        }
        let copyStatus = frame.encodedData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.encodedData.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw MacHEVCVideoDecoderError.sampleBufferCreationFailed(copyStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = frame.encodedData.count
        let sampleBufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleBufferStatus == noErr, let sampleBuffer else {
            throw MacHEVCVideoDecoderError.sampleBufferCreationFailed(sampleBufferStatus)
        }

        let pendingFrame = PendingDecodedFrame(header: frame.header)
        let sourceFrameRefcon = Unmanaged.passRetained(pendingFrame).toOpaque()
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: sourceFrameRefcon,
            infoFlagsOut: &infoFlags
        )
        guard decodeStatus == noErr else {
            Unmanaged<PendingDecodedFrame>.fromOpaque(sourceFrameRefcon).release()
            throw MacHEVCVideoDecoderError.decodingFailed(decodeStatus)
        }
    }

    func completeFrames() {
        if let decompressionSession {
            VTDecompressionSessionFinishDelayedFrames(decompressionSession)
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
        }
    }

    func invalidate() {
        guard let decompressionSession else { return }
        VTDecompressionSessionFinishDelayedFrames(decompressionSession)
        VTDecompressionSessionInvalidate(decompressionSession)
        self.decompressionSession = nil
        formatDescription = nil
        activeParameterSets = []
    }

    private func configureIfNeeded(parameterSets: [Data]) throws {
        guard parameterSets.count >= 3 else {
            throw MacHEVCVideoDecoderError.missingParameterSets
        }
        let firstThree = Array(parameterSets.prefix(3))
        let hasChangedFormat = formatDescription == nil || activeParameterSets != firstThree
        guard hasChangedFormat else { return }
        invalidate()

        let creation = try firstThree[0].withUnsafeBytes { bytes0 in
            guard let pointer0 = bytes0.bindMemory(to: UInt8.self).baseAddress else {
                throw MacHEVCVideoDecoderError.missingParameterSets
            }
            return try firstThree[1].withUnsafeBytes { bytes1 in
                guard let pointer1 = bytes1.bindMemory(to: UInt8.self).baseAddress else {
                    throw MacHEVCVideoDecoderError.missingParameterSets
                }
                return try firstThree[2].withUnsafeBytes { bytes2 in
                    guard let pointer2 = bytes2.bindMemory(to: UInt8.self).baseAddress else {
                        throw MacHEVCVideoDecoderError.missingParameterSets
                    }
                    var pointers: [UnsafePointer<UInt8>] = [pointer0, pointer1, pointer2]
                    var sizes = firstThree.map(\.count)
                    var createdFormat: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &createdFormat
                    )
                    guard status == noErr, let createdFormat else {
                        throw MacHEVCVideoDecoderError.formatDescriptionCreationFailed(status)
                    }
                    return createdFormat
                }
            }
        }
        let videoFormat = creation

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var createdSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: videoFormat,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &createdSession
        )
        guard sessionStatus == noErr, let createdSession else {
            throw MacHEVCVideoDecoderError.decompressionSessionCreationFailed(sessionStatus)
        }
        decompressionSession = createdSession
        formatDescription = videoFormat
        activeParameterSets = firstThree
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        outputCallbackRefCon,
        sourceFrameRefCon,
        status,
        _,
        imageBuffer,
        _,
        _ in
        guard let outputCallbackRefCon, let sourceFrameRefCon else { return }
        let decoder = Unmanaged<MacHEVCVideoDecoder>
            .fromOpaque(outputCallbackRefCon)
            .takeUnretainedValue()
        let pendingFrame = Unmanaged<PendingDecodedFrame>
            .fromOpaque(sourceFrameRefCon)
            .takeRetainedValue()
        guard status == noErr, let imageBuffer else {
            decoder.onError?(MacHEVCVideoDecoderError.decodingFailed(status))
            return
        }
        decoder.onDecodedFrame?(pendingFrame.header, imageBuffer)
    }
}

private final class PendingDecodedFrame {
    let header: CaptureVideoFrameHeader

    init(header: CaptureVideoFrameHeader) {
        self.header = header
    }
}
