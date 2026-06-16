import XCTest

/// `EdgeRumCore` holds the internal `Recording` protocol, the
/// `Recorder` shared instance, and the real `AttributeValue` enum.
/// We promote those to `public` so the public umbrella module
/// (`EdgeRum`) can import and route through them. The reason that
/// doesn't leak to outside consumers is the load-bearing invariant
/// that `EdgeRumCore` is NOT listed as a `.library` product in
/// `Package.swift`. If someone adds it as a product, internal types
/// become available to `import EdgeRumCore` from any consumer — a
/// silent breach of the public API contract.
///
/// This test reads `Package.swift` as text and fails if `EdgeRumCore`
/// (or any other intentionally-internal target) appears as a product.
///
/// Refs: PLAN-iOS.md §F2, ADR-002, CLAUDE.md "Repository structure".
final class PackageProductsTests: XCTestCase {

    /// Targets that MUST NOT be re-exposed as SwiftPM products.
    private static let internalOnlyTargets: Set<String> = [
        "EdgeRumCore",
        "EdgeRumCapture",
        "EdgeRumCrash",
        "EdgeRumOTelBridge"
    ]

    func testInternalTargetsAreNotExposedAsProducts() throws {
        let packageSwift = try locateRepoRoot()
            .appendingPathComponent("Package.swift")
        let source = try String(contentsOf: packageSwift, encoding: .utf8)

        // Slice the substring from the `products:` block to the
        // following `dependencies:` block — we only care about
        // `.library(name: "...")` declarations inside the products
        // array.
        guard
            let productsStart = source.range(of: "products:"),
            let productsEnd = source.range(of: "dependencies:", range: productsStart.upperBound..<source.endIndex)
        else {
            return XCTFail("Could not locate `products:` block in Package.swift")
        }
        let productsBlock = String(source[productsStart.upperBound..<productsEnd.lowerBound])

        for target in Self.internalOnlyTargets {
            let needle = "\"\(target)\""
            XCTAssertFalse(
                productsBlock.contains(needle),
                "\(target) must not be listed as a SwiftPM product — outside consumers would gain `import \(target)` access and bypass the public API surface."
            )
        }
    }

    private func locateRepoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "PackageProductsTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(file)"]
        )
    }
}
