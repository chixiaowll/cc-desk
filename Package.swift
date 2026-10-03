// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CCDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CCDesk", targets: ["CCDesk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        // 1.1.0 的 swift-tools-version 为 5.10，可用 Swift 6.0.3 工具链构建（arm64 / x86_64 均通过）。
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        .target(name: "CCDeskCore"),
        .executableTarget(
            name: "CCDesk",
            dependencies: [
                "CCDeskCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(name: "CCDeskCoreTests", dependencies: ["CCDeskCore"]),
    ],
    swiftLanguageModes: [.v5]
)
