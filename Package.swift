// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVCompanion",
    platforms: [
        .tvOS(.v17),
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "TVCompanion", targets: ["TVCompanion"]),
    ],
    targets: [
        .target(
            name: "TVCompanion",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "TVCompanionTests",
            dependencies: ["TVCompanion"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
