// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeadowKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeadowKit", targets: ["MeadowKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.7.1"),
    ],
    targets: [
        .target(
            name: "MeadowKit",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .executableTarget(name: "mdprobe", dependencies: ["MeadowKit"]),
        .executableTarget(name: "mdsnap", dependencies: ["MeadowKit"]),
        .executableTarget(name: "mdbench", dependencies: ["MeadowKit"]),
        .testTarget(name: "MeadowKitTests", dependencies: ["MeadowKit"]),
    ]
)
