#if os(iOS)
@preconcurrency import ARKit
import CoreMotion
import AVFoundation
import Foundation
import simd
import VPXCaptureProtocol

public struct CaptureVideoSample {
    public let header: CaptureVideoFrameHeader
    public let pixelBuffer: CVPixelBuffer
}

public struct CaptureDepthSample {
    public let header: CaptureDepthFrameHeader
    public let depthMap: CVPixelBuffer
    public let confidenceMap: CVPixelBuffer?
}

/// Captures video, ARKit tracking, and LiDAR depth from one ARSession.
/// HEVC encoding is optional and network transport remains outside this type.
public final class IPhoneCaptureCoordinator: NSObject {
    public var onVideoSample: ((CaptureVideoSample) -> Void)?
    public var onEncodedVideoFrame: ((CaptureEncodedVideoFrame) -> Void)?
    public var onPose: ((CapturePosePacket) -> Void)?
    public var onDepthSample: ((CaptureDepthSample) -> Void)?
    public var onTrackingQualityChanged: ((CaptureTrackingQuality) -> Void)?
    public var onEncodingError: ((Error) -> Void)?
    public var onDepthPacket: ((CaptureDepthPacket) -> Void)?
    public var onQualityEvent: ((CaptureQualityEvent) -> Void)?
    public static var supportsDepth: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    public static var supportsTracking: Bool { ARWorldTrackingConfiguration.isSupported }
    public var supportsMotion: Bool { motionManager.isDeviceMotionAvailable && CMMotionActivityManager.authorizationStatus() != .denied && CMMotionActivityManager.authorizationStatus() != .restricted }

    public let session = ARSession()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var latestAngularVelocity = SIMD3<Float>(repeating: 0)
    private var latestAcceleration = SIMD3<Float>(repeating: 0)
    private let motionLock = NSLock()
    private var motionTimestamp: TimeInterval = 0
    private let captureQueue = DispatchQueue(label: "com.vpxstudio.arkit")
    private let videoCapture = IPhoneVideoCapture()
    private var qualitySequence: UInt64 = 0
    private var lastReason: CaptureQualityEvent.Reason?
    private var lastDepthTime: UInt64 = 0
    private var capturingAR = false
    private var previousTranslation: SIMD3<Float>?
    private var previousPoseTimestampNanoseconds: UInt64?
    private var frameSequence: UInt64 = 0
    private var referenceSpaceRevision: UInt64 = 0
    private var lastQuality: CaptureTrackingQuality?
    private var videoEncoder: IPhoneHEVCVideoEncoder?

    public override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = captureQueue
        videoCapture.onSample = { [weak self] sample in
            guard let self else { return }
            onVideoSample?(sample)
            do { try videoEncoder?.encode(pixelBuffer: sample.pixelBuffer, header: sample.header) }
            catch { onEncodingError?(error) }
        }
        videoCapture.onFailure = { [weak self] error in self?.onEncodingError?(error) }
    }

    public func start(enableDepth: Bool, enableTracking: Bool = true) {
        guard enableTracking, Self.supportsTracking else { videoCapture.start(); return }
        captureQueue.sync {
            capturingAR = true
            let configuration = ARWorldTrackingConfiguration()
            if enableDepth,
               ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            referenceSpaceRevision &+= 1
            startMotionUpdates()
        }
    }

    public func stop() {
        videoCapture.stop()
        captureQueue.sync {
            capturingAR = false
            publishQualityIfNeeded(.lost, reason: .disconnected)
            session.pause()
            motionManager.stopDeviceMotionUpdates()
            videoEncoder?.completeFrames()
            previousTranslation = nil
            previousPoseTimestampNanoseconds = nil
            lastDepthTime = 0
        }
    }

    public func startHEVCEncoding(profile: CaptureVideoProfile = .uhd60HEVC) throws {
        let encoder = try IPhoneHEVCVideoEncoder(profile: profile)
        encoder.onEncodedFrame = { [weak self] frame in
            self?.onEncodedVideoFrame?(frame)
        }
        encoder.onError = { [weak self] error in
            self?.onEncodingError?(error)
        }
        videoEncoder = encoder
    }

    public func stopHEVCEncoding() {
        videoEncoder?.invalidate()
        videoEncoder = nil
    }

    public func requestVideoKeyFrame() {
        videoEncoder?.requestKeyFrame()
    }

    private func startMotionUpdates() {
        guard supportsMotion else { publishQualityIfNeeded(.limited, reason: .motionUnavailable); return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            motionLock.lock()
            latestAngularVelocity = SIMD3(
                Float(motion.rotationRate.x),
                Float(motion.rotationRate.y),
                Float(motion.rotationRate.z)
            )
            latestAcceleration=SIMD3(Float(motion.userAcceleration.x)*9.80665, Float(motion.userAcceleration.y)*9.80665, Float(motion.userAcceleration.z)*9.80665)
            motionTimestamp=motion.timestamp
            motionLock.unlock()
        }
    }
}

extension IPhoneCaptureCoordinator: ARSessionDelegate {
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard capturingAR else { return }
        frameSequence &+= 1
        let timestamp = monotonicNanoseconds(frame.timestamp)
        let quality = trackingQuality(for: frame.camera.trackingState)
        let reason = trackingReason(for: frame.camera.trackingState)
        if reason == .relocalizing, lastReason != .relocalizing {
            referenceSpaceRevision &+= 1; previousTranslation=nil; previousPoseTimestampNanoseconds=nil
        }
        publishQualityIfNeeded(quality, reason: reason)
        motionLock.lock()
        let freshMotion=abs(frame.timestamp-motionTimestamp) < 0.05
        let angular=freshMotion ? latestAngularVelocity : .zero
        let acceleration=freshMotion ? [latestAcceleration.x, latestAcceleration.y, latestAcceleration.z] : nil
        motionLock.unlock()

