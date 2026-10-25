// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Baton",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BatonCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            // 工具条图标：从 Longshot 提取并转成「黑 + alpha」的模板位图，
            // 运行时按 BarPalette 染色，见 BarIcon.swift
            resources: [.copy("Resources/BarIcons")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BatonProbe",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BatonApp",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // OCR 子进程：与主进程同一个 wire 规格，独立打包进 Baton.app/Contents/MacOS
        .executableTarget(
            name: "BatonOCR",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BatonCoreTests",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
