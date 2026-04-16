// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoyehtCore",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SoyehtCore", targets: ["SoyehtCore"]),
    ],
    targets: [
        .target(
            name: "SoyehtCore",
            dependencies: [],
            path: "Sources/SoyehtCore",
            resources: [
                .copy("Resources/Fonts"),
            ]
        ),
    ]
)
