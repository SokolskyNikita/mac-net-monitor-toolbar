// swift-tools-version:5.9
// Used for `swift test` only. The app bundle is still built by the Makefile.
import PackageDescription

let package = Package(
    name: "NetMenu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NetMenu"
        ),
        .testTarget(
            name: "NetMenuTests",
            dependencies: ["NetMenu"],
            path: "Tests/NetMenuTests"
        ),
    ]
)
