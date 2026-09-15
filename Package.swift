// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "kacha",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "kacha", path: "Sources/Kacha"),
        .testTarget(name: "KachaTests", dependencies: ["kacha"], path: "Tests/KachaTests"),
    ]
)
