// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Tokenozerca",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TokenozercaCore", targets: ["TokenozercaCore"]),
        .executable(name: "Tokenozerca", targets: ["Tokenozerca"]),
        .executable(name: "TokenozercaSelfTest", targets: ["TokenozercaSelfTest"]),
        .executable(name: "TokenozercaProbe", targets: ["TokenozercaProbe"])
    ],
    targets: [
        .target(
            name: "TokenozercaCore"
        ),
        .executableTarget(
            name: "Tokenozerca",
            dependencies: ["TokenozercaCore"]
        ),
        .executableTarget(
            name: "TokenozercaSelfTest",
            dependencies: ["TokenozercaCore"],
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "TokenozercaProbe",
            dependencies: ["TokenozercaCore"]
        )
    ]
)
