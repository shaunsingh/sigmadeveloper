// swift-tools-version: 6.2
import PackageDescription
import Foundation

let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLib = "\(pkgDir)/../raw/target/release"
let rustLink: [LinkerSetting] = [.unsafeFlags(["-L\(rustLib)", "-lsd14raw"])]

let package = Package(
    name: "SigmaFoveon",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SigmaFoveon", targets: ["SigmaFoveon"]),
        .executable(name: "foveon", targets: ["foveon"]),
    ],
    targets: [
        // C interop shim exposing the `foveon_*` declarations to Swift.
        .target(name: "CFoveonRaw"),

        // Rust decode (CPU) + Core Image finish (GPU) + Core ML denoise
        .target(
            name: "SigmaFoveon",
            dependencies: ["CFoveonRaw"],
            resources: [.copy("Assets")],
            // Use Accelerate's current CBLAS headers.
            swiftSettings: [.unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK=1"])]
        ),

        // CLI
        .executableTarget(
            name: "foveon",
            dependencies: ["SigmaFoveon"],
            linkerSettings: rustLink
        ),
    ]
)
