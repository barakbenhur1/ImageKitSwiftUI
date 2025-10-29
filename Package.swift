// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageKit",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        .macCatalyst(.v15)
    ],
    products: [
        .library(name: "ImageKit", targets: ["ImageKit"])
    ],
    targets: [
        .target(
            name: "ImageKit",
            path: "Sources/ImageKit",
            resources: [],
            swiftSettings: [ .define("IMAGEKIT_SPM") ]
        ),
        .testTarget(
            name: "ImageKitTests",
            dependencies: ["ImageKit"],
            path: "Tests/ImageKitTests"
        )
    ]
)
