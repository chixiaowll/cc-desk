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
    ],
    targets: [
        .target(name: "CCDeskCore"),
        .executableTarget(
            name: "CCDesk",
            dependencies: ["CCDeskCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "CCDeskCoreTests", dependencies: ["CCDeskCore"]),
    ],
    swiftLanguageModes: [.v5]
)
