// swift-tools-version:6.2
import Foundation
import PackageDescription

// SwiftPorts is a monorepo of pure-Swift, cross-platform
// reimplementations of standard CLI tools and SDK clients.
//
// Layout convention:
//   - A pure library port lives flat at `Sources/<Name>/`.
//   - A library + binary(ies) port lives under an umbrella folder
//     `Sources/<Umbrella>/` with these subfolders:
//       Lib/             — the SDK library target, named "<Umbrella>"
//       <X>Command/      — one library target per binary, holds the
//                          AsyncParsableCommand types (extendable by
//                          SwiftBash via cross-package import)
//       <x>/             — one executable target per binary, a four-line
//                          @main wrapper that delegates to <X>Command
//   - Library target names are PascalCase, executable target names are
//     lowercase and match the binary name.

// Detect cross-compile-to-Android by looking at the env var the
// swift-android-action sets. The action's link recipe currently fails
// on executable targets with `undefined symbol: __libc_init`
// (skiptools/swift-android-action#23), so when targeting Android we
// drop the executable products + targets at manifest evaluation time
// and only build the libraries that downstream embedders consume.
let isAndroid = ProcessInfo.processInfo.environment["TARGET_OS_ANDROID"] != nil

let executableProducts: [Product] = isAndroid ? [] : [
    .executable(name: "zip", targets: ["zip"]),
    .executable(name: "unzip", targets: ["unzip"]),
    .executable(name: "gh", targets: ["gh"]),
    .executable(name: "glab", targets: ["glab"]),
    .executable(name: "git", targets: ["git"]),
]

let executableTargets: [Target] = isAndroid ? [] : [
    .executableTarget(
        name: "zip",
        dependencies: ["ZipCommand"],
        path: "Sources/ZipKit/zip"
    ),
    .executableTarget(
        name: "unzip",
        dependencies: ["UnzipCommand"],
        path: "Sources/ZipKit/unzip"
    ),
    .executableTarget(
        name: "gh",
        dependencies: ["GhCommand"],
        path: "Sources/GitHub/gh"
    ),
    .executableTarget(
        name: "glab",
        dependencies: ["GlabCommand"],
        path: "Sources/GitLab/glab"
    ),
    .executableTarget(
        name: "git",
        dependencies: ["GitCommand"],
        path: "Sources/SwiftGit/git"
    ),
]