        let transform = frame.camera.transform
        let rotation = simd_quatf(transform)
        let translation = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let pose = CapturePosePacket(
            sequence: frameSequence,
            captureTimeNanoseconds: timestamp,
            translationMeters: [translation.x, translation.y, translation.z],
            rotationQuaternion: [rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w],
            linearVelocityMetersPerSecond: linearVelocity(
                translation: translation,
                timestampNanoseconds: timestamp
            ),
            angularVelocityRadiansPerSecond: [angular.x, angular.y, angular.z],
            quality: quality,
            referenceSpaceRevision: referenceSpaceRevision,
            accelerationMetersPerSecondSquared: acceleration
        )
        onPose?(pose)

        let image = frame.capturedImage
        let header = CaptureVideoFrameHeader(
            sequence: frameSequence,
            captureTimeNanoseconds: timestamp,
            width: UInt32(CVPixelBufferGetWidth(image)),
            height: UInt32(CVPixelBufferGetHeight(image)),
            codec: "raw-cv-pixel-buffer",
            isKeyFrame: true,
            cameraMetadata: IPhoneVideoCapture.metadata(image, cameraID: "arkit.back", source: "arkit",
                intrinsics: (0..<3).flatMap { column in (0..<3).map { frame.camera.intrinsics[column][$0] } })
        )
        onVideoSample?(CaptureVideoSample(header: header, pixelBuffer: image))
        do {
            try videoEncoder?.encode(pixelBuffer: image, header: header)
        } catch {
            onEncodingError?(error)
        }

        if let sceneDepth = frame.sceneDepth {
            let depthHeader = CaptureDepthFrameHeader(
                sequence: frameSequence,
                captureTimeNanoseconds: timestamp,
                width: UInt32(CVPixelBufferGetWidth(sceneDepth.depthMap)),
                height: UInt32(CVPixelBufferGetHeight(sceneDepth.depthMap)),
                depthEncoding: "depth-float32-le",
                confidenceEncoding: "confidence-uint8"
            )
            onDepthSample?(
                CaptureDepthSample(
                    header: depthHeader,
                    depthMap: sceneDepth.depthMap,
                    confidenceMap: sceneDepth.confidenceMap
                )
            )
            if timestamp >= lastDepthTime, timestamp-lastDepthTime >= 200_000_000,
               let confidence=sceneDepth.confidenceMap {
                do {
                    let packet=try CaptureDepthPacket(header: depthHeader,
                        depth: packed(sceneDepth.depthMap, bytesPerPixel: 4), confidence: packed(confidence, bytesPerPixel: 1))
                    onDepthPacket?(packet); lastDepthTime=timestamp
                } catch { onEncodingError?(error) }
            }
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        publishQualityIfNeeded(.lost, reason: .failed)
        onEncodingError?(error)
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        publishQualityIfNeeded(.lost, reason: .interrupted)
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        referenceSpaceRevision &+= 1
        previousTranslation=nil; previousPoseTimestampNanoseconds=nil
        publishQualityIfNeeded(.limited, reason: .interruptionEnded)
    }

    private func trackingQuality(for state: ARCamera.TrackingState) -> CaptureTrackingQuality {
        switch state {
        case .normal: .nominal
        case .limited: .limited
        case .notAvailable: .lost
        }
    }

    private func trackingReason(for state: ARCamera.TrackingState) -> CaptureQualityEvent.Reason {
        switch state {
        case .normal: return .normal
        case .notAvailable: return .initializing
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .excessiveMotion: return .excessiveMotion
            case .insufficientFeatures: return .insufficientFeatures
            case .relocalizing: return .relocalizing
            @unknown default: return .initializing
            }
        }
    }
    private func packed(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        var data=Data()
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            data.append(base.advanced(by: row*CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self), count: CVPixelBufferGetWidth(buffer)*bytesPerPixel)
        }
        return data
    }
    private func publishQualityIfNeeded(_ quality: CaptureTrackingQuality, reason: CaptureQualityEvent.Reason) {
        guard quality != lastQuality || reason != lastReason else { return }
        qualitySequence &+= 1; lastReason=reason
        lastQuality = quality
        onTrackingQualityChanged?(quality)
        onQualityEvent?(CaptureQualityEvent(sequence: qualitySequence, captureTimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            quality: quality, reason: reason, referenceSpaceRevision: referenceSpaceRevision))
    }

    private func monotonicNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func linearVelocity(
        translation: SIMD3<Float>,
        timestampNanoseconds: UInt64
    ) -> [Float] {
        defer {
            previousTranslation = translation
            previousPoseTimestampNanoseconds = timestampNanoseconds
        }
        guard let previousTranslation,
              let previousPoseTimestampNanoseconds,
              timestampNanoseconds > previousPoseTimestampNanoseconds else {
            return [0, 0, 0]
        }

        let seconds = Float(timestampNanoseconds - previousPoseTimestampNanoseconds) / 1_000_000_000
        let velocity = (translation - previousTranslation) / max(seconds, 0.000_001)
        return [velocity.x, velocity.y, velocity.z]
    }
}
#endif
