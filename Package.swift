// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "sdbui",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sdbui", targets: ["SDBUI"]),
        .library(name: "ADBCKit", targets: ["ADBCKit"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/moreSwift/swift-cross-ui",
            .upToNextMinor(from: "0.10.0")
        )
    ],
    targets: [
        // Minimal ADBC driver loader (dlopen + AdbcDriverInit) and the
        // vendored ADBC / Arrow C Data Interface headers.
        .target(
            name: "CADBC",
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        // Swift API: driver manifests, connection profiles, Arrow decoding.
        .target(name: "ADBCKit", dependencies: ["CADBC"]),
        .executableTarget(
            name: "SDBUI",
            dependencies: [
                "ADBCKit",
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
    ]
)
