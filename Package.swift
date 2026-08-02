// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LGforMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LGforMac",
            path: "Sources/LGforMac"
        )
    ]
)
