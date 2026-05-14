// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoubleFinder",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DoubleFinder",
            path: "Sources/DoubleFinder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
