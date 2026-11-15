// swift-tools-version: 6.0
import PackageDescription
import Foundation

let studioInfo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/VPXStudio/StudioInfo.plist").path

let package = Package(
    name: "VPXStudio",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .executable(name: "VPXStudio", targets: ["VPXStudio"]),
        .executable(name: "VPXIPhoneCaptureApp", targets: ["VPXIPhoneCaptureApp"]),
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
            name: "VPXIPhoneCaptureApp",
            dependencies: ["VPXIPhoneCapture"]
        ),
        .executableTarget(
            name: "VPXStudio",
            dependencies: ["VPXCaptureProtocol"],
            exclude: ["StudioInfo.plist"],
            resources: [
                .copy("Resources/PreviewShaders.metal"),
                .copy("Resources/StudioPipeline.metal"),
                .process("Resources/LocalizationCatalog.json")
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", studioInfo], .when(platforms: [.macOS]))]
        ),
        .testTarget(
            name: "VPXStudioTests",
            dependencies: ["VPXStudio", "VPXCaptureProtocol"],
            resources: [.copy("Fixtures")]
        )
    ]
)
