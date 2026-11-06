import SwiftUI

struct PipelineMeasurementsView: View {
    let values: PipelineMeasurements
    let poseAge: Double?
    let localization: LocalizationStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row(.captureEncode, milliseconds(values.captureToEncodeMilliseconds))
            row(.networkTransport, milliseconds(values.transportMilliseconds))
            row(.captureReceive, milliseconds(values.captureToReceiveMilliseconds))
            row(.receiveDecode, milliseconds(values.receiveToDecodeMilliseconds))
            row(.decodeDuration, milliseconds(values.decodeMilliseconds))
            row(.renderWait, milliseconds(values.decodeToRenderMilliseconds))
            row(.textureImport, milliseconds(values.textureImportMilliseconds))
            row(.presentationDelay, milliseconds(values.renderToPresentMilliseconds))
            row(.capturePresent, milliseconds(values.captureToPresentMilliseconds))
            row(.poseCaptureAge, milliseconds(poseAge))
            row(.residentMemory, values.residentMemoryBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "—")
            row(.knownCopies, "\(values.knownCPUCopyCount) / \(values.knownCPUCopyBytes) B")
            row(.bufferReuse, "\(values.pixelBufferReuseCount) / \(values.observedFrames)")
            row(.surfaceReuse, "\(values.ioSurfaceReuseCount) / \(values.ioSurfaceFrames)")
        }
        .font(.caption)
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f ms", $0) } ?? "—"
    }

    private func row(_ key: LocalizationKey, _ value: String) -> some View {
        GridRow {
            Text(localization.text(key)).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}
