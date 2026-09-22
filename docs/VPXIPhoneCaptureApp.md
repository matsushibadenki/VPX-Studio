# VPX iPhone Capture Node App

## [Done] Application entry point

`VPXIPhoneCaptureApp` is the iOS SwiftUI application entry target. It hosts the reusable `CaptureNodeControlView`, accepts `vpxstudio://pair/...` QR deep links, and keeps capture, pairing, discovery, and networking in `VPXIPhoneCapture` rather than the app shell.

## [Next] Xcode app-bundle integration

To install on a physical iPhone, add the package target to an iOS app bundle in Xcode and set a signing team. Add the following privacy usage descriptions to that bundle in English, Japanese, and Simplified Chinese:

- `NSCameraUsageDescription` — required for ARKit camera capture and QR pairing.
- `NSMotionUsageDescription` — required for CoreMotion pose data.
- `NSLocalNetworkUsageDescription` — required to discover and connect to the Mac Host on the LAN.
- `NSBonjourServices` — include `_vpxcapture._tcp`.

The pairing URL carries a 256-bit credential. It is stored only in the iPhone Keychain after a successful scan; do not put it in an Info.plist, UserDefaults, log, or Take package.
