// swift-tools-version:6.2
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

let package = Package(
    name: "SwiftPorts",
    // Aligned with our largest direct Apple dependency, swift-archive
    // (`.macOS(.v13), .iOS(.v15), .tvOS(.v15), .watchOS(.v10)`), and
    // with downstream SwiftBash (`macOS 13 / iOS 16 / tvOS 16 /
    // watchOS 9`). No source under Sources/ uses `@available` or
    // `if #available`, so lowering the bound is mechanical.
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // Sandbox — TaskLocal-driven path & URL gating for embedding.
        // Zero dependencies beyond Foundation. Every library that
        // touches URLs / env / argv depends on this.
        .library(name: "Sandbox", targets: ["Sandbox"]),

        // ForgeKit — host-agnostic CLI plumbing (IO, Git, Secrets).
        .library(name: "ForgeKit", targets: ["ForgeKit"]),

        // ZipKit umbrella — Info-ZIP family.
        .library(name: "ZipKit", targets: ["ZipKit"]),
        .library(name: "ZipCommand", targets: ["ZipCommand"]),
        .library(name: "UnzipCommand", targets: ["UnzipCommand"]),
        .executable(name: "zip", targets: ["zip"]),
        .executable(name: "unzip", targets: ["unzip"]),

        // TarKit umbrella — POSIX tar with libarchive backend.
        .library(name: "TarKit", targets: ["TarKit"]),
        .library(name: "TarCommand", targets: ["TarCommand"]),
        .executable(name: "tar", targets: ["tar"]),

        // GzipKit umbrella — single-file gzip via libarchive's
        // raw + gzip filter. One library + three personalities
        // (gzip / gunzip / zcat).
        .library(name: "GzipKit", targets: ["GzipKit"]),
        .library(name: "GzipCommand", targets: ["GzipCommand"]),
        .executable(name: "gzip", targets: ["gzip"]),
        .executable(name: "gunzip", targets: ["gunzip"]),
        .executable(name: "zcat", targets: ["zcat"]),

        // Bzip2Kit umbrella — single-file bzip2 via libbz2's stream API.
        .library(name: "Bzip2Kit", targets: ["Bzip2Kit"]),
        .library(name: "Bzip2Command", targets: ["Bzip2Command"]),
        .executable(name: "bzip2", targets: ["bzip2"]),
        .executable(name: "bunzip2", targets: ["bunzip2"]),
        .executable(name: "bzcat", targets: ["bzcat"]),

        // XzKit umbrella — single-file xz / lzma2 via liblzma's stream API.
        .library(name: "XzKit", targets: ["XzKit"]),
        .library(name: "XzCommand", targets: ["XzCommand"]),
        .executable(name: "xz", targets: ["xz"]),
        .executable(name: "unxz", targets: ["unxz"]),
        .executable(name: "xzcat", targets: ["xzcat"]),

        // ZstdKit umbrella — single-file Zstandard via libzstd's stream API.
        .library(name: "ZstdKit", targets: ["ZstdKit"]),
        .library(name: "ZstdCommand", targets: ["ZstdCommand"]),
        .executable(name: "zstd", targets: ["zstd"]),
        .executable(name: "unzstd", targets: ["unzstd"]),
        .executable(name: "zstdcat", targets: ["zstdcat"]),

        // Lz4Kit umbrella — single-file LZ4 frame format. Apple
        // platforms back the engine with Compression.framework's
        // LZ4_RAW; Linux/Windows use system liblz4.
        .library(name: "Lz4Kit", targets: ["Lz4Kit"]),
        .library(name: "Lz4Command", targets: ["Lz4Command"]),
        .executable(name: "lz4", targets: ["lz4"]),
        .executable(name: "unlz4", targets: ["unlz4"]),
        .executable(name: "lz4cat", targets: ["lz4cat"]),

        // JqKit umbrella — pure-Swift jq engine. No system C dependency,
        // so the library and command targets work everywhere; the `jq`
        // executable target is universal too (Apple-mobile builds it as
        // a stub that's never invoked).
        .library(name: "JqKit", targets: ["JqKit"]),
        .library(name: "JqCommand", targets: ["JqCommand"]),
        .executable(name: "jq", targets: ["jq"]),

        // GitHub umbrella — gh(1) port.
        .library(name: "GitHub", targets: ["GitHub"]),
        .library(name: "GhCommand", targets: ["GhCommand"]),
        .executable(name: "gh", targets: ["gh"]),

        // GitLab umbrella — glab port.
        .library(name: "GitLab", targets: ["GitLab"]),
        .library(name: "GlabCommand", targets: ["GlabCommand"]),
        .executable(name: "glab", targets: ["glab"]),

        // SwiftGit umbrella — libgit2-backed `GitClient` SDK + `git` CLI.
        // SDK lib is named `SwiftGit` (matching the umbrella folder) so
        // its `SwiftGit.build` artifact directory doesn't case-fold-collide
        // with `git.build` on macOS's case-insensitive filesystem.
        .library(name: "SwiftGit", targets: ["SwiftGit"]),
        .library(name: "GitCommand", targets: ["GitCommand"]),
        .executable(name: "git", targets: ["git"]),
    ],
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
        // libarchive-backed multi-format archive library (tar, zip, 7z,
        // cpio, xar, ISO9660, …) with gzip/bzip2/xz/zstd filters. The
        // platform-narrowed gating from
        // https://github.com/marcprux/swift-archive/pull/2 is now on
        // upstream `master` but not yet in a tagged release — track the
        // branch until v3.8.8 (or later) ships, then move to a `from:`
        // version pin.
        .package(url: "https://github.com/marcprux/swift-archive",
                 branch: "master",
                 traits: [.defaults,
                          "GzipSupport",
                          "Bzip2Support",
                          "LZMASupport",
                          "ZstdSupport"]),

        // libgit2 1.9.x packaged as a SwiftPM C target. We pin to our
        // own fork while https://github.com/ibrahimcetin/libgit2/pull/<TBD>
        // is open — it adds Windows + Android arms to Package.swift so
        // the SwiftPM build covers all five of our CI platforms. Roll
        // back to upstream once the PR lands.
        .package(url: "https://github.com/odrobnik/libgit2",
                 branch: "windows-android-platforms"),
    ],
    targets: [
        // MARK: Sandbox (TaskLocal URL/env/argv gating)
        .target(
            name: "Sandbox",
            path: "Sources/Sandbox",
            exclude: ["AUDIT.md"]
        ),
        .testTarget(
            name: "SandboxTests",
            dependencies: ["Sandbox"]
        ),

        // MARK: ForgeKit (host-agnostic plumbing)
        .target(
            name: "ForgeKit",
            dependencies: ["Sandbox"],
            path: "Sources/ForgeKit"
        ),

        // MARK: ZipKit umbrella
        .target(
            name: "ZipKit",
            dependencies: [
                "Sandbox",
                .product(name: "Archive", package: "swift-archive"),
            ],
            path: "Sources/ZipKit/Lib"
        ),
        .target(
            name: "ZipCommand",
            dependencies: [
                "ZipKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ZipKit/ZipCommand"
        ),
        .target(
            name: "UnzipCommand",
            dependencies: [
                "ZipKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ZipKit/UnzipCommand"
        ),
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
        .testTarget(
            name: "ZipKitTests",
            dependencies: [
                "ZipKit",
                // Same rationale as TarKitTests — needed to write
                // malicious zips for the path-traversal extract guards.
                .product(name: "Archive", package: "swift-archive"),
            ]
        ),
        .testTarget(
            name: "ZipTests",
            dependencies: ["ZipCommand", "ZipKit"]
        ),
        .testTarget(
            name: "UnzipTests",
            dependencies: ["UnzipCommand", "ZipKit"]
        ),

        // MARK: TarKit umbrella
        .target(
            name: "TarKit",
            dependencies: [
                "Sandbox",
                .product(name: "Archive", package: "swift-archive"),
            ],
            path: "Sources/TarKit/Lib"
        ),
        .target(
            name: "TarCommand",
            dependencies: [
                "TarKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/TarKit/TarCommand"
        ),
        .executableTarget(
            name: "tar",
            dependencies: ["TarCommand"],
            path: "Sources/TarKit/tar"
        ),
        .testTarget(
            name: "TarKitTests",
            dependencies: [
                "TarKit",
                // Direct libarchive access so tests can mint archives
                // with hostile entry names that our own create() refuses
                // to produce — needed to verify the extract path-
                // traversal guards.
                .product(name: "Archive", package: "swift-archive"),
            ]
        ),
        .testTarget(
            name: "TarTests",
            dependencies: ["TarCommand", "TarKit"]
        ),

        // MARK: GzipKit umbrella
        // Uses zlib directly (via the local SPCZlib systemLibrary)
        // rather than libarchive — libarchive's read side excludes
        // `raw` format by default, so a pure single-file gzip stream
        // written with libarchive's raw+gzip filter can't be parsed
        // back by the same wrapper. zlib's own inflate/deflate handle
        // gzip framing natively (`MAX_WBITS + 16` for write, `+ 32`
        // for read auto-detection) and zlib is already on every
        // platform we target.
        //
        // Named `SPCZlib` (not `CZlib`) so SwiftBash — which has its
        // own pre-existing public `CZlib` systemLibrary product — can
        // depend on SwiftPorts without a SwiftPM target-name collision.
        .systemLibrary(
            name: "SPCZlib",
            path: "Sources/SPCZlib",
            pkgConfig: "zlib",
            providers: [
                .brew(["zlib"]),
                .apt(["zlib1g-dev"]),
            ]
        ),
        .systemLibrary(
            name: "CBzip2",
            path: "Sources/CBzip2",
            pkgConfig: "bzip2",
            providers: [
                .brew(["bzip2"]),
                .apt(["libbz2-dev"]),
            ]
        ),
        .systemLibrary(
            name: "CLZMA",
            path: "Sources/CLZMA",
            pkgConfig: "liblzma",
            providers: [
                .brew(["xz"]),
                .apt(["liblzma-dev"]),
            ]
        ),
        .systemLibrary(
            name: "CZstd",
            path: "Sources/CZstd",
            pkgConfig: "libzstd",
            providers: [
                .brew(["zstd"]),
                .apt(["libzstd-dev"]),
            ]
        ),
        .systemLibrary(
            name: "CLz4",
            path: "Sources/CLz4",
            pkgConfig: "liblz4",
            providers: [
                .brew(["lz4"]),
                .apt(["liblz4-dev"]),
            ]
        ),
        .target(
            name: "GzipKit",
            dependencies: ["SPCZlib", "Sandbox"],
            path: "Sources/GzipKit/Lib"
        ),
        .target(
            name: "GzipCommand",
            dependencies: [
                "GzipKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GzipKit/GzipCommand"
        ),
        .executableTarget(
            name: "gzip",
            dependencies: ["GzipCommand"],
            path: "Sources/GzipKit/gzip"
        ),
        .executableTarget(
            name: "gunzip",
            dependencies: ["GzipCommand"],
            path: "Sources/GzipKit/gunzip"
        ),
        .executableTarget(
            name: "zcat",
            dependencies: ["GzipCommand"],
            path: "Sources/GzipKit/zcat"
        ),
        .testTarget(
            name: "GzipKitTests",
            dependencies: ["GzipKit"]
        ),
        .testTarget(
            name: "GzipTests",
            dependencies: ["GzipCommand", "GzipKit"]
        ),

        // MARK: Bzip2Kit umbrella
        // libbz2 isn't in the iOS / tvOS / watchOS / visionOS SDK, and
        // Android NDK doesn't ship `<bzlib.h>` either. Gate the
        // CBzip2 dep so SwiftPM doesn't try to honor `link "bz2"` on
        // those platforms — the kit's source-level `#if` already
        // empties the module on those platforms; this prevents the
        // link directive from leaking through.
        .target(
            name: "Bzip2Kit",
            dependencies: [
                "Sandbox",
                .target(name: "CBzip2",
                        condition: .when(platforms: [.macOS, .linux, .windows])),
            ],
            path: "Sources/Bzip2Kit/Lib"
        ),
        .target(
            name: "Bzip2Command",
            dependencies: [
                "Bzip2Kit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Bzip2Kit/Bzip2Command"
        ),
        .executableTarget(
            name: "bzip2",
            dependencies: ["Bzip2Command"],
            path: "Sources/Bzip2Kit/bzip2"
        ),
        .executableTarget(
            name: "bunzip2",
            dependencies: ["Bzip2Command"],
            path: "Sources/Bzip2Kit/bunzip2"
        ),
        .executableTarget(
            name: "bzcat",
            dependencies: ["Bzip2Command"],
            path: "Sources/Bzip2Kit/bzcat"
        ),
        .testTarget(
            name: "Bzip2KitTests",
            dependencies: ["Bzip2Kit"]
        ),
        .testTarget(
            name: "Bzip2Tests",
            dependencies: ["Bzip2Command", "Bzip2Kit"]
        ),

        // MARK: XzKit umbrella
        // Apple platforms (macOS / iOS / tvOS / watchOS / visionOS)
        // back the engine with `Compression.framework`'s LZMA path,
        // which produces and consumes real `.xz` byte streams. Linux
        // / Windows still use system `liblzma` via the CLZMA shim.
        // Android stays gated out — no NDK liblzma and no Compression
        // framework either.
        .target(
            name: "XzKit",
            dependencies: [
                "Sandbox",
                .target(name: "CLZMA",
                        condition: .when(platforms: [.linux, .windows])),
            ],
            path: "Sources/XzKit/Lib"
        ),
        .target(
            name: "XzCommand",
            dependencies: [
                "XzKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/XzKit/XzCommand"
        ),
        .executableTarget(
            name: "xz",
            dependencies: ["XzCommand"],
            path: "Sources/XzKit/xz"
        ),
        .executableTarget(
            name: "unxz",
            dependencies: ["XzCommand"],
            path: "Sources/XzKit/unxz"
        ),
        .executableTarget(
            name: "xzcat",
            dependencies: ["XzCommand"],
            path: "Sources/XzKit/xzcat"
        ),
        .testTarget(
            name: "XzKitTests",
            dependencies: ["XzKit"]
        ),
        .testTarget(
            name: "XzTests",
            dependencies: ["XzCommand", "XzKit"]
        ),

        // MARK: ZstdKit umbrella
        // Same gating as Bzip2Kit — see comment there.
        .target(
            name: "ZstdKit",
            dependencies: [
                "Sandbox",
                .target(name: "CZstd",
                        condition: .when(platforms: [.macOS, .linux, .windows])),
            ],
            path: "Sources/ZstdKit/Lib"
        ),
        .target(
            name: "ZstdCommand",
            dependencies: [
                "ZstdKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ZstdKit/ZstdCommand"
        ),
        .executableTarget(
            name: "zstd",
            dependencies: ["ZstdCommand"],
            path: "Sources/ZstdKit/zstd"
        ),
        .executableTarget(
            name: "unzstd",
            dependencies: ["ZstdCommand"],
            path: "Sources/ZstdKit/unzstd"
        ),
        .executableTarget(
            name: "zstdcat",
            dependencies: ["ZstdCommand"],
            path: "Sources/ZstdKit/zstdcat"
        ),
        .testTarget(
            name: "ZstdKitTests",
            dependencies: ["ZstdKit"]
        ),
        .testTarget(
            name: "ZstdTests",
            dependencies: ["ZstdCommand", "ZstdKit"]
        ),

        // MARK: Lz4Kit umbrella
        // Apple platforms (macOS / iOS / tvOS / watchOS / visionOS)
        // use Compression.framework's `LZ4_RAW` block coder; Linux
        // / Windows use system liblz4. Both produce standard
        // `.lz4` v1.6.x frames via our Swift framing layer. Android
        // gated out (no liblz4 in NDK).
        .target(
            name: "Lz4Kit",
            dependencies: [
                "Sandbox",
                .target(name: "CLz4",
                        condition: .when(platforms: [.linux, .windows])),
            ],
            path: "Sources/Lz4Kit/Lib"
        ),
        .target(
            name: "Lz4Command",
            dependencies: [
                "Lz4Kit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Lz4Kit/Lz4Command"
        ),
        .executableTarget(
            name: "lz4",
            dependencies: ["Lz4Command"],
            path: "Sources/Lz4Kit/lz4"
        ),
        .executableTarget(
            name: "unlz4",
            dependencies: ["Lz4Command"],
            path: "Sources/Lz4Kit/unlz4"
        ),
        .executableTarget(
            name: "lz4cat",
            dependencies: ["Lz4Command"],
            path: "Sources/Lz4Kit/lz4cat"
        ),
        .testTarget(
            name: "Lz4KitTests",
            dependencies: ["Lz4Kit"]
        ),
        .testTarget(
            name: "Lz4Tests",
            dependencies: ["Lz4Command", "Lz4Kit"]
        ),

        // MARK: JqKit umbrella
        // Pure-Swift jq engine ported from SwiftBash. Recursive-descent
        // parser + evaluator over Foundation's `JSONSerialization`, no
        // system C dependency — the same code runs on every platform we
        // ship to (macOS / iOS / tvOS / watchOS / visionOS / Linux /
        // Windows / Android), so no platform gating is needed at the
        // module level. The `jq` executable target compiles everywhere
        // for the same reason; on Apple-mobile it builds as a never-
        // invoked binary, matching how we treat the rest of our CLIs.
        .target(
            name: "JqKit",
            path: "Sources/JqKit/Lib"
        ),
        .target(
            name: "JqCommand",
            dependencies: [
                "JqKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/JqKit/JqCommand"
        ),
        .executableTarget(
            name: "jq",
            dependencies: ["JqCommand"],
            path: "Sources/JqKit/jq"
        ),
        .testTarget(
            name: "JqKitTests",
            dependencies: ["JqKit"]
        ),
        .testTarget(
            name: "JqTests",
            dependencies: ["JqCommand", "JqKit"]
        ),

        // MARK: GitHub umbrella
        .target(
            name: "GitHub",
            dependencies: [
                "ForgeKit",
                "Sandbox",
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
                "JqKit",
                "Lz4Kit",
                "Sandbox",
                "SwiftGit",
                "TarKit",
                "XzKit",
                "ZipKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GitHub/GhCommand"
        ),
        .executableTarget(
            name: "gh",
            dependencies: ["GhCommand"],
            path: "Sources/GitHub/gh"
        ),
        .testTarget(
            name: "GitHubTests",
            dependencies: [
                "GitHub", "GhCommand", "ForgeKit", "Sandbox",
                "JqKit", "Lz4Kit", "TarKit", "XzKit", "ZipKit",
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),

        // MARK: GitLab umbrella
        .target(
            name: "GitLab",
            dependencies: [
                "ForgeKit",
                "Sandbox",
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
                "JqKit",
                "Sandbox",
                "SwiftGit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GitLab/GlabCommand"
        ),
        .executableTarget(
            name: "glab",
            dependencies: ["GlabCommand"],
            path: "Sources/GitLab/glab"
        ),
        .testTarget(
            name: "GitLabTests",
            dependencies: ["GitLab", "GlabCommand", "ForgeKit"]
            // Re-add `resources: [.copy("Fixtures")]` once Tests/GitLabTests/Fixtures
            // has any tracked files; the empty dir doesn't survive git checkout.
        ),

        // MARK: CLibgit2Shim — typed C wrappers for the variadic
        // `git_libgit2_opts(int option, ...)` API. Used by the
        // Sandbox ↔ libgit2 env-bridge in SwiftGit's
        // `Libgit2Sandboxing` actor.
        .target(
            name: "CLibgit2Shim",
            dependencies: [
                .product(name: "libgit2", package: "libgit2"),
            ],
            path: "Sources/CLibgit2Shim",
            publicHeadersPath: "include"
        ),

        // MARK: SwiftGit umbrella (libgit2-backed GitClient + `git` CLI)
        .target(
            name: "SwiftGit",
            dependencies: [
                "CLibgit2Shim",
                "ForgeKit",
                "Sandbox",
                .product(name: "libgit2", package: "libgit2"),
                // For `git archive` — libarchive's writer is the
                // backend so the operation runs in-process and works
                // under sandboxed iOS / tvOS / watchOS.
                .product(name: "Archive", package: "swift-archive"),
            ],
            path: "Sources/SwiftGit/Lib"
        ),
        .target(
            name: "GitCommand",
            dependencies: [
                "SwiftGit",
                "ForgeKit",
                "Sandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "libgit2", package: "libgit2"),
            ],
            path: "Sources/SwiftGit/GitCommand"
        ),
        .executableTarget(
            name: "git",
            dependencies: ["GitCommand", "Sandbox"],
            path: "Sources/SwiftGit/git"
        ),
        .testTarget(
            name: "SwiftGitTests",
            dependencies: ["SwiftGit", "ForgeKit", "TarKit"]
        ),
        .testTarget(
            name: "GitCommandTests",
            dependencies: ["GitCommand", "SwiftGit", "ForgeKit"]
        ),
    ]
)
