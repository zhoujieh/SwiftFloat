// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftFloat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "SwiftFloat",
            targets: ["SwiftFloat"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftFloat",
            dependencies: [],
            path: "Sources"
        )
    ]
)
