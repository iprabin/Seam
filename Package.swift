// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Seam",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Seam", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
