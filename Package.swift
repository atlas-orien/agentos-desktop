// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentOSDesktop",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AgentOSDesktop", targets: ["AgentOSDesktop"]),
    ],
    targets: [
        .executableTarget(name: "AgentOSDesktop"),
    ]
)
