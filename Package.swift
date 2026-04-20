// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let infoPlistPath = packageRoot
    .appendingPathComponent("Sources/MyWispr/Resources/Info.plist")
    .path

let package = Package(
    name: "MyWispr",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MyWispr", targets: ["MyWispr"])
    ],
    targets: [
        .executableTarget(
            name: "MyWispr",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        )
    ]
)
