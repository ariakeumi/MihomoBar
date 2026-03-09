// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClashBar",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "MihomoBar", targets: ["ClashBar"]),
    ],
    targets: [
        .executableTarget(
            name: "ClashBar",
            path: "Sources/ClashBar",
            resources: [
                .copy("Resources/Brand/clashbar-icon.png"),
                .copy("Resources/Brand/mihomobar.icns"),
                .process("Resources/Localization"),
            ]),
    ])
