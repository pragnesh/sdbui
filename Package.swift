// swift-tools-version:5.10

import Foundation
import PackageDescription

// Use the GitHub fork by default; SDBUI_SCUI_PATH is an explicit local override.
let swiftCrossUI: Package.Dependency =
    if let path = ProcessInfo.processInfo.environment["SDBUI_SCUI_PATH"] {
        .package(path: path)
    } else {
        // Fork of moreSwift/swift-cross-ui 0.10.0 with GtkBackend fixes and
        // performance patches, plus the virtualized DataGrid view.
        .package(
            url: "https://github.com/pragnesh/swift-cross-ui",
            branch: "sdbui-data-grid"
        )
    }

let package = Package(
    name: "sdbui",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sdbui", targets: ["SDBUI"]),
        .library(name: "ADBCKit", targets: ["ADBCKit"]),
    ],
    dependencies: [swiftCrossUI],
    targets: [
        // Minimal ADBC driver loader (dlopen + AdbcDriverInit) and the
        // vendored ADBC / Arrow C Data Interface headers.
        .target(
            name: "CADBC",
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        // Swift API: driver manifests, connection profiles, Arrow decoding.
        .target(name: "ADBCKit", dependencies: ["CADBC"]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .executableTarget(
            name: "SDBUI",
            dependencies: [
                "ADBCKit",
                "CSQLite",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                // DefaultBackend also drags in the Windows-only WinUIInterop
                // target, which Swift 6.4's build system compiles on Linux too.
                .product(
                    name: "GtkBackend", package: "swift-cross-ui",
                    condition: .when(platforms: [.linux])),
                .product(
                    name: "DefaultBackend", package: "swift-cross-ui",
                    condition: .when(platforms: [.macOS, .windows])),
            ]
        ),
        .testTarget(name: "ADBCKitTests", dependencies: ["ADBCKit"]),
        .testTarget(name: "SDBUITests", dependencies: ["SDBUI", "CSQLite"]),
    ]
)
