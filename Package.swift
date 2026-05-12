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
            resources: [.copy("Resources")],
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