let package = Package(
    name: "SwiftPorts",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        // ForgeKit — host-agnostic CLI plumbing (IO, Git, Secrets).
        .library(name: "ForgeKit", targets: ["ForgeKit"]),

        // ZipKit umbrella — Info-ZIP family.
        .library(name: "ZipKit", targets: ["ZipKit"]),
        .library(name: "ZipCommand", targets: ["ZipCommand"]),
        .library(name: "UnzipCommand", targets: ["UnzipCommand"]),

        // GitHub umbrella — gh(1) port.
        .library(name: "GitHub", targets: ["GitHub"]),
        .library(name: "GhCommand", targets: ["GhCommand"]),

        // GitLab umbrella — glab port.
        .library(name: "GitLab", targets: ["GitLab"]),
        .library(name: "GlabCommand", targets: ["GlabCommand"]),

        // SwiftGit umbrella — libgit2-backed `GitClient` SDK + `git` CLI.
        // SDK lib is named `SwiftGit` (matching the umbrella folder) so
        // its `SwiftGit.build` artifact directory doesn't case-fold-collide
        // with `git.build` on macOS's case-insensitive filesystem.
        .library(name: "SwiftGit", targets: ["SwiftGit"]),
        .library(name: "GitCommand", targets: ["GitCommand"]),
    ] + executableProducts,
    dependencies: [
        // Apple / swiftlang
        .package(url: "https://github.com/apple/swift-argument-parser",
                 from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log",
                 from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-http-types",
                 from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-configuration",
                 from: "1.2.0",
                 traits: [.defaults, "YAML", "CommandLineArguments"]),
        .package(url: "https://github.com/apple/swift-crypto",
                 from: "3.0.0"),

        // Community
        .package(url: "https://github.com/jpsim/Yams",
                 from: "6.0.0"),
        // Pinned to a fork while https://github.com/weichsel/ZIPFoundation/pull/<TBD>
        // is open — adds explicit `import Bionic` so the package compiles on
        // Android. Roll back to upstream once the PR lands.
        .package(url: "https://github.com/odrobnik/ZIPFoundation",
                 branch: "fix/android-windows-imports"),

        // libgit2 1.9.x packaged as a SwiftPM C target. We pin to our
        // own fork while https://github.com/ibrahimcetin/libgit2/pull/<TBD>
        // is open — it adds Windows + Android arms to Package.swift so
        // the SwiftPM build covers all five of our CI platforms. Roll
        // back to upstream once the PR lands.
        .package(url: "https://github.com/odrobnik/libgit2",
                 branch: "windows-android-platforms"),
    ],
    targets: [
        // MARK: ForgeKit (host-agnostic plumbing)
        .target(
            name: "ForgeKit",
            path: "Sources/ForgeKit"
        ),

        // MARK: ZipKit umbrella
        .target(
            name: "ZipKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/ZipKit/Lib"
        ),
        .target(
            name: "ZipCommand",
            dependencies: [
                "ZipKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ZipKit/ZipCommand"
        ),
        .target(
            name: "UnzipCommand",
            dependencies: [
                "ZipKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ZipKit/UnzipCommand"
        ),
        .testTarget(
            name: "ZipKitTests",
            dependencies: ["ZipKit"]
        ),
        .testTarget(
            name: "ZipTests",
            dependencies: ["ZipCommand", "ZipKit"]
        ),
        .testTarget(
            name: "UnzipTests",
            dependencies: ["UnzipCommand", "ZipKit"]
        ),

        // MARK: GitHub umbrella
        .target(
            name: "GitHub",
            dependencies: [
                "ForgeKit",
                "ZipKit",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/GitHub/Lib"
        ),
        .target(
            name: "GhCommand",
            dependencies: [
                "GitHub",
                "ForgeKit",
                "SwiftGit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GitHub/GhCommand"
        ),
        .testTarget(
            name: "GitHubTests",
            dependencies: ["GitHub", "GhCommand", "ForgeKit"],
            resources: [
                .copy("Fixtures"),
            ]
        ),

        // MARK: GitLab umbrella
        .target(
            name: "GitLab",
            dependencies: [
                "ForgeKit",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            ],
            path: "Sources/GitLab/Lib"
        ),
        .target(
            name: "GlabCommand",
            dependencies: [
                "GitLab",
                "ForgeKit",
                "SwiftGit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GitLab/GlabCommand"
        ),
        .testTarget(
            name: "GitLabTests",
            dependencies: ["GitLab", "GlabCommand", "ForgeKit"]
            // Re-add `resources: [.copy("Fixtures")]` once Tests/GitLabTests/Fixtures
            // has any tracked files; the empty dir doesn't survive git checkout.
        ),

        // MARK: SwiftGit umbrella (libgit2-backed GitClient + `git` CLI)
        .target(
            name: "SwiftGit",
            dependencies: [
                "ForgeKit",
                .product(name: "libgit2", package: "libgit2"),
            ],
            path: "Sources/SwiftGit/Lib"
        ),
        .target(
            name: "GitCommand",
            dependencies: [
                "SwiftGit",
                "ForgeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "libgit2", package: "libgit2"),
            ],
            path: "Sources/SwiftGit/GitCommand"
        ),
        .testTarget(
            name: "SwiftGitTests",
            dependencies: ["SwiftGit", "ForgeKit"]
        ),
        .testTarget(
            name: "GitCommandTests",
            dependencies: ["GitCommand", "SwiftGit", "ForgeKit"]
        ),
    ] + executableTargets
)
