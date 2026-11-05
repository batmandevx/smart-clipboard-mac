// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipStack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipStack",
            path: "Sources/ClipStack"
        )
    ]
)

