// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RushCut",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "RushCut",
            path: "Sources/RushCut"
        ),
        .testTarget(
            name: "RushCutTests",
            dependencies: ["RushCut"],
            path: "Tests/RushCutTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
