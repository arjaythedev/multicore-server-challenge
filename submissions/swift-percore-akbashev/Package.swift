// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "conduit",
    // Span, InlineArray and TaskExecutor need the Swift 6.2 runtime on Darwin (macOS 26). Linux has no such floor.
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
    ],
    targets: [
        // epoll and eventfd for the event loops, which Swift's Glibc module leaves out.
        .target(name: "CEventLoop", path: "Sources/CEventLoop"),
        .executableTarget(
            name: "Conduit",
            dependencies: [
                "CEventLoop",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/Conduit",
            swiftSettings: [
                // Swift 7 defaults, on now: a nonisolated async function runs on its caller's executor instead of
                // hopping to the global one (@concurrent opts back in); isolated conformances are inferred.
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
