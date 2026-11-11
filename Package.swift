// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "airpods",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "airpods", targets: ["airpods"])
    ],
    targets: [
        .executableTarget(
            name: "airpods",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/airpods/Info.plist",
                ])
            ]
        )
    ]
)
