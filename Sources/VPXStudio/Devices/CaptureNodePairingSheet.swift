import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VPXCaptureProtocol

struct CaptureNodePairingSheet: View {
    let credential: CapturePairingCredential
    @Bindable var localization: LocalizationStore
    let stop: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text(localization.text(.pairIPhone))
                .font(.title2.weight(.semibold))
            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .accessibilityLabel(localization.text(.scanQRCode))
            }
            Text(localization.text(.scanQRCode))
                .font(.headline)
            Text(localization.text(.pairingInstructions))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(localization.text(.verificationCode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(credential.verificationCode)
                    .font(.title.monospacedDigit().weight(.bold))
                    .textSelection(.enabled)
            }
            Text(credential.qrPayload)
                .font(.caption2.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Button(localization.text(.stopPairing), role: .destructive) {
                stop()
                dismiss()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(credential.qrPayload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 240, height: 240))
    }
}
