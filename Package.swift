// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftFloat",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "SwiftFloat", targets: ["SwiftFloat"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftFloat",
            dependencies: [],
            path: "Sources"
        )
    ]
)
