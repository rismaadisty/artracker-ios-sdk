// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ARTracker",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ARTracker",
            targets: ["ARTracker"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/plcrashreporter.git", from: "1.11.2"),
    ],
    targets: [
        .target(
            name: "ARTrackerNative",
            path: "Sources/ARTrackerNative",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ARTracker",
            dependencies: [
                "ARTrackerNative",
                .product(name: "CrashReporter", package: "plcrashreporter")
            ],
            path: "Sources/ARTracker",
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "ARTrackerTests",
            dependencies: [
                "ARTracker",
                "ARTrackerNative"
            ],
            path: "Tests/ARTrackerTests"
        ),
    ]
)
