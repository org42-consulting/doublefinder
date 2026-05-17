// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoubleFinder",
    defaultLocalization: "en",
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
                .copy("Resources/doublefinder.png"),
                .process("Resources/Localizable.xcstrings")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
