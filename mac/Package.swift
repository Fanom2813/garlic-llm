// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Garlic",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "GarlicCore",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .executableTarget(name: "GarlicCheck", dependencies: ["GarlicCore"]),
        .executableTarget(name: "Garlic", dependencies: ["GarlicCore"]),
    ]
)
