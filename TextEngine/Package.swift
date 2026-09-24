// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "V07TextEngine",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "v07-text-engine", targets: ["V07TextEngine"])],
    dependencies: [
        .package(name: "V07", path: ".."),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "V07TextEngine",
            dependencies: [
                .product(name: "V07Core", package: "V07"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
    ]
)
