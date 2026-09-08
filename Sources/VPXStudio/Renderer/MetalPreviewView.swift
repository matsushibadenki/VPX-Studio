import MetalKit
import SwiftUI

struct MetalPreviewView: NSViewRepresentable {
    let latestVideoFrame: LatestVideoFrameStore
    let metrics: RealtimeMetricsStore
    let chromaKeyEnabled: Bool
    let chromaGreenThreshold: Float
    let chromaGreenSoftness: Float
    let focalLengthMillimeters: Float
    let radialDistortionK1: Float

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        guard let device = MTLCreateSystemDefaultDevice() else { return view }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.015, green: 0.02, blue: 0.04, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        guard let renderer = MetalRenderer(
            pixelFormat: view.colorPixelFormat,
            depthPixelFormat: view.depthStencilPixelFormat,
            latestVideoFrame: latestVideoFrame,
            metrics: metrics
        ) else { return view }
        context.coordinator.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.setChromaKey(
            enabled: chromaKeyEnabled,
            greenThreshold: chromaGreenThreshold,
            greenSoftness: chromaGreenSoftness
        )
        context.coordinator.renderer?.setFocalLength(focalLengthMillimeters)
        context.coordinator.renderer?.setRadialDistortion(radialDistortionK1)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: MetalRenderer?
    }
}
