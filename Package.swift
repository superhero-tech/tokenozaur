// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "Tokenozaur",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "TokenozaurCore", targets: ["TokenozaurCore"]),
    .executable(name: "Tokenozaur", targets: ["Tokenozaur"]),
    .executable(name: "TokenozaurSelfTest", targets: ["TokenozaurSelfTest"]),
    .executable(name: "TokenozaurProbe", targets: ["TokenozaurProbe"]),
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite"
    ),
    .target(
      name: "TokenozaurCore",
      dependencies: ["CSQLite"]
    ),
    .executableTarget(
      name: "Tokenozaur",
      dependencies: ["TokenozaurCore"]
    ),
    .executableTarget(
      name: "TokenozaurSelfTest",
      dependencies: ["TokenozaurCore"],
      resources: [.copy("Fixtures")]
    ),
    .executableTarget(
      name: "TokenozaurProbe",
      dependencies: ["TokenozaurCore"]
    ),
  ]
)
