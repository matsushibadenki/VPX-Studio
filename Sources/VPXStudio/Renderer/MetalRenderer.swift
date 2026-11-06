import MetalKit
import CoreMedia
import os

/// SwiftUI changes immutable settings; only the render thread owns the frame pipeline.
final class MetalRenderer: NSObject, MTKViewDelegate {
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
        self.latestVideoFrame = latestVideoFrame; self.metrics = metrics
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime(), frame = latestVideoFrame.read()
        let settings = settingsLock.withLock { storedSettings }
        do {
            let command = try pipeline.encode(frame: frame,target: drawable.texture,settings: settings,metrics: metrics,now: now)
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
