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

// Keep unrelated native targets out of the host build graph (including tests).
#if os(Linux)
let nativeTargets: [Target] = [
    .systemLibrary(name: "CSDBUIGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
    .target(name: "CResultValue", dependencies: ["CSDBUIGtk"]),
]
let nativeDependencies: [Target.Dependency] = [
    "CResultValue", .product(name: "GtkBackend", package: "swift-cross-ui"),
]
#elseif os(macOS)
let nativeTargets: [Target] = []
let nativeDependencies: [Target.Dependency] = [
    .product(name: "AppKitBackend", package: "swift-cross-ui"),
]
#else
let nativeTargets: [Target] = []
let nativeDependencies: [Target.Dependency] = [
    .product(name: "DefaultBackend", package: "swift-cross-ui"),
]
#endif

let package = Package(
    name: "sdbui",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sdbui", targets: ["SDBUI"]),
        .library(name: "ADBCKit", targets: ["ADBCKit"]),
    ],
    dependencies: [swiftCrossUI],
    targets: nativeTargets + [
        // Minimal ADBC driver loader (dlopen + AdbcDriverInit) and the
        // vendored ADBC / Arrow C Data Interface headers.
        .target(
            name: "CADBC",
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        // Swift API: driver manifests, connection profiles, Arrow decoding.
        .target(name: "ADBCKit", dependencies: ["CADBC"], resources: [.copy("Resources/transfer.py")]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .executableTarget(
            name: "SDBUI",
            dependencies: [
                "ADBCKit",
                "CSQLite",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            ] + nativeDependencies
        ),
        .testTarget(name: "ADBCKitTests", dependencies: ["ADBCKit"]),
        .testTarget(name: "SDBUITests", dependencies: ["SDBUI", "CSQLite"]),
    ]
)
