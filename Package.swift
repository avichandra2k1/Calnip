// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Calnip",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Calnip",
            path: "Sources/Calnip",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
