import CryptoKit
import Foundation

/// Build-time-pinned SHA-256 + byte size for every model Murmur downloads itself.
///
/// Why this exists: the app fetches multi-GB ggml/GGUF weights over HTTPS and hands
/// them straight to C/C++ parsers (`whisper_init_from_file`, llama) — a memory-
/// corruption surface — in an UNSANDBOXED process. HTTPS alone isn't enough: there's
/// no certificate pinning, and a hijacked Hugging Face repo would serve a malicious
/// file under a valid TLS cert. Freezing the expected hash in the signed app binary
/// means a tampered/substituted weight is rejected before it's ever loaded.
///
/// Files not listed here (e.g. WhisperKit's own Hub-managed Core ML bundles, which we
/// don't download through `ModelDownloader`) fall back to no check — we never fail
/// closed on an unpinned file, so adding a new model can't brick the app.
enum ModelManifest {
    struct Pin { let sha256: String; let size: Int }

    /// Keyed by the download's final filename.
    static let pins: [String: Pin] = [
        // whisper.cpp ggml — repo: ggerganov/whisper.cpp
        "ggml-tiny.bin": Pin(sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", size: 77691713),
        "ggml-tiny.en.bin": Pin(sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f", size: 77704715),
        "ggml-base.bin": Pin(sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", size: 147951465),
        "ggml-base.en.bin": Pin(sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", size: 147964211),
        "ggml-small.bin": Pin(sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", size: 487601967),
        "ggml-small.en.bin": Pin(sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", size: 487614201),
        "ggml-small-q5_1.bin": Pin(sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", size: 190085487),
        "ggml-medium.bin": Pin(sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208", size: 1533763059),
        "ggml-medium.en.bin": Pin(sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356", size: 1533774781),
        "ggml-medium-q5_0.bin": Pin(sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f", size: 539212467),
        "ggml-medium.en-q5_0.bin": Pin(sha256: "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0", size: 539225533),
        "ggml-large-v2.bin": Pin(sha256: "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487", size: 3094623691),
        "ggml-large-v2-q5_0.bin": Pin(sha256: "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2", size: 1080732091),
        "ggml-large-v3.bin": Pin(sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", size: 3095033483),
        "ggml-large-v3-q5_0.bin": Pin(sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1", size: 1081140203),
        "ggml-large-v3-turbo.bin": Pin(sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", size: 1624555275),
        "ggml-large-v3-turbo-q5_0.bin": Pin(sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", size: 574041195),
        "ggml-large-v3-turbo-q8_0.bin": Pin(sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1", size: 874188075),

        // Qwen GGUF cleanup models — repos: bartowski/Qwen2.5-{3B,1.5B}-Instruct-GGUF
        "Qwen2.5-3B-Instruct-Q4_K_M.gguf": Pin(sha256: "9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94", size: 1929903264),
        "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf": Pin(sha256: "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370", size: 986048768),
    ]

    enum VerifyError: Error, CustomStringConvertible {
        case sizeMismatch(expected: Int, got: Int)
        case hashMismatch

        var description: String {
            switch self {
            case .sizeMismatch(let e, let g): return "Model size mismatch (expected \(e) bytes, got \(g))."
            case .hashMismatch: return "Model checksum doesn't match the expected build-pinned hash — the download may be corrupt or tampered with."
            }
        }
    }

    /// Cheap integrity check for a cached file (size only — instant). Returns `true`
    /// when the file matches the pin OR the file isn't pinned (so unpinned models and
    /// WhisperKit's Hub bundles aren't blocked). Use on the cache-hit path to avoid
    /// re-hashing multi-GB weights on every model load.
    static func sizeMatches(fileName: String, at url: URL) -> Bool {
        guard let pin = pins[fileName] else { return true }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            return false
        }
        return size == pin.size
    }

    /// Full verification (size + streaming SHA-256) for a freshly downloaded file.
    /// No-op for unpinned files. Throws `VerifyError` on mismatch.
    static func verify(fileName: String, at url: URL) throws {
        guard let pin = pins[fileName] else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size != pin.size {
            throw VerifyError.sizeMismatch(expected: pin.size, got: size)
        }
        guard try sha256(of: url) == pin.sha256 else { throw VerifyError.hashMismatch }
    }

    /// Streaming SHA-256 (constant memory) so multi-GB weights aren't read into RAM.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
