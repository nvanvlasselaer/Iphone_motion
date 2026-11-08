// swift-tools-version: 5.10
//
//  RecorderCore: platform-independent logic shared by the iPhone and Apple Watch apps.
//  Foundation-only (CoreMotion glue is compiled on iOS/watchOS only), so `swift test` runs on the Mac.
//

import PackageDescription

let package = Package(
    name: "RecorderCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
    ],
    targets: [
        .target(
            name: "RecorderCore",
            resources: [.copy("Resources/DATA_FORMAT.md")]
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"]
        ),
    ]
)
