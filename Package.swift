// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FountainMaintenanceKit",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "FountainMaintenanceCore", targets: ["FountainMaintenanceCore"]),
        .library(name: "FountainMaintenanceClient", targets: ["FountainMaintenanceClient"]),
        .library(name: "FountainMaintenanceTestKit", targets: ["FountainMaintenanceTestKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(name: "FountainMaintenanceCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .target(name: "FountainMaintenanceClient", dependencies: ["FountainMaintenanceCore"]),
        .target(name: "FountainMaintenanceTestKit", dependencies: ["FountainMaintenanceCore", "FountainMaintenanceClient"]),
        .testTarget(name: "FountainMaintenanceCoreTests", dependencies: ["FountainMaintenanceCore", "FountainMaintenanceClient", "FountainMaintenanceTestKit"])
    ]
)
