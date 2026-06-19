// swift-tools-version: 5.9
import PackageDescription

// Vendors whisper.cpp's *official* prebuilt XCFramework (Metal + Core ML) from
// https://github.com/ggml-org/whisper.cpp/releases. We use the binary release
// rather than building from source because:
//
//   * The upstream source `Package.swift` was removed; Apple-platform support is
//     now shipped exclusively as this XCFramework (built by `build-xcframework.sh`).
//   * It's compiled WITH the Metal backend, so models run GPU-accelerated. The old
//     community `whisper.spm` source package has Metal disabled (CPU-only).
//
// IMPORTANT — why `WhisperCppKit` wraps the binary instead of exposing it directly:
// the app also links LLM.swift, which bundles `llama.framework` carrying its OWN
// (older, incompatible) copy of the `ggml` C headers. If the app target imported
// the raw `whisper` C module, Clang would see `ggml_*` structs defined two
// different ways across the `whisper` and `llama` modules — a hard "different
// definitions in different modules" error. Confining `import whisper` to this
// Swift target (whose public API exposes only Swift types, never ggml/whisper C
// types) keeps the two ggml copies out of the same compilation context. The two
// frameworks stay separate dylibs at runtime (macOS two-level namespace), so
// there's no symbol clash at link time either.
//
// To bump: download the new `whisper-vX.Y.Z-xcframework.zip`, run
// `swift package compute-checksum <zip>`, update the URL + checksum below.
let package = Package(
    name: "WhisperCpp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WhisperCppKit", targets: ["WhisperCppKit"])
    ],
    targets: [
        .target(
            name: "WhisperCppKit",
            dependencies: ["whisper"]
        ),
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        )
    ]
)
