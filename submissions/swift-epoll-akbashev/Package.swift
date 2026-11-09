// swift-tools-version:6.2
import PackageDescription

// The host is the machine the server runs on (build.sh builds on the box), so its architecture picks the flags; on
// others SHAExtensions is empty.
#if arch(x86_64)
let shaFlags = ["-enable-builtin-module", "-Xcc", "-msha", "-Xcc", "-mssse3", "-Xcc", "-msse4.1"]
#else
let shaFlags: [String] = []
#endif

let package = Package(
    name: "conduit",
    // Linux only (epoll, eventfd, accept4, unshare). No dependencies: Swift's standard library, Synchronization and
    // Glibc.
    targets: [
        // SHA-256 on the x86 SHA extensions, reached through Swift's `Builtin` module (-enable-builtin-module), with
        // the instructions enabled for this module alone; Conduit calls it only on a CPU that has them.
        .target(
            name: "SHAExtensions",
            path: "Sources/SHAExtensions",
            swiftSettings: [.unsafeFlags(shaFlags), .unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // The Linux calls Glibc's module leaves out, declared in Swift with `@_extern(c)`.
        .target(
            name: "Syscalls",
            path: "Sources/Syscalls",
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),
        .executableTarget(
            name: "Conduit",
            dependencies: ["Syscalls", "SHAExtensions"],
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
