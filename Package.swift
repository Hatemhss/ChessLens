// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChessLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChessLens", targets: ["ChessLens"])
    ],
    targets: [
        .executableTarget(
            name: "ChessLens",
            path: "Sources/ChessLens",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ChessLensTests",
            dependencies: ["ChessLens"],
            path: "Tests/ChessLensTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
