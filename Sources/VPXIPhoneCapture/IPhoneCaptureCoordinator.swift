#if os(iOS)
@preconcurrency import ARKit
import CoreMotion
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
/// Encoding and network transport intentionally remain outside this type so the
/// app can select an HEVC encoder and transport policy per production profile.
public final class IPhoneCaptureCoordinator: NSObject {
    public var onVideoSample: ((CaptureVideoSample) -> Void)?
    public var onPose: ((CapturePosePacket) -> Void)?
    public var onDepthSample: ((CaptureDepthSample) -> Void)?
    public var onTrackingQualityChanged: ((CaptureTrackingQuality) -> Void)?

    public let session = ARSession()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var latestAngularVelocity = SIMD3<Float>(repeating: 0)
    private var previousTranslation: SIMD3<Float>?
    private var previousPoseTimestampNanoseconds: UInt64?
    private var frameSequence: UInt64 = 0
    private var referenceSpaceRevision: UInt64 = 0
    private var lastQuality: CaptureTrackingQuality?

    public override init() {
        super.init()
        session.delegate = self
    }

    public func start(enableDepth: Bool) {
        let configuration = ARWorldTrackingConfiguration()
        if enableDepth,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        referenceSpaceRevision &+= 1
        startMotionUpdates()
    }

    public func stop() {
        session.pause()
        motionManager.stopDeviceMotionUpdates()
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let motion else { return }
            self?.latestAngularVelocity = SIMD3(
                Float(motion.rotationRate.x),
                Float(motion.rotationRate.y),
                Float(motion.rotationRate.z)
            )
        }
    }
}

extension IPhoneCaptureCoordinator: ARSessionDelegate {
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameSequence &+= 1
        let timestamp = monotonicNanoseconds(frame.timestamp)
        let quality = trackingQuality(for: frame.camera.trackingState)
        publishQualityIfNeeded(quality)

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
            angularVelocityRadiansPerSecond: [latestAngularVelocity.x, latestAngularVelocity.y, latestAngularVelocity.z],
            quality: quality,
            referenceSpaceRevision: referenceSpaceRevision
        )
        onPose?(pose)

        let image = frame.capturedImage
        let header = CaptureVideoFrameHeader(
            sequence: frameSequence,
            captureTimeNanoseconds: timestamp,
            width: UInt32(CVPixelBufferGetWidth(image)),
            height: UInt32(CVPixelBufferGetHeight(image)),
            codec: "raw-cv-pixel-buffer",
            isKeyFrame: true
        )
        onVideoSample?(CaptureVideoSample(header: header, pixelBuffer: image))

        if let sceneDepth = frame.sceneDepth {
            let depthHeader = CaptureDepthFrameHeader(
                sequence: frameSequence,
                captureTimeNanoseconds: timestamp,
                width: UInt32(CVPixelBufferGetWidth(sceneDepth.depthMap)),
                height: UInt32(CVPixelBufferGetHeight(sceneDepth.depthMap)),
                depthEncoding: "depth-float32",
                confidenceEncoding: "confidence-uint8"
            )
            onDepthSample?(
                CaptureDepthSample(
                    header: depthHeader,
                    depthMap: sceneDepth.depthMap,
                    confidenceMap: sceneDepth.confidenceMap
                )
            )
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        publishQualityIfNeeded(.lost)
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        publishQualityIfNeeded(.lost)
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        referenceSpaceRevision &+= 1
    }

    private func trackingQuality(for state: ARCamera.TrackingState) -> CaptureTrackingQuality {
        switch state {
        case .normal: .nominal
        case .limited: .limited
        case .notAvailable: .lost
        }
    }

    private func publishQualityIfNeeded(_ quality: CaptureTrackingQuality) {
        guard quality != lastQuality else { return }
        lastQuality = quality
        onTrackingQualityChanged?(quality)
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
