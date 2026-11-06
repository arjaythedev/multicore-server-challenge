// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "conduit",
    // Linux only (epoll, eventfd, accept4, unshare), like the Rust it is ported from. No dependencies: Swift's
    // standard library, Synchronization and Glibc, as the Rust uses only `std`.
    targets: [
        // The Linux calls Glibc's module leaves out, declared in Swift with `@_extern(c)`, as the Rust declares them in
        // its `mod sys`.
        .target(
            name: "Syscalls",
            path: "Sources/Syscalls",
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),
        .executableTarget(
            name: "Conduit",
            dependencies: ["Syscalls"],
            path: "Sources/Conduit",
            swiftSettings: [
                // Nonisolated by default: the server is one actor per thread (reactors, lanes, bcrypt workers, the
                // scheduler), each its own isolation domain; nothing belongs to the main actor.
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
                // `@_lifetime` on the ~Escapable views (an HTTP request, the JSON parser) and on the Spans the
                // noncopyable buffers lend out.
                .enableExperimentalFeature("Lifetimes"),
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        ),
    ]
)
