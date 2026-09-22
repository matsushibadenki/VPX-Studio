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
#endif
