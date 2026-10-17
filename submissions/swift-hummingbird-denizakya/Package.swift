// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "conduit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "Conduit",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                "CVaporBcrypt",
            ],
            path: "Sources/Conduit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-cross-module-optimization"],
                             .when(configuration: .release)),
            ]
        ),
        .target(
            name: "CVaporBcrypt",
            path: "Sources/CVaporBcrypt",
            cSettings: [.headerSearchPath("include")]
        ),
    ]
)
