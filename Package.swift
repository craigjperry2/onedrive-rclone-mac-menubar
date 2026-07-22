// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OneDriveRcloneMenubar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "OneDriveRcloneMenubar", targets: ["OneDriveRcloneMenubar"]),
    ],
    targets: [
        .executableTarget(name: "OneDriveRcloneMenubar"),
        .testTarget(name: "OneDriveRcloneMenubarTests", dependencies: ["OneDriveRcloneMenubar"]),
    ]
)
