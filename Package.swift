// swift-tools-version:6.2
import PackageDescription

// Platforms where ArgumentParser-bearing command targets may enter a
// TEST target's module graph. Excludes Android: its explicit-module
// dependency scanner trips a spurious 'Android' <-> 'ArgumentParser'
// cycle once the large `--build-tests` graph pulls ArgumentParser into a
// test target. The argv-parsing test targets drop their `*Command`
// dependency on Android via this list; their sources carry a matching
// `#if !os(Android)` so nothing references the absent module there.
let commandTestPlatforms: [Platform] = [
    .macOS, .iOS, .tvOS, .watchOS, .linux, .windows,
]

// `swift build` is invoked with TARGET_OS_ANDROID=1 by
// skiptools/swift-android-action when cross-compiling for Android. The
// ArgumentParser command/executable layer (the `*Command` libraries,
// their executables, and the argv-parsing test targets) can't share
// Android's large `--build-tests` module-scanner graph — it trips a
// spurious 'Android' <-> 'ArgumentParser' explicit-module cycle (an
// upstream toolchain bug). The realistic Android consumer is SwiftBash
// embedding the SDK *libraries*, which — after the ArgumentParser
// decouple (ForgeKit + ShellKit) — build and test cleanly. So drop that
// command layer from Android builds; the SDK libraries and their
// ArgumentParser-free test suites stay and run on the emulator.
let buildingForAndroid = Context.environment["TARGET_OS_ANDROID"] == "1"

let androidDroppedTargets: Set<String> = [
    // command (ArgumentParser) libraries
    "ZipCommand", "UnzipCommand", "TarCommand", "GzipCommand",
    "Bzip2Command", "XzCommand", "ZstdCommand", "Lz4Command",
    "JqCommand", "GlamCommand", "GhCommand", "GlabCommand",
    "GitCommand", "RgCommand", "FdCommand", "Sqlite3Command",
    "SwiftPortsCommands",
    // executables
    "zip", "unzip", "tar", "gzip", "gunzip", "zcat", "bzip2", "bunzip2",
    "bzcat", "xz", "unxz", "xzcat", "zstd", "unzstd", "zstdcat", "lz4",
    "unlz4", "lz4cat", "jq", "glam", "gh", "glab", "git", "rg", "fd",
    "sqlite3",
    // argv-parsing test targets (each needs a `*Command` lib)
    // NB: there's no Sqlite3 test target here — the `Sqlite3Shell` driver and
    // its suite live in Cocoanetics/SQLiteKit now, which exercises them on
    // every platform itself.
    "ZipTests", "UnzipTests", "TarTests", "GzipTests", "Bzip2Tests",
    "XzTests", "ZstdTests", "Lz4Tests", "JqTests", "GlamTests",
    "GitCommandTests", "RgTests", "FdTests",
    // GitHubTests is the only Android-scope test target that links a C++
    // SwiftPM target (swift-crypto's BoringSSL, via GitHub). Linking C++
    // into the xctest executable makes swiftc go through clang's C++ link
    // driver, which injects host C++ defaults (-lstdc++ + a host
    // /usr/lib/x86_64-linux-gnu search path) and breaks Bionic libc
    // resolution for the whole bundle. Dropping it keeps the test bundle
    // C++-free so the other SDK suites link + run on the emulator.
    // (GitHubTests still runs on the four full-build platforms.)
    "GitHubTests",
]

