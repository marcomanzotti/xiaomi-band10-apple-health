// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Band10Kit",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // The band's protocol and file formats: no Bluetooth, no HealthKit.
        .library(name: "Band10Kit", targets: ["Band10Kit"]),
        // The background sync engine an app embeds: Bluetooth, storage, HealthKit.
        .library(name: "Band10Sync", targets: ["Band10Sync"]),
    ],
    targets: [
        .target(name: "Band10Kit"),
        .target(name: "Band10Sync", dependencies: ["Band10Kit"], resources: [.process("Resources")]),
        .testTarget(name: "Band10KitTests", dependencies: ["Band10Kit"]),
        .testTarget(name: "Band10SyncTests", dependencies: ["Band10Sync"]),
    ]
)
