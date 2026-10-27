// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLibraryDirectory = ProcessInfo.processInfo.environment["KEYTRAIL_RUST_LIBRARY_DIR"] ?? root + "/rust/target/release"

let package = Package(
    name: "KeyTrail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeyTrailDashboard", targets: ["KeyTrailApp"]),
        .executable(name: "KeyTrailAgent", targets: ["KeyTrailAgent"]),
        .executable(name: "KeyTrailPet", targets: ["KeyTrailPet"]),
        .executable(name: "KeyTrailFloat", targets: ["KeyTrailFloat"]),
        .library(name: "KeyTrailCore", targets: ["KeyTrailCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CKeyTrailRust"),
        .target(name: "KeyTrailCore", dependencies: ["CSQLite"]),
        .target(name: "KeyTrailIPC"),
        .target(name: "KeyTrailRuntime", dependencies: ["CKeyTrailRust", "KeyTrailCore", "KeyTrailIPC", "CSQLite"], linkerSettings: [.unsafeFlags(["-L", rustLibraryDirectory]), .linkedLibrary("sqlite3")]),
        .target(name: "KeyTrailFloatingUI", dependencies: ["KeyTrailIPC"]),
        .executableTarget(name: "KeyTrailAgent", dependencies: ["KeyTrailRuntime", "KeyTrailIPC", "KeyTrailFloatingUI"]),
        .executableTarget(name: "KeyTrailFloat", dependencies: ["KeyTrailIPC", "KeyTrailFloatingUI"]),
        .executableTarget(name: "KeyTrailFloatingChecks", dependencies: ["KeyTrailIPC", "KeyTrailFloatingUI"], path: "Tests/FloatingChecks"),
        .executableTarget(name: "KeyTrailPet", dependencies: ["KeyTrailIPC"]),
        .executableTarget(name: "KeyTrailPetChecks", dependencies: ["KeyTrailRuntime", "KeyTrailIPC"], path: "Tests/PetChecks"),
        .executableTarget(name: "KeyTrailRuntimeChecks", dependencies: ["KeyTrailRuntime", "KeyTrailIPC", "KeyTrailCore"], path: "Tests/RuntimeChecks"),
        .executableTarget(name: "KeyTrailRhythmChecks", dependencies: ["KeyTrailCore"], path: "Tests/RhythmChecks"),
        .executableTarget(name: "KeyTrailAnalysisChecks", dependencies: ["KeyTrailCore"], path: "Tests/AnalysisChecks"),
        .executableTarget(name: "KeyTrailFunChecks", dependencies: ["KeyTrailCore"], path: "Tests/FunChecks"),
        .executableTarget(name: "KeyTrailTextChecks", dependencies: ["KeyTrailRuntime", "CSQLite"], path: "Tests/TextChecks", exclude: ["README.md"]),
        .executableTarget(name: "KeyTrailSyncChecks", dependencies: ["KeyTrailRuntime", "KeyTrailIPC", "KeyTrailCore"], path: "Tests/SyncChecks"),
        .executableTarget(name: "KeyTrailApp", dependencies: ["KeyTrailCore", "KeyTrailIPC"], resources: [.copy("Resources")]),
        .testTarget(name: "KeyTrailCoreTests", dependencies: ["KeyTrailCore"])
    ],
    swiftLanguageModes: [.v5]
)
