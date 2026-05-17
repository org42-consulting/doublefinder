// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoubleFinder",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "DoubleFinderC",
            path: "Sources/DoubleFinderC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "DoubleFinder",
            dependencies: ["DoubleFinderC"],
            path: "Sources/DoubleFinder",
            resources: [
                .copy("Resources/DoubleFinder.icns"),
                .copy("Resources/doublefinder.png")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
