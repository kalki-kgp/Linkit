// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LinkitMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LinkitMacReceiver", targets: ["LinkitMacReceiver"]),
        .executable(name: "LinkitMacMenu", targets: ["LinkitMacMenu"]),
        .library(name: "LinkitMacCore", targets: ["LinkitMacCore"])
    ],
    targets: [
        .target(name: "LinkitMacCore"),
        .executableTarget(
            name: "LinkitMacReceiver",
            dependencies: ["LinkitMacCore"]
        ),
        .executableTarget(
            name: "LinkitMacMenu",
            dependencies: ["LinkitMacCore"],
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .testTarget(
            name: "LinkitMacCoreTests",
            dependencies: ["LinkitMacCore"]
        )
    ]
)
