#if os(iOS)
import SwiftUI
import VPXIPhoneCapture

/// iPhone Capture Node application entry point. Embedding this Swift Package
/// target in an Xcode iOS app supplies the normal app bundle, signing, and
/// privacy-manifest configuration while preserving the reusable capture library.
@main
struct VPXIPhoneCaptureApp: App {
    @State private var model = CaptureNodeSessionModel()

    var body: some Scene {
        WindowGroup {
            CaptureNodeControlView(model: model)
                .onOpenURL { url in
                    model.applyPairingPayload(url.absoluteString)
                }
        }
    }
}
#else
import Foundation

// SwiftPM resolves executable targets for the host platform while loading the
// package in Xcode. Keep a no-op host entry point so the iOS app target does not
// produce an undefined _main when the package is inspected on macOS.
@main
struct VPXIPhoneCaptureAppHostStub {
    static func main() {}
}
#endif
