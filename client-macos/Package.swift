// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RustleApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RustleApp",
            path: "Sources/RustleApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
