// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoubleFinder",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DoubleFinder",
            path: "Sources/DoubleFinder",
            resources: [
                .copy("Resources/DoubleFinder.icns")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
