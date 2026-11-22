// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GitLFSPublicConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Explicit name also works when the checkout directory is SwiftPorts-agent.
        .package(name: "SwiftPorts", path: "../../..")
    ],
    targets: [
        .testTarget(
            name: "TestServerConsumerTests",
            dependencies: [
                .product(name: "GitLFSTestSupport", package: "SwiftPorts")
            ]
        )
    ]
)
