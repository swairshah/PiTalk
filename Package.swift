// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiTalk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PiTalk", targets: ["PiTalk"]),
        .executable(name: "ptts", targets: ["ptts"]),
    ],
    dependencies: [
    ],
    targets: [
        // Shared client library
        .target(
            name: "PiTalkClient",
            path: "Sources/PiTalkClient"
        ),
        // Main menubar app
        .executableTarget(
            name: "PiTalk",
            dependencies: [],
            path: "Sources/PiTalk",
            exclude: ["Info.plist", "PiTalk.entitlements"],
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources")
            ]
        ),
        // CLI tool
        .executableTarget(
            name: "ptts",
            dependencies: ["PiTalkClient"],
            path: "Sources/ptts"
        ),
        .testTarget(
            name: "PiTalkTests",
            dependencies: ["PiTalk"],
            path: "Tests/PiTalkTests"
        )
    ]
)
