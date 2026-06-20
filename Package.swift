// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Boopr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Boopr",
            path: "Sources/Boopr"
        )
    ]
)
