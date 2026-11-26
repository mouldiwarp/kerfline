// swift-tools-version: 6.2
// SwarfGRBL: the native macOS GRBL sender, part of the Swarf Suite.
import PackageDescription

let package = Package(
    name: "SwarfGRBL",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SGCore", targets: ["SGCore"]),
        .library(name: "SGMachine", targets: ["SGMachine"]),
        .library(name: "SGLibrary", targets: ["SGLibrary"]),
        .library(name: "SGNet", targets: ["SGNet"]),
        .executable(name: "swarfgrbl-cli", targets: ["swarfgrbl-cli"]),
        .executable(name: "SwarfGRBL", targets: ["SwarfGRBL"]),
    ],
    dependencies: [
        // HTTP and WebSocket server (SwiftNIO).
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        // Updates from GitHub Releases in release builds (a binary framework, embedded by build-app.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure Swift, no I/O: G-code, GRBL protocol, shared state, resume, progress, travel, surfacing.
        .target(name: "SGCore"),
        // The machine: USB serial, the GRBL simulator, and the streaming session (1.0's controller).
        .target(name: "SGMachine", dependencies: ["SGCore"]),
        // The file library: blobs, SQLite, the Finder folder working copy, history, Trash, 1.0 import.
        .target(name: "SGLibrary", dependencies: ["SGCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // The running app without its window: hub HTTP API, Bonjour, the Mac-to-Mac link, library
        // sync, machine ownership and the inbox.
        .target(name: "SGNet", dependencies: [
            "SGCore", "SGMachine", "SGLibrary",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
        ]),
        // The window: SwiftUI views and the model behind them (a library so tests can reach it).
        .target(name: "SGUI", dependencies: [
            "SGCore", "SGMachine", "SGLibrary", "SGNet",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        // The app: run as Hub or Agent, chosen on first launch.
        .executableTarget(name: "SwarfGRBL", dependencies: ["SGUI"]),
        // Headless sender: `swarfgrbl-cli ports`, `swarfgrbl-cli stream [--simulate | --port P] file.nc`.
        .executableTarget(name: "swarfgrbl-cli", dependencies: ["SGMachine"], path: "Sources/swarfgrbl-cli"),
        .testTarget(name: "SGCoreTests", dependencies: ["SGCore"]),
        .testTarget(name: "SGMachineTests", dependencies: ["SGMachine"]),
        .testTarget(name: "SGLibraryTests", dependencies: ["SGLibrary"]),
        .testTarget(name: "SGNetTests", dependencies: ["SGNet", "SGCore", "SGMachine", "SGLibrary"]),
        .testTarget(name: "SGUITests", dependencies: ["SGUI", "SGNet", "SGCore", "SGMachine", "SGLibrary"]),
    ]
)
