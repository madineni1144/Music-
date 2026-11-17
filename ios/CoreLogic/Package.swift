// swift-tools-version: 5.9
import PackageDescription

// Compiles the Foundation-only logic files straight from the app target (via symlinks in
// Sources/CoreLogic) so queue, model, address, lyrics and release logic can be tested with
// `swift test` on macOS or Linux, without an Xcode test target or a device.
let package = Package(
    name: "CoreLogic",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "CoreLogic", targets: ["CoreLogic"])],
    targets: [
        .target(name: "CoreLogic"),
        .testTarget(name: "CoreLogicTests", dependencies: ["CoreLogic"]),
    ]
)
