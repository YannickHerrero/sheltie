// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SheltieProtocol",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SheltieProtocol", targets: ["SheltieProtocol"]),
    ],
    targets: [
        .target(name: "SheltieProtocol"),
        .testTarget(
            name: "SheltieProtocolTests",
            dependencies: ["SheltieProtocol"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
