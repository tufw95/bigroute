// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RouterQuota",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RouterQuota", targets: ["RouterQuota"]),
        .executable(name: "RouterQuotaWidget", targets: ["RouterQuotaWidget"]),
        .library(name: "RouterQuotaCore", targets: ["RouterQuotaCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(
            name: "RouterQuotaCore",
            path: "Sources/RouterQuotaCore",
            sources: [
                "QuotaService.swift",
                "RouterEndpoint.swift",
                "CustomQuotaProvider.swift",
                "SharedQuotaStore.swift",
                "CredentialStore.swift"
            ]
        ),
        .executableTarget(
            name: "RouterQuota",
            dependencies: [
                "RouterQuotaCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/RouterQuota"
        ),
        .executableTarget(
            name: "RouterQuotaWidget",
            dependencies: ["RouterQuotaCore"],
            path: "Sources/RouterQuotaWidget"
        ),
        .testTarget(
            name: "RouterQuotaCoreTests",
            dependencies: ["RouterQuotaCore"],
            path: "Tests/RouterQuotaCoreTests"
        )
    ]
)
