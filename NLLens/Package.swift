// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NLLensCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NLLensCore", targets: ["NLLensCore"])
    ],
    targets: [
        .target(
            name: "NLLensCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NLLensCoreTests",
            dependencies: ["NLLensCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