func androidFiltered(products list: [Product]) -> [Product] {
    buildingForAndroid
        ? list.filter { !androidDroppedTargets.contains($0.name) }
        : list
}
func androidFiltered(targets list: [Target]) -> [Target] {
    buildingForAndroid
        ? list.filter { !androidDroppedTargets.contains($0.name) }
        : list
}

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
    // Platforms aligned with our largest direct Apple dependency,
    // swift-archive (`.macOS(.v13), .iOS(.v15), .tvOS(.v15), .watchOS(.v10)`),
    // and with downstream SwiftBash. Sites that legitimately need
    // newer-OS API (`Synchronization.Mutex`,
    // `swift-configuration`'s `ConfigReader`) gate locally with
    // `@available` instead of forcing the package floor up.
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: androidFiltered(products: [
        // ForgeKit — host-agnostic CLI plumbing (IO, Git, Secrets).
        // The previous `Sandbox` product moved upstream to
        // [ShellKit](https://github.com/Cocoanetics/ShellKit) — every
        // library that virtualises URLs / env / argv now depends on
        // ShellKit and reads through `Shell.current`.
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

        // SQLiteKit umbrella — the `sqlite3` shell port. The SDK (vendored
        // amalgamation + Swift glue) lives in Cocoanetics/SQLiteKit; this repo
        // owns the shell port and both CLI faces on top of it. The `sqlite3`
        // executable is the valuable artifact on macOS / Linux (Apple-mobile
        // builds it as a never-invoked stub, like the rest of our CLIs).
        //
        //   • Sqlite3Shell  — the argv parser / dot-command / REPL driver
        //                     (`Sqlite3Executable`) plus its ShellKit-`Command`
        //                     face (`Sqlite3Builtin`). ArgumentParser-free, so
        //                     it builds on every platform (Android included); a
        //                     host shell installs the builtin as a virtual bin.
        //   • Sqlite3Command — the thin `Sqlite3: AsyncParsableCommand` wrapper
        //                     (the macOS-CLI face; the only
        //                     ArgumentParser-bearing layer, dropped on Android
        //                     with the rest of the command set).
        .library(name: "Sqlite3Shell", targets: ["Sqlite3Shell"]),
        .library(name: "Sqlite3Command", targets: ["Sqlite3Command"]),
        .executable(name: "sqlite3", targets: ["sqlite3"]),

        // SwiftPortsCommands — every ArgumentParser-backed port vended as a
        // ready-to-install ShellKit `Command` (bridged via ShellKit's
        // `ShellCommandKit`). A host shell (e.g. SwiftBash) installs these as
        // virtual bins without bridging anything itself. ArgumentParser-bearing
        // ⇒ dropped on Android; the ArgumentParser-free `sqlite3` builtin
        // (`Sqlite3Shell` product) is the exception that survives there.
        .library(name: "SwiftPortsCommands", targets: ["SwiftPortsCommands"]),

        // GlamKit umbrella — Glamour-compatible Markdown→ANSI renderer.
        // Pure-Swift port of charmbracelet/glamour built on apple/swift-
        // markdown. Honors `GLAMOUR_STYLE`, terminal capability (TERM /
        // COLORTERM / NO_COLOR), and emits OSC 8 hyperlinks when the
        // terminal supports them. Used by GitHub / GitLab umbrellas to
        // render PR/issue/release bodies and comments.
        .library(name: "GlamKit", targets: ["GlamKit"]),
        .library(name: "GlamCommand", targets: ["GlamCommand"]),
        .executable(name: "glam", targets: ["glam"]),

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

        // RipgrepKit umbrella — pure-Swift port of BurntSushi/ripgrep.
        // Engine respects `.gitignore` / `.ignore` / `.rgignore`, has a
        // `--type` registry mirroring upstream's defaults, supports
        // multi-line / fixed-string / smart-case modes, and emits JSON
        // Lines output compatible with `rg --json` consumers (Pi's grep
        // tool, ripgrep editor plugins, etc.).
        .library(name: "RipgrepKit", targets: ["RipgrepKit"]),
        .library(name: "RgCommand", targets: ["RgCommand"]),
        .executable(name: "rg", targets: ["rg"]),

        // FdKit umbrella — pure-Swift port of sharkdp/fd. Reuses
        // RipgrepKit's gitignore-aware Walker for traversal; layers
        // an fd-flavored pattern matcher (regex / glob / fixed
        // strings, basename- or full-path-matched), type / size /
        // time filters, and a printer over it. Respects `.gitignore`,
        // `.ignore`, `.fdignore`, the user's global git ignore, and
        // parent-directory ignore files just like upstream fd.
        .library(name: "FdKit", targets: ["FdKit"]),
        .library(name: "FdCommand", targets: ["FdCommand"]),
        .executable(name: "fd", targets: ["fd"]),
    ]),
    // Package traits — opt-in, build-time toggles. Off by default (none are
    // listed in any `.default(enabledTraits:)`).
    //
    // FTS5 and SQLiteVec forward to the external Cocoanetics/SQLiteKit
    // package's same-named traits, which compile the engine with
    // -DSQLITE_ENABLE_FTS5 and link in the vendored sqlite-vec amalgamation
    // (`vec0` vector / semantic search) respectively.
    //   • depending on this package:   .package(url: …, traits: ["FTS5", "SQLiteVec"])
    //   • building this package direct: swift build --traits FTS5,SQLiteVec
    traits: [
        .trait(name: "FTS5",
               description: "Compile SQLite with FTS5 full-text search."),
        .trait(name: "SQLiteVec",
               description: "Compile in sqlite-vec for on-device vector / semantic search."),
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
        // cpio, xar, ISO9660, …) with gzip/bzip2/xz/zstd filters — backs
        // the tar/zip CLI ports. Pinned to the latest commit of upstream's
        // default (`swift`) branch — it carries the platform-narrowed
        // gating from marcprux/swift-archive#2, which no tagged release
        // contains yet. GitKit's `Archive` trait pins the SAME revision
        // (the dependency graph must agree on one version of the package);
        // move both to a `from:` pin when upstream tags the gating.
        .package(url: "https://github.com/marcprux/swift-archive",
                 revision: "60f478d10ae730c4faed643d3fcc746c07a7e7e5",
                 traits: [.defaults,
                          "GzipSupport",
                          "Bzip2Support",
                          "LZMASupport",
                          "ZstdSupport"]),

        // Cocoanetics/GitKit: the libgit2 C library (pristine submodule,
        // curated Windows-safe `CGitKit` module) plus the typed Swift SDK
        // (`Repository` + operations) SwiftGit's GitClient composes. GitKit
        // versions independently of libgit2 (2.x vendors libgit2 v1.9.4).
        // The `Archive` trait turns on `Repository.archive` (libarchive via
        // the revision-pinned swift-archive above), backing our `git
        // archive` subcommand. Referenced by BRANCH, not version: enabling
        // the trait activates GitKit's revision-pinned dep, and SwiftPM only
        // permits that from a branch/revision reference (a stable-version
        // package may not activate an unstable-version dependency — the
        // `from: "2.0.0"` form works only with the trait off).
        .package(url: "https://github.com/Cocoanetics/GitKit",
                 branch: "main",
                 traits: [.defaults, "Archive"]),

        // ShellKit owns the virtualised shell-environment surface
        // (IO sinks, Environment, Sandbox URL gate, NetworkConfig,
        // ProcessTable, HostInfo, BinCatalog, the Command protocol,
        // ParsableCommand bridge). SwiftPorts CLIs read/write through
        // `Shell.current` so they participate in any host's pipeline
        // (SwiftBash, swift-js, SwiftScript, …) without a fork.
        // Pinned to `main` until ShellKit ships a tagged release.
        // ShellKit `main` carries zero ArgumentParser dependency — the
        // ParsableCommand bridge lives in the separate `ShellCommandKit`
        // product — which keeps ArgumentParser off every SDK library's
        // module graph (see Docs/Android.md). Pinned to `main` until
        // ShellKit ships a tagged release.
        .package(url: "https://github.com/Cocoanetics/ShellKit",
                 branch: "main"),

        // swift-markdown supplies the CommonMark + GFM AST used by
        // GlamKit. We picked it directly rather than going through
        // Cocoanetics/SwiftText — SwiftText only re-exports it with
        // an HTML renderer (different output format than ours), and
        // we'd inherit its libxml2 / OCR / PDF trait surface for no
        // ANSI-side benefit.
        .package(url: "https://github.com/swiftlang/swift-markdown",
                 from: "0.7.0"),

        // SQLiteKit — the SQLite SDK (vendored amalgamation + sqlite-vec +
        // FTS5), extracted from this repo into its own package so it can be
        // versioned independently and consumed with a minimal closure. Backs
        // the `sqlite3` shell port. Pinned to `main` until SQLiteKit ships a
        // tagged release. Our `FTS5` / `SQLiteVec` traits forward to
        // SQLiteKit's same-named traits; off unless the consumer opts in (see
        // the `traits:` block above).
        .package(url: "https://github.com/Cocoanetics/SQLiteKit",
                 branch: "main",
                 traits: [
                     .trait(name: "FTS5", condition: .when(traits: ["FTS5"])),
                     .trait(name: "SQLiteVec", condition: .when(traits: ["SQLiteVec"])),
                 ]),
    ],
    targets: androidFiltered(targets: [
        // MARK: ForgeKit (host-agnostic plumbing)
        // No ArgumentParser dependency: ForgeKit is imported by every SDK
        // library, so pulling ArgumentParser here would drag it (and its
        // libc-overlay module edges) onto every SDK module graph — which
        // tripped a spurious explicit-module scanner cycle on Android.
        // ForgeKit ships `ColorChoice` as a plain value type; command
        // targets that bind it as an `@Option` declare the
        // `ExpressibleByArgument` conformance themselves (see GitCommand).
        .target(
            name: "ForgeKit",
            dependencies: [
                .product(name: "ShellKit", package: "ShellKit"),
            ],
            path: "Sources/ForgeKit"
        ),
        .testTarget(
            name: "ForgeKitTests",
            dependencies: ["ForgeKit"]
        ),

        // MARK: ZipKit umbrella
        .target(
            name: "ZipKit",
            dependencies: [
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "Archive", package: "swift-archive"),
            ],
            path: "Sources/ZipKit/Lib"
        ),
        .target(
            name: "ZipCommand",
            dependencies: [
                "ZipKit",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ZipKit/ZipCommand"
        ),
        .target(
            name: "UnzipCommand",
            dependencies: [
                "ZipKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
            dependencies: [
                .target(name: "ZipCommand", condition: .when(platforms: commandTestPlatforms)),
                "ZipKit",
            ]
        ),
        .testTarget(
            name: "UnzipTests",
            dependencies: [
                .target(name: "UnzipCommand", condition: .when(platforms: commandTestPlatforms)),
                "ZipKit",
            ]
        ),

        // MARK: TarKit umbrella
        .target(
            name: "TarKit",
            dependencies: [
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "Archive", package: "swift-archive"),
            ],
            path: "Sources/TarKit/Lib"
        ),
        .target(
            name: "TarCommand",
            dependencies: [
                "TarKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
            dependencies: [
                .target(name: "TarCommand", condition: .when(platforms: commandTestPlatforms)),
                "TarKit",
            ]
        ),

        // MARK: GzipKit umbrella
        // Uses zlib directly (via the local CZlib systemLibrary) rather
        // than libarchive — libarchive's read side excludes `raw` format
        // by default, so a pure single-file gzip stream written with
        // libarchive's raw+gzip filter can't be parsed back by the same
        // wrapper. zlib's own inflate/deflate handle gzip framing
        // natively (`MAX_WBITS + 16` for write, `+ 32` for read auto-
        // detection) and zlib is already on every platform we target.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            // No `pkgConfig:`. On an Android cross-build SwiftPM runs HOST
            // pkg-config, which injects `-L/usr/lib/x86_64-linux-gnu -lz`
            // into the link; the host libz then pulls host glibc (no
            // Bionic __libc_init/__errno/__assert2) and breaks the xctest
            // link. The modulemap's `link "z"` already adds `-lz`, resolved
            // against the active sysroot; zlib.h is a default system header
            // (and the Windows CI passes the vcpkg include path), so zlib
            // is still found on every platform without pkg-config.
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
            dependencies: ["CZlib", .product(name: "ShellKit", package: "ShellKit")],
            path: "Sources/GzipKit/Lib"
        ),
        .target(
            name: "GzipCommand",
            dependencies: [
                "GzipKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
            dependencies: [
                .target(name: "GzipCommand", condition: .when(platforms: commandTestPlatforms)),
                "GzipKit",
            ]
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
                .product(name: "ShellKit", package: "ShellKit"),
                .target(name: "CBzip2",
                        condition: .when(platforms: [.macOS, .linux, .windows])),
            ],
            path: "Sources/Bzip2Kit/Lib"
        ),
        .target(
            name: "Bzip2Command",
            dependencies: [
                "Bzip2Kit",
                .product(name: "ShellKit", package: "ShellKit"),
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
                .product(name: "ShellKit", package: "ShellKit"),
                .target(name: "CLZMA",
                        condition: .when(platforms: [.linux, .windows])),
            ],
            path: "Sources/XzKit/Lib"
        ),
        .target(
            name: "XzCommand",
            dependencies: [
                "XzKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
                .product(name: "ShellKit", package: "ShellKit"),
                .target(name: "CZstd",
                        condition: .when(platforms: [.macOS, .linux, .windows])),
            ],
            path: "Sources/ZstdKit/Lib"
        ),
        .target(
            name: "ZstdCommand",
            dependencies: [
                "ZstdKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
                .product(name: "ShellKit", package: "ShellKit"),
                .target(name: "CLz4",
                        condition: .when(platforms: [.linux, .windows])),
            ],
            path: "Sources/Lz4Kit/Lib"
        ),
        .target(
            name: "Lz4Command",
            dependencies: [
                "Lz4Kit",
                .product(name: "ShellKit", package: "ShellKit"),
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
            dependencies: [
                .product(name: "ShellKit", package: "ShellKit"),
            ],
            path: "Sources/JqKit/Lib"
        ),
        .target(
            name: "JqCommand",
            dependencies: [
                "JqKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
            dependencies: [
                .target(name: "JqCommand", condition: .when(platforms: commandTestPlatforms)),
                "JqKit",
            ]
        ),

        // MARK: GlamKit umbrella
        // Markdown → ANSI renderer matching glamour's stylesheet model.
        // The library accepts a `GLAMOUR_STYLE`-shaped style JSON (same
        // schema as upstream), reads terminal capability through
        // `ForgeKit.TTY` / `Glam.Terminal`, and emits an indented,
        // word-wrapped, hyperlink-aware ANSI stream. Used by gh/glab
        // for PR / issue / release body rendering and from the `glam`
        // CLI for piped input.
        .target(
            name: "GlamKit",
            dependencies: [
                "ForgeKit",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/GlamKit/Lib",
            resources: [
                // `.process` (not `.copy`) so the JSON files land at
                // the bundle root rather than inside a `Resources/`
                // subdirectory — that name is reserved in iOS
                // framework bundles and trips the codesign step at
                // CI time (`bundle format unrecognized`). Resource
                // lookups via `Bundle.module.url(forResource:
                // withExtension:)` still find them.
                .process("Style/Resources"),
            ]
        ),
        .target(
            name: "GlamCommand",
            dependencies: [
                "GlamKit",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GlamKit/GlamCommand"
        ),
        .executableTarget(
            name: "glam",
            dependencies: ["GlamCommand"],
            path: "Sources/GlamKit/glam"
        ),
        .testTarget(
            name: "GlamKitTests",
            dependencies: ["GlamKit"]
        ),
        .testTarget(
            name: "GlamTests",
            dependencies: [
                .target(name: "GlamCommand", condition: .when(platforms: commandTestPlatforms)),
                "GlamKit",
            ]
        ),

        // MARK: GitHub umbrella
        .target(
            name: "GitHub",
            dependencies: [
                "ForgeKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
                "GlamKit",
                "GitHub",
                "ForgeKit",
                "JqKit",
                "Lz4Kit",
                .product(name: "ShellKit", package: "ShellKit"),
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
                "GitHub", "ForgeKit", .product(name: "ShellKit", package: "ShellKit"),
                "JqKit", "Lz4Kit", "TarKit", "XzKit", "ZipKit",
            ] + (buildingForAndroid ? [] : ["GhCommand"]),
            resources: [
                .copy("Fixtures"),
            ]
        ),

        // MARK: GitLab umbrella
        .target(
            name: "GitLab",
            dependencies: [
                "ForgeKit",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            ],
            path: "Sources/GitLab/Lib"
        ),
        .target(
            name: "GlabCommand",
            dependencies: [
                "GlamKit",
                "GitLab",
                "ForgeKit",
                "JqKit",
                .product(name: "ShellKit", package: "ShellKit"),
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
            dependencies: ["GitLab", "ForgeKit"]
                + (buildingForAndroid ? [] : ["GlabCommand"])
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
                .product(name: "CGitKit", package: "GitKit"),
            ],
            path: "Sources/CLibgit2Shim",
            publicHeadersPath: "include"
        ),

        // MARK: SwiftGit umbrella (libgit2-backed GitClient + `git` CLI)
        // The pure libgit2 Swift SDK (the `Repository` handle + operations)
        // lives upstream in Cocoanetics/GitKit (its `GitKit` product) —
        // extracted from here via the staged refactor in GitKit#3. This repo
        // keeps `SwiftGit`, the sandbox-aware `GitClient` face: each
        // operation authorizes paths via `Shell.authorize`, bridges sandbox
        // env to libgit2's process-global options (`Libgit2Sandboxing`),
        // opens a `Repository`, and delegates.
        .target(
            name: "SwiftGit",
            dependencies: [
                "CLibgit2Shim",
                "ForgeKit",
                .product(name: "ShellKit", package: "ShellKit"),
                // `git archive` rides GitKit's trait-gated
                // `Repository.archive` (see the GitKit package entry's
                // `Archive` trait) — no direct libarchive dependency here.
                .product(name: "GitKit", package: "GitKit"),
                .product(name: "CGitKit", package: "GitKit"),
            ],
            path: "Sources/SwiftGit/Lib"
        ),
        .target(
            name: "GitCommand",
            dependencies: [
                "SwiftGit",
                "ForgeKit",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "CGitKit", package: "GitKit"),
            ],
            path: "Sources/SwiftGit/GitCommand"
        ),
        .executableTarget(
            name: "git",
            dependencies: ["GitCommand", .product(name: "ShellKit", package: "ShellKit")],
            path: "Sources/SwiftGit/git"
        ),
        .testTarget(
            name: "SwiftGitTests",
            dependencies: ["SwiftGit", "ForgeKit", "TarKit"]
        ),
        .testTarget(
            name: "GitCommandTests",
            dependencies: [
                .target(name: "GitCommand", condition: .when(platforms: commandTestPlatforms)),
                "SwiftGit", "ForgeKit",
            ]
        ),

        // MARK: RipgrepKit umbrella
        // Pure-Swift recursive code search. The library has no system
        // dependency (regex compiles through Foundation's
        // `NSRegularExpression`, file traversal goes through
        // FileManager + raw POSIX `readdir`-free APIs). The CLI lives
        // in `RgCommand` so SwiftBash and other embedders can register
        // `rg` as a builtin without pulling in the executable target.
        .target(
            name: "RipgrepKit",
            dependencies: [
                "ForgeKit",
                .product(name: "ShellKit", package: "ShellKit"),
            ],
            path: "Sources/RipgrepKit/Lib"
        ),
        .target(
            name: "RgCommand",
            dependencies: [
                "RipgrepKit",
                "ForgeKit",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/RipgrepKit/RgCommand"
        ),
        .executableTarget(
            name: "rg",
            dependencies: ["RgCommand"],
            path: "Sources/RipgrepKit/rg"
        ),
        .testTarget(
            name: "RipgrepKitTests",
            dependencies: ["RipgrepKit"]
        ),
        .testTarget(
            name: "RgTests",
            dependencies: [
                .target(name: "RgCommand", condition: .when(platforms: commandTestPlatforms)),
                "RipgrepKit",
            ]
        ),

        // MARK: FdKit umbrella
        // Pure-Swift recursive file finder. Depends on RipgrepKit so
        // the Walker / IgnoreSet / GitignoreGlob machinery is shared,
        // keeping ignore-rule semantics identical across the two
        // tools.
        .target(
            name: "FdKit",
            dependencies: [
                "ForgeKit",
                "RipgrepKit",
                .product(name: "ShellKit", package: "ShellKit"),
            ],
            path: "Sources/FdKit/Lib"
        ),
        .target(
            name: "FdCommand",
            dependencies: [
                "FdKit",
                "ForgeKit",
                "RipgrepKit",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/FdKit/FdCommand"
        ),
        .executableTarget(
            name: "fd",
            dependencies: ["FdCommand"],
            path: "Sources/FdKit/fd"
        ),
        .testTarget(
            name: "FdKitTests",
            dependencies: ["FdKit", "RipgrepKit"]
        ),
        .testTarget(
            name: "FdTests",
            dependencies: [
                .target(name: "FdCommand", condition: .when(platforms: commandTestPlatforms)),
                "FdKit", "RipgrepKit",
            ]
        ),

        // MARK: SQLiteKit umbrella (issue #43)
        // The `sqlite3` shell port over the external Cocoanetics/SQLiteKit SDK.
        // The SDK — the vendored amalgamation + the CSQLiteShim / CSQLiteVec C
        // targets + Swift glue — lives in that package; this repo owns the
        // shell port and both faces. The Linux / Android engine link libs
        // (m / dl / pthread) come from SQLiteKit's own linker settings,
        // propagated through the dependency.
        //
        // `Sqlite3Shell` — the argv parser / dot-command / REPL driver
        // (`Sqlite3Executable`, ArgumentParser-free, IO-routed through
        // `ShellKit.Shell.current`) plus its ShellKit-`Command` face
        // (`Sqlite3Builtin`). Builds on every platform — Android included — so
        // a host shell can install a working `sqlite3` everywhere. SwiftBash
        // drives `sqlite3` in-process from this target's product.
        .target(
            name: "Sqlite3Shell",
            dependencies: [
                .product(name: "SQLiteKit", package: "SQLiteKit"),
                .product(name: "ShellKit", package: "ShellKit"),
            ],
            path: "Sources/SQLiteKit/Sqlite3Shell"
        ),
        // The ArgumentParser wrapper — the `Sqlite3` command type over the
        // local `Sqlite3Shell` driver. The macOS-CLI face; dropped on Android
        // with the rest of the command layer (see `androidDroppedTargets`).
        .target(
            name: "Sqlite3Command",
            dependencies: [
                "Sqlite3Shell",
                .product(name: "ShellKit", package: "ShellKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SQLiteKit/Sqlite3Command"
        ),
        .executableTarget(
            name: "sqlite3",
            dependencies: ["Sqlite3Command"],
            path: "Sources/SQLiteKit/sqlite3"
        ),
        // Drives `Sqlite3Executable` directly (no ArgumentParser), so it runs
        // on every platform — Android included — exercising the shell port on
        // the emulator in CI.
        .testTarget(
            name: "Sqlite3Tests",
            dependencies: [
                "Sqlite3Shell",
                .product(name: "SQLiteKit", package: "SQLiteKit"),
            ]
        ),

        // MARK: SwiftPortsCommands — the shellkit face of the CLI ports
        // Vends every ArgumentParser-backed port as a ready-to-install ShellKit
        // `Command`, bridged through ShellKit's own `ShellCommandKit`
        // (`Shell.parsableCommand(_:)`) — no per-host bridge. A host shell
        // (e.g. SwiftBash) installs these as virtual bins. ArgumentParser-
        // bearing ⇒ dropped on Android (see `androidDroppedTargets`); the
        // ArgumentParser-free `sqlite3` face is in `Sqlite3Shell` and survives.
        .target(
            name: "SwiftPortsCommands",
            dependencies: [
                .product(name: "ShellCommandKit", package: "ShellKit"),
                "JqCommand", "RgCommand", "FdCommand",
                "GhCommand", "GlabCommand", "GitCommand",
                "TarCommand", "ZipCommand", "UnzipCommand",
                "GzipCommand", "Bzip2Command", "XzCommand",
                "ZstdCommand", "Lz4Command",
            ],
            path: "Sources/SwiftPortsCommands"
        ),
    ])
)
