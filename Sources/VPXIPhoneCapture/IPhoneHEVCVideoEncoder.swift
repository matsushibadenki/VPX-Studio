#if os(iOS)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import VPXCaptureProtocol

public enum IPhoneHEVCVideoEncoderError: LocalizedError {
    case compressionSessionCreationFailed(OSStatus)
    case compressionSessionConfigurationFailed(OSStatus)
    case frameEncodingFailed(OSStatus)
    case unsupportedVideoProfile(CaptureVideoProfile)

    public var errorDescription: String? {
        switch self {
        case .compressionSessionCreationFailed(let status):
            "Could not create the HEVC compression session (" + String(status) + ")."
        case .compressionSessionConfigurationFailed(let status):
            "Could not configure the HEVC compression session (" + String(status) + ")."
        case .frameEncodingFailed(let status):
            "Could not encode the HEVC video frame (" + String(status) + ")."
        case .unsupportedVideoProfile(let profile):
            "The requested video profile " + profile.codec + " is not supported by this encoder."
        }
    }
}

/// Real-time HEVC encoder for the Capture Node. It emits one VideoToolbox access
/// unit per input frame and deliberately owns no networking policy.
public final class IPhoneHEVCVideoEncoder {
    public var onEncodedFrame: ((CaptureEncodedVideoFrame) -> Void)?
    public var onError: ((Error) -> Void)?

    public let profile: CaptureVideoProfile

    private var compressionSession: VTCompressionSession?
    private var encodedWidth: Int32 = 0
    private var encodedHeight: Int32 = 0
    private var shouldForceKeyFrame = true

    public init(profile: CaptureVideoProfile = .uhd60HEVC) throws {
        guard profile.codec == "hvc1" else {
            throw IPhoneHEVCVideoEncoderError.unsupportedVideoProfile(profile)
        }
        self.profile = profile
    }

    deinit {
        invalidate()
    }

    public func encode(pixelBuffer: CVPixelBuffer, header: CaptureVideoFrameHeader) throws {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        try prepareSessionIfNeeded(width: width, height: height)

        guard let compressionSession else { return }
        let pendingFrame = PendingFrame(header: header)
        let frameProperties: CFDictionary? = shouldForceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        shouldForceKeyFrame = false

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: .invalid,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: Unmanaged.passRetained(pendingFrame).toOpaque(),
            infoFlagsOut: nil
        )
        guard status == noErr else {
            Unmanaged<PendingFrame>.fromOpaque(
                Unmanaged.passUnretained(pendingFrame).toOpaque()
            ).release()
            throw IPhoneHEVCVideoEncoderError.frameEncodingFailed(status)
        }
    }

    public func requestKeyFrame() {
        shouldForceKeyFrame = true
    }

    public func completeFrames() {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
        }
    }

    public func invalidate() {
        guard let compressionSession else { return }
        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
        encodedWidth = 0
        encodedHeight = 0
    }

    private func prepareSessionIfNeeded(width: Int32, height: Int32) throws {
        guard compressionSession == nil || width != encodedWidth || height != encodedHeight else {
            return
        }
        invalidate()

        var createdSession: VTCompressionSession?
        let creationStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &createdSession
        )
        guard creationStatus == noErr, let createdSession else {
            throw IPhoneHEVCVideoEncoderError.compressionSessionCreationFailed(creationStatus)
        }

        let keyFrameInterval = max(1, Int(profile.frameRate * 2))
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, profile.frameRate as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, profile.bitRate as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, keyFrameInterval as CFNumber)
        ]
        for (key, value) in settings {
            let status = VTSessionSetProperty(createdSession, key: key, value: value)
            guard status == noErr else {
                VTCompressionSessionInvalidate(createdSession)
                throw IPhoneHEVCVideoEncoderError.compressionSessionConfigurationFailed(status)
            }
        }

        let preparationStatus = VTCompressionSessionPrepareToEncodeFrames(createdSession)
        guard preparationStatus == noErr else {
            VTCompressionSessionInvalidate(createdSession)
            throw IPhoneHEVCVideoEncoderError.compressionSessionConfigurationFailed(preparationStatus)
        }
        compressionSession = createdSession
        encodedWidth = width
        encodedHeight = height
        shouldForceKeyFrame = true
    }

    private func receiveEncodedSample(
        pendingFrame: PendingFrame,
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?
    ) {
        guard status == noErr, let sampleBuffer else {
            onError?(IPhoneHEVCVideoEncoderError.frameEncodingFailed(status))
            return
        }
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            onError?(IPhoneHEVCVideoEncoderError.frameEncodingFailed(kVTInvalidSessionErr))
            return
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let dataStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard dataStatus == kCMBlockBufferNoErr, let dataPointer else {
            onError?(IPhoneHEVCVideoEncoderError.frameEncodingFailed(dataStatus))
            return
        }

        let isKeyFrame = Self.isKeyFrame(sampleBuffer)
        let parameterSets = isKeyFrame ? Self.parameterSets(for: sampleBuffer) : []
        let encodedHeader = CaptureVideoFrameHeader(
            sequence: pendingFrame.header.sequence,
            captureTimeNanoseconds: pendingFrame.header.captureTimeNanoseconds,
            width: pendingFrame.header.width,
            height: pendingFrame.header.height,
            codec: "hvc1",
            isKeyFrame: isKeyFrame
        )
        onEncodedFrame?(
            CaptureEncodedVideoFrame(
                header: encodedHeader,
                encodedData: Data(bytes: dataPointer, count: totalLength),
                parameterSets: parameterSets
            )
        )
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as? [CFString: Any] else {
            return false
        }
        return (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func parameterSets(for sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return [] }
        var parameterSetCount = 0
        var headerLength: Int32 = 0
        var parameterSets: [Data] = []

        for index in 0..<3 {
            var parameterSetPointer: UnsafePointer<UInt8>?
            var parameterSetSize = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &parameterSetPointer,
                parameterSetSizeOut: &parameterSetSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &headerLength
            )
            guard status == noErr, let parameterSetPointer else { continue }
            parameterSets.append(Data(bytes: parameterSetPointer, count: parameterSetSize))
        }
        return parameterSets
    }

    private static let outputCallback: VTCompressionOutputCallback = {
        outputCallbackRefCon,
        sourceFrameRefCon,
        status,
        _,
        sampleBuffer in
        guard let outputCallbackRefCon, let sourceFrameRefCon else { return }
        let encoder = Unmanaged<IPhoneHEVCVideoEncoder>
            .fromOpaque(outputCallbackRefCon)
            .takeUnretainedValue()
        let pendingFrame = Unmanaged<PendingFrame>
            .fromOpaque(sourceFrameRefCon)
            .takeRetainedValue()
        encoder.receiveEncodedSample(
            pendingFrame: pendingFrame,
            status: status,
            sampleBuffer: sampleBuffer
        )
    }
}

private final class PendingFrame {
    let header: CaptureVideoFrameHeader

    init(header: CaptureVideoFrameHeader) {
        self.header = header
    }
}
#endif
