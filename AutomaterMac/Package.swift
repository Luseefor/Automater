// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AutomaterMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutomaterKit", targets: ["AutomaterKit"]),
        .executable(name: "automater-cli", targets: ["automater-cli"]),
    ],
    targets: [
        .target(name: "AutomaterKit"),
        .executableTarget(
            name: "automater-cli",
            dependencies: ["AutomaterKit"]
        ),
        .executableTarget(
            name: "automater-app",
            dependencies: ["AutomaterKit"]
        ),
        .testTarget(name: "AutomaterAppTests", dependencies: ["automater-app"]),
        .testTarget(
            name: "AutomaterKitTests",
            dependencies: ["AutomaterKit"]
        ),
    ]
)
