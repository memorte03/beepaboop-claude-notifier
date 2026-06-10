// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Beepaboop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Beepaboop",
            path: "Sources/Beepaboop"
        )
    ]
)
