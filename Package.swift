// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyEditor",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ManuscriptCore", targets: ["ManuscriptCore"]),
        .executable(name: "MyEditor", targets: ["MyEditor"]),
        .executable(name: "NovelReaderChecks", targets: ["NovelReaderChecks"]),
    ],
    targets: [
        .target(name: "ManuscriptCore"),
        .executableTarget(name: "MyEditor", dependencies: ["ManuscriptCore"]),
        .executableTarget(
            name: "NovelReaderChecks", dependencies: ["ManuscriptCore"], path: "Tests/CoreChecks"),
    ]
)
