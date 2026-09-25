// swift-tools-version:5.9
// Used for `swift test` only. The app bundle is still built by the Makefile.
import PackageDescription

let package = Package(
    name: "NetMenu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NetMenu",
            path: ".",
            exclude: ["Tests", "scripts", "images", "Casks", "build", "dist", "NetMenu.app",
                      "Info.plist", "Makefile", "README.md", "RELEASING.md", "LICENSE"],
            sources: ["constants.swift", "latency.swift", "health.swift", "speedtest.swift", "netmenu.swift", "main.swift"]
        ),
        .testTarget(
            name: "NetMenuTests",
            dependencies: ["NetMenu"],
            path: "Tests/NetMenuTests"
        ),
    ]
)
