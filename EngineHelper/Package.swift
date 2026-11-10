// swift-tools-version: 6.2

import PackageDescription

// acelinkui-engine runs the AceStream engine container in a lightweight Linux VM
// (Apple's Containerization framework), so AceLinkUI works without Docker. It is a
// separate executable because the framework needs macOS 26 and the app supports 13.
let package = Package(
    name: "acelinkui-engine",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.54.0"),
    ],
    targets: [
        .executableTarget(
            name: "acelinkui-engine",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
