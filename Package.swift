// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FountainMaintenanceKit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS("17"), .watchOS("10")],
    products: [
        .library(name: "FountainMaintenanceCore", targets: ["FountainMaintenanceCore"]),
        .library(name: "FountainMaintenanceClient", targets: ["FountainMaintenanceClient"]),
        .library(name: "FountainMaintenanceTestKit", targets: ["FountainMaintenanceTestKit"])
    ],
    targets: [
        .target(name: "FountainMaintenanceCore"),
        .target(name: "FountainMaintenanceClient", dependencies: ["FountainMaintenanceCore"]),
        .target(name: "FountainMaintenanceTestKit", dependencies: ["FountainMaintenanceCore", "FountainMaintenanceClient"]),
        .testTarget(name: "FountainMaintenanceCoreTests", dependencies: ["FountainMaintenanceCore", "FountainMaintenanceClient", "FountainMaintenanceTestKit"])
    ]
)
