// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "iOSMcuManagerLibrary",
    platforms: [.iOS(.v13), .macOS(.v10_14)],
    products: [
        .library(
            name: "iOSMcuManagerLibrary",
            targets: ["iOSMcuManagerLibrary"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/valpackett/SwiftCBOR.git",
            .exact("0.5.0")
        ),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.0")
        ),
    ],
    targets: [
        .target(
            name: "iOSMcuManagerLibrary",
            dependencies: ["SwiftCBOR", "ZIPFoundation"],
            path: "iOSMcuManagerLibrary/Source",
            exclude: ["Info.plist"]
        ),
    ]
)
