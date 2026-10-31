// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "conduit",
    // Span, InlineArray and TaskExecutor need the Swift 6.2 runtime on Darwin (macOS 26). Linux has no such floor.
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.13.0"),
    ],
    targets: [
        .executableTarget(
            name: "Conduit",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Conduit",
            swiftSettings: [
                // Swift 7 defaults, on now: a nonisolated async function runs on its caller's executor instead of
                // hopping to the global one (@concurrent opts back in, see App.swift); isolated conformances are inferred.
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                // Every existential is spelled `any`, so each boxed value on a hot path is visible.
                .enableUpcomingFeature("ExistentialAny"),
                // A file sees only the members of modules it imports itself.
                .enableUpcomingFeature("MemberImportVisibility"),
                // No -cross-module-optimization: it controls what a module exports for inlining, so on an executable
                // it does nothing, and on every module (see build.sh) Swift 6.4 fails to link (swiftlang/swift#91771).
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        ),
    ]
)
