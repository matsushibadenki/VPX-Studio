import MetalKit
import CoreMedia
import os

/// SwiftUI changes immutable settings; only the render thread owns the frame pipeline.
final class MetalRenderer: NSObject, MTKViewDelegate {
    private let capture: CompositeCapture
    private let personMatteWorker: PersonMatteWorker
    private let pipeline: MetalFramePipeline
    private let latestVideoFrame: LatestVideoFrameStore
    private let metrics: RealtimeMetricsStore
    private let settingsLock = NSLock()
    private var storedSettings = StudioRenderSettings()
    private let log = Logger(subsystem: "jp.vpxstudio",category: "renderer")

    init?(pixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat,
          latestVideoFrame: LatestVideoFrameStore, metrics: RealtimeMetricsStore) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do { pipeline = try MetalFramePipeline(device: device,pixelFormat: pixelFormat) }
        catch { Logger(subsystem: "jp.vpxstudio",category: "renderer").error("Pipeline: \(error.localizedDescription)"); return nil }
        capture = CompositeCapture(device: device)
        personMatteWorker = PersonMatteWorker(device: device)
        self.latestVideoFrame = latestVideoFrame; self.metrics = metrics
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        let captureTime = CMClockGetTime(CMClockGetHostTimeClock())
        let now = CACurrentMediaTime(), snapshot = latestVideoFrame.readSnapshot()
        let frame = snapshot.frame
        var settings = settingsLock.withLock { storedSettings }
        if settings.personMatteEnabled, settings.chromaEnabled, let frame {
            settings.personMatte = personMatteWorker.mask(for: frame, source: snapshot.sourceID, now: now)
        }
        do {
            let recorder = settings.debugView == .composite ? latestVideoFrame.compositeRecorder : nil
            let recordFrame: ((MTLCommandBuffer, MTLTexture, MTLTexture?, MTLFence, TakeAuxiliaryFrame) -> Void)?
            if let recorder {
                recordFrame = { command, output, matte, fence, auxiliary in
                    self.capture.encode(output, on: command, to: recorder, at: captureTime,
                        auxiliary: auxiliary, matte: matte, matteFence: fence)
                }
            } else {
                recordFrame = nil
            }
            let command = try pipeline.encode(frame: frame, target: drawable.texture, settings: settings, metrics: metrics,
                now: now, frameSourceID: snapshot.sourceID, capture10Bit: recorder?.preserve10Bit == true, capture: recordFrame)
            command.present(drawable)
            let captured = metrics.read().protection == .normal ? frame?.telemetry.captured : nil
            drawable.addPresentedHandler { [metrics] drawable in
                metrics.recordPresentation(at: drawable.presentedTime,submitted: now,captureTime: captured)
            }
            metrics.recordFrameSubmitted(at: now,inputFrame: frame,timeoutSeconds: settings.profile.inputTimeoutSeconds,
                                         expectedFramesPerSecond: settings.profile.framesPerSecond)
            command.commit()
        } catch { log.error("Frame encoding failed: \(error.localizedDescription)") }
    }

    func configure(_ settings: StudioRenderSettings) { settingsLock.withLock { storedSettings = settings } }

    func setChromaKey(enabled: Bool, greenThreshold: Float, greenSoftness: Float) {
        settingsLock.withLock {
            storedSettings.chromaEnabled = enabled
            storedSettings.greenThreshold = greenThreshold
            storedSettings.greenSoftness = greenSoftness
        }
    }
    func setFocalLength(_ millimeters: Float) { settingsLock.withLock { storedSettings.camera.setFocalLength(millimeters) } }
    func setRadialDistortion(_ coefficient: Float) { settingsLock.withLock { storedSettings.camera.lens.radialDistortionK1 = coefficient } }
}
