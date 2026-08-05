// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bigroute",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Bigroute", targets: ["Bigroute"]),
        .executable(name: "BigrouteWidget", targets: ["BigrouteWidget"]),
        .library(name: "BigrouteCore", targets: ["BigrouteCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(
            name: "BigrouteCore",
            path: "Sources/BigrouteCore",
            sources: [
                "QuotaService.swift",
                "RouterEndpoint.swift",
                "CustomQuotaProvider.swift",
                "SharedQuotaStore.swift",
                "CredentialStore.swift"
            ]
        ),
        .executableTarget(
            name: "Bigroute",
            dependencies: [
                "BigrouteCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Bigroute"
        ),
        .executableTarget(
            name: "BigrouteWidget",
            dependencies: ["BigrouteCore"],
            path: "Sources/BigrouteWidget"
        ),
        .testTarget(
            name: "BigrouteCoreTests",
            dependencies: ["BigrouteCore"],
            path: "Tests/BigrouteCoreTests"
        )
    ]
)
