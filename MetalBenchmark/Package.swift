// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalBenchmark",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "MetalBenchmark", targets: ["MetalBenchmark"])
    ],
    targets: [
        .executableTarget(
            name: "MetalBenchmark",
            path: "Sources",
            resources: [
                .process("Shaders.metal")
            ]
        ),
        .testTarget(
            name: "MetalBenchmarkTests",
            dependencies: ["MetalBenchmark"],
            path: "Tests"
        )
    ],
    swiftLanguageModes: [.v5]
)
