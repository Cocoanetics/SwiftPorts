// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GitLFSPublicConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Explicit name also works when the checkout directory is SwiftPorts-agent.
        .package(name: "SwiftPorts", path: "../../.."),
        .package(url: "https://github.com/Cocoanetics/GitKit", from: "2.19.0"),
        .package(url: "https://github.com/Cocoanetics/ShellKit", .upToNextMinor(from: "0.1.2"))
    ],
    targets: [
        .testTarget(
            name: "TestServerConsumerTests",
            dependencies: [
                .product(name: "GitLFSTestSupport", package: "SwiftPorts")
            ]
        ),
        .testTarget(
            name: "NativeOperationTests",
            dependencies: [
                .product(name: "GitLFSKit", package: "SwiftPorts"),
                .product(name: "GitLFSTestSupport", package: "SwiftPorts"),
                .product(name: "GitKit", package: "GitKit"),
                .product(name: "ShellKit", package: "ShellKit")
            ]
        )
    ]
)
