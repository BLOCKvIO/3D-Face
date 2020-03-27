// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VatomFace3D",
    platforms: [
        .iOS(.v11)
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "VatomFace3D",
            targets: ["VatomFace3D"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(name: "BLOCKv", url: "https://github.com/BLOCKvIO/ios-sdk", .revision("7011d6e22a5fae7cef7ddb35743670a9114bae19")),
        .package(url: "https://github.com/ninjaprox/NVActivityIndicatorView", from: "4.8.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "VatomFace3D",
            dependencies: ["BLOCKv", "NVActivityIndicatorView"],
            path: "ios"),
    ],
    swiftLanguageVersions: [
        .v5
    ]
)