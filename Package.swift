// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "KapKap",
    platforms: [
        .macOS("12.3")
    ],
    products: [
        .executable(
            name: "KapKap",
            targets: ["KapKap"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "KapKap",
            dependencies: [],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["KapKap"],
            path: "Tests/AppTests"
        )
    ]
)
