// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenScope",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TokenScope",
            path: "Sources/TokenScope"
        )
    ]
)
