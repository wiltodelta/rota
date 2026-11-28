// swift-tools-version:6.0
import Foundation
import PackageDescription

/// Oldest supported macOS. `create-app.sh` reads this line for the bundle's
/// `LSMinimumSystemVersion`.
let deploymentTarget = "15.0"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustFFILibDir = "\(packageRoot)/target/swift-ffi"

let package = Package(
    name: "Rota",
    platforms: [
        .macOS(deploymentTarget)
    ],
    products: [
        .executable(name: "Rota", targets: ["Rota"])
    ],
    dependencies: [
        // In-place updates from the appcast published with each release;
        // create-app.sh embeds and signs the framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "CRotaFFI",
            path: "Sources/CRotaFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RotaCore",
            dependencies: ["CRotaFFI"],
            path: "Sources/RotaCore",
            linkerSettings: [
                .unsafeFlags(["-L", rustFFILibDir, "-lrota_ffi"]),
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "Rota",
            dependencies: ["RotaCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Rota",
            resources: [.copy("Resources/Fonts")],
            // Swift Build records the deployment target as the SDK version in
            // LC_BUILD_VERSION, and macOS then runs the app in its pre-Tahoe
            // compatibility look. Stamp a macOS 26 SDK version instead.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-platform_version", "-Xlinker", "macos",
                    "-Xlinker", deploymentTarget, "-Xlinker", "26.0"
                ])
            ]
        ),
        .testTarget(
            name: "RotaTests",
            dependencies: ["RotaCore", "Rota"],
            path: "Tests"
        )
    ]
)
