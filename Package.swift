// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ImageKit",
  platforms: [
    .iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)
  ],
  products: [
    .library(name: "ImageKit", targets: ["ImageKit"])
  ],
  targets: [
    .target(name: "ImageKit"),
    .testTarget(name: "ImageKitTests", dependencies: ["ImageKit"])
  ]
)
