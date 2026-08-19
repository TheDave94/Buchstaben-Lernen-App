// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PrimaeNative",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "PrimaeNative", targets: ["PrimaeNative"]),
    ],
    targets: [
        .target(
            name: "PrimaeNative",
            path: "PrimaeNative",
            // `Resources` stays `.copy`: it holds 87 identically-named
            // `strokes.json` files in per-letter directories, and
            // `.process` flattens toward the bundle root. Measured, not
            // assumed — SwiftPM rejects the manifest outright with
            // "multiple resources named 'strokes.json'".
            //
            // The CoreML model lives in its own root so it can carry
            // `.process`, which ships the COMPILED `.mlmodelc`. Under
            // `.copy` the model shipped as a raw `.mlpackage` directory
            // and every cold load called `MLModel.compileModel(at:)` at
            // runtime — behaviour Apple does not document as guaranteed,
            // in the one feature that already failed silently across 194
            // records (`cb7291d`).
            resources: [.copy("Resources"), .process("MLResources")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferSendableFromCaptures"),
            ]
        ),
        .testTarget(
            name: "PrimaeNativeTests",
            dependencies: ["PrimaeNative"],
            path: "PrimaeNativeTests",
            swiftSettings: [
                // XCTest subclasses with @MainActor members hit a Swift 6 limitation:
                // inherited nonisolated initialisers (init(invocation:) etc.) conflict
                // with the inferred @MainActor isolation. Minimal concurrency checking
                // in the test target avoids this without affecting production code.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
