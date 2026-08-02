// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "yap",
    // macOS 15, not 14: SystemAudioRecorder uses Core Audio process taps
    // (AudioHardwareCreateProcessTap / CATapDescription), which are 14.2+ and
    // unguarded. Gating them behind @available would spread version checks
    // through the audio layer for the sake of a two-versions-old OS.
    // String form, not `.v15`: that enum case needs tools-version 6.0, which
    // would also switch the whole target into Swift 6 language mode.
    platforms: [.macOS("15.0")],
    // Two dependencies, and it stays that way. Parakeet on the ANE is the
    // only engine: it is both faster and more accurate than the small Whisper
    // models on short dictation clips, and parakeet-tdt-0.6b-v3 covers the
    // other languages, so a second engine would cost six more packages and
    // buy nothing measurable.
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "yap",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Info.plist"],
            // Embed the plist in the binary itself (__TEXT,__info_plist) so TCC
            // can attribute microphone and accessibility grants to yap when it
            // runs as a bare LaunchAgent rather than from an .app bundle.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/yap/Info.plist",
                ])
            ]
        )
    ]
)
