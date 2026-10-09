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
        ),
        // The tiny command agents run for each hook event; forwards it to Lintel over 127.0.0.1.
        .executableTarget(
            name: "lintel-hook",
            path: "Sources/LintelHook"
        ),
    ]
)
