// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VPXStudio",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .executable(name: "VPXStudio", targets: ["VPXStudio"]),
        .library(name: "VPXCaptureProtocol", targets: ["VPXCaptureProtocol"]),
        .library(name: "VPXIPhoneCapture", targets: ["VPXIPhoneCapture"])
    ],
    targets: [
        .target(name: "VPXCaptureProtocol"),
        .target(
            name: "VPXIPhoneCapture",
            dependencies: ["VPXCaptureProtocol"]
        ),
        .executableTarget(
            name: "VPXStudio",
            dependencies: ["VPXCaptureProtocol"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "VPXStudioTests",
            dependencies: ["VPXStudio", "VPXCaptureProtocol"]
        )
    ]
)
