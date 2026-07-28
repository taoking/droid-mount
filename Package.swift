// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DroidMount",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DroidMount", targets: ["DroidMount"]),
    ],
    targets: [
        .executableTarget(
            name: "DroidMount",
            path: "Sources/DroidMount",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "DroidMountTests",
            dependencies: ["DroidMount"],
            path: "Tests/DroidMountTests"
        ),
    ]
)
