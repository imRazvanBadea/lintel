// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lintel",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Lintel",
            path: "Sources/Lintel",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
