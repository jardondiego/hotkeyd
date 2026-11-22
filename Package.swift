// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hotkeyd",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hotkeyd", targets: ["hotkeyd"])
    ],
    targets: [
        .target(
            name: "HotkeydCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "hotkeyd",
            dependencies: ["HotkeydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        ),
        // Command Line Tools ship no XCTest or swift-testing module, so the suite is a plain
        // executable. `scripts/test.sh` builds and runs it.
        .executableTarget(
            name: "selftest",
            dependencies: ["HotkeydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Local interactive diagnostics (listen, tap, modtap) kept out of the signed production
        // `hotkeyd` binary so the TCC-trusted executable cannot act as a Confused Deputy.
        .executableTarget(
            name: "hotkeyd-dev",
            dependencies: ["HotkeydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
