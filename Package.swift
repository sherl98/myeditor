// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyEditor",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ManuscriptCore", targets: ["ManuscriptCore"]),
        .executable(name: "MyEditor", targets: ["MyEditor"]),
        .executable(name: "CoreChecks", targets: ["CoreChecks"]),
    ],
    targets: [
        .target(name: "ManuscriptCore"),
        .executableTarget(name: "MyEditor", dependencies: ["ManuscriptCore"]),
        .executableTarget(
            name: "CoreChecks", dependencies: ["ManuscriptCore"], path: "Tests/CoreChecks"),
    ]
)
