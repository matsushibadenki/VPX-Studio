#if os(iOS)
import Foundation
import VPXCaptureProtocol

/// Capture callbacks run outside the UI actor. Snapshot transport references
/// under a lock, then submit to Network.framework without holding the lock.
final class CaptureNodeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: CaptureSecureChannel?
    private var telemetry: CaptureDatagramChannel?
    func setStream(_ stream: CaptureSecureChannel?) { lock.withLock { self.stream=stream } }
    func setTelemetry(_ telemetry: CaptureDatagramChannel?) {
        let old=lock.withLock { let old=self.telemetry; self.telemetry=telemetry; return old }
        old?.cancel()
    }
    func sendVideo(_ frame: CaptureEncodedVideoFrame) throws { try lock.withLock { stream }?.sendVideo(frame) }
    func sendDepth(_ packet: CaptureDepthPacket) throws { try lock.withLock { stream }?.sendDepth(packet) }
    func sendPose(_ pose: CapturePosePacket) { lock.withLock { telemetry }?.send(.pose(pose)) }
    func sendQuality(_ event: CaptureQualityEvent) throws {
        try lock.withLock { stream }?.sendControl(CaptureMessageEnvelope(kind: .qualityEvent, payload: event))
        lock.withLock { telemetry }?.send(.diagnostic(event))
    }
}
#endif
