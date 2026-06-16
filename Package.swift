// swift-tools-version: 6.0
//
// EdgeRum — native iOS Real User Monitoring SDK.
//
// Public surface: `EdgeRum` (umbrella). Internal targets are imported
// with `@_implementationOnly` and are invisible from `import EdgeRum`.
//
// Refs: PLAN-iOS.md §2.3, §4.1, §5.4; docs/decisions.md ADR-001.
//
import PackageDescription

let package = Package(
    name: "EdgeRum",
    platforms: [
        .iOS(.v14),
        // macOS floor exists only so `swift build` / `swift test` run
        // on the macOS CI host. The SDK is iOS-only; consumers ship
        // iOS apps. `.v11` (Big Sur) is the contemporaneous macOS for
        // iOS 14 and gives us `NWPathMonitor`, `os.Logger`, etc.
        .macOS(.v11)
    ],
    products: [
        // Dynamic framework — the default. Forcing `.dynamic` is what
        // makes `xcodebuild archive` emit a real `.framework` bundle
        // (not loose `.o` files), which we then pipe through
        // `xcodebuild -create-xcframework` in Tools/build-xcframework.sh.
        .library(
            name: "EdgeRum",
            type: .dynamic,
            targets: ["EdgeRum"]
        ),
        // Static variant for app-extension hosts.
        .library(
            name: "EdgeRumStatic",
            type: .static,
            targets: ["EdgeRum"]
        )
    ],
    dependencies: [
        // Core OpenTelemetry API + SDK only. We deliberately do NOT depend on
        // the `opentelemetry-swift` umbrella package — PLAN-iOS.md §5.4.
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
            from: "2.4.1"
        )
    ],
    targets: [
        // MARK: - Public umbrella
        .target(
            name: "EdgeRum",
            dependencies: [
                "EdgeRumCore",
                "EdgeRumCapture",
                "EdgeRumCrash",
                "EdgeRumOTelBridge"
            ],
            path: "Sources/EdgeRum",
            resources: [
                // PrivacyInfo.xcprivacy ships inside every framework slice
                // so SwiftPM, CocoaPods, and XCFramework consumers all see
                // the same manifest. Authored declarations land in F20.
                .copy("Resources/PrivacyInfo.xcprivacy")
            ],
            plugins: ["EdgeRumVersionPlugin"]
        ),

        // MARK: - Internal targets
        .target(
            name: "EdgeRumCore",
            path: "Sources/EdgeRumCore"
        ),
        .target(
            name: "EdgeRumCapture",
            dependencies: ["EdgeRumCore"],
            path: "Sources/EdgeRumCapture"
        ),
        .target(
            name: "EdgeRumCrash",
            dependencies: [
                "EdgeRumCore",
                "CrashReporter"
            ],
            path: "Sources/EdgeRumCrash"
        ),
        .target(
            name: "EdgeRumOTelBridge",
            dependencies: [
                "EdgeRumCore",
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core")
            ],
            path: "Sources/EdgeRumOTelBridge"
        ),

        // MARK: - Build plugin: version-file generator
        .plugin(
            name: "EdgeRumVersionPlugin",
            capability: .buildTool()
        ),

        // MARK: - Binary target: PLCrashReporter 1.12.0
        //
        // Vendored under Frameworks/CrashReporter.xcframework. The upstream
        // release zip nests the xcframework one directory deep, so we cannot
        // use `.binaryTarget(url:checksum:)` directly — `Tools/fetch-
        // plcrashreporter.sh` downloads, verifies SHA256 against a pinned
        // value, and extracts. Run it once after cloning (CI runs it before
        // every `swift build`).
        .binaryTarget(
            name: "CrashReporter",
            path: "Frameworks/CrashReporter.xcframework"
        ),

        // MARK: - Test targets
        .testTarget(
            name: "EdgeRumTests",
            dependencies: ["EdgeRum", "EdgeRumCore"],
            path: "Tests/EdgeRumTests"
        ),
        .testTarget(
            name: "EdgeRumCaptureTests",
            dependencies: ["EdgeRumCapture", "EdgeRumCore"],
            path: "Tests/EdgeRumCaptureTests"
        ),
        .testTarget(
            name: "EdgeRumContractTests",
            dependencies: ["EdgeRum", "EdgeRumCore"],
            path: "Tests/EdgeRumContractTests"
        )
    ],
    // Compile in Swift 5 language mode by default so consumers on Xcode 15
    // and Swift 5 host apps are not forced into Swift 6 strict concurrency.
    // CLAUDE.md "Swift conventions" §2.
    swiftLanguageModes: [.v5]
)
