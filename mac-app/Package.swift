// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "zyncird",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "zyncird",
            resources: [
                .copy("Resources/zyncir.jar")
            ]
        )
    ]
)
