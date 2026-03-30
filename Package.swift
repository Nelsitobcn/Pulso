// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pulso",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Pulso", targets: ["Pulso"])
    ],
    dependencies: [
        // Firebase — añadir en Fase 2
        // .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Pulso",
            path: "Pulso",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
