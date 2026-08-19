import AVFoundation
import Foundation
import OSLog

/// OpenAI's file transcription endpoint, using `gpt-transcribe` — the model
/// OpenAI recommends over whisper-1 and the gpt-4o-transcribe pair (released
/// 2026-07-28; word error rate 19.27% vs whisper-1's 40.37% on Common Voice
/// across 22 languages).
///
/// Unlike every other engine here this sends the user's speech off the machine.
/// It is opt-in, never the default, and requires a key the user pastes in
/// themselves (see `APIKeyStore`).
actor OpenAIFileService: SpeechEngine {
    /// The file endpoint accepts 25 MB. 16 kHz 16-bit mono is 32 KB/s, so this
    /// is ~13 minutes — long, but hands-free takes can exceed it, and a clear
    /// error beats a 400 from the API.
    private static let maxUploadBytes = 25 * 1024 * 1024
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let model = "gpt-transcribe"

    private static let log = Logger(subsystem: "com.murmur.app", category: "openai")
    private var stateHandler: (@Sendable (EngineLoadState) -> Void)?
    private var warmedAt: ContinuousClock.Instant?

    /// One session so connections are pooled and reused across dictations.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    nonisolated var inputSampleRate: Int { 16_000 }

    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) {
        stateHandler = handler
    }

    /// Nothing to load — but report readiness (or a missing key) so the UI and
    /// the transcription watchdog behave the same as for a local model.
    func preload() async {
        stateHandler?(APIKeyStore.hasKey ? .ready : .failed("Add your OpenAI API key in Settings"))
    }

    /// Open the TLS connection now, while the user is still speaking, so the
    /// upload after they stop reuses a warm socket. Measured round trips were a
    /// flat ~2.5 s regardless of audio length — that is handshake plus server
    /// time, not upload, so this is the part worth moving off the critical path.
    /// URLSession keeps pooled connections alive for a while; re-warming more
    /// than once a minute is wasted work.
    func warmUp() async {
        guard APIKeyStore.hasKey else { return }
        if let warmedAt, ContinuousClock.now - warmedAt < .seconds(60) { return }
        warmedAt = ContinuousClock.now
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        if let key = APIKeyStore.load() { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        _ = try? await Self.session.data(for: request)
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        guard let key = APIKeyStore.load() else { throw OpenAIError.missingKey }

        let wav = AudioWAV.encode(samples, sampleRate: inputSampleRate)
        guard wav.count <= Self.maxUploadBytes else {
            throw OpenAIError.tooLong(seconds: Double(samples.count) / Double(inputSampleRate))
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let boundary = "murmur-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        field("model", Self.model)
        field("response_format", "text")
        if let language, !language.isEmpty { field("language", language) }
        if !vocabulary.isEmpty { field("prompt", vocabulary.joined(separator: ", ")) }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n")

        let started = ContinuousClock.now
        let (data, response) = try await Self.session.upload(for: request, from: body)
        let elapsed = ContinuousClock.now - started

        guard let http = response as? HTTPURLResponse else { throw OpenAIError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the API's own message — it names the real problem (bad key,
            // quota, unsupported model) far better than a status code.
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(http.statusCode)"
            Self.log.error("transcription failed (\(http.statusCode, privacy: .public)): \(detail, privacy: .public)")
            throw OpenAIError.api(status: http.statusCode, message: detail)
        }

        let audioSeconds = Double(samples.count) / Double(inputSampleRate)
        Self.log.log("gpt-transcribe: \(audioSeconds, privacy: .public)s audio, \(wav.count / 1024, privacy: .public) KB, round trip \(elapsed.seconds, privacy: .public)s")

        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OpenAIError: LocalizedError {
    case missingKey
    case tooLong(seconds: Double)
    case api(status: Int, message: String)
    case badResponse(String)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No OpenAI API key — add one in Settings ▸ Advanced."
        case .tooLong(let seconds):
            return "Recording too long for OpenAI (\(Int(seconds))s exceeds the 25 MB upload limit)."
        case .api(let status, let message):
            return status == 401
                ? "OpenAI rejected the API key."
                : "OpenAI error \(status): \(message.prefix(200))"
        case .badResponse(let detail):
            return "Unexpected response from OpenAI: \(detail)"
        case .connectionClosed:
            return "OpenAI closed the connection before the transcript arrived."
        }
    }
}

extension Duration {
    /// Seconds as a Double, for logging.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

/// Minimal 16-bit PCM WAV encoder — the one container every OpenAI audio
/// endpoint accepts, and small enough not to justify a dependency.
enum AudioWAV {
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        let byteRate = sampleRate * 2
        let dataBytes = samples.count * 2

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32: UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(uint32: 16)                       // PCM header size
        data.append(uint16: 1)                        // format: PCM
        data.append(uint16: 1)                        // channels: mono
        data.append(uint32: UInt32(sampleRate))
        data.append(uint32: UInt32(byteRate))
        data.append(uint16: 2)                        // block align
        data.append(uint16: 16)                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32: UInt32(dataBytes))
        for sample in samples {
            data.append(uint16: UInt16(bitPattern: pcm16(sample)))
        }
        return data
    }

    /// Clamp before scaling: a converter overshoot past ±1 would otherwise wrap
    /// around and turn a loud syllable into a burst of noise.
    static func pcm16(_ sample: Float) -> Int16 {
        let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
        return Int16(clamped * 32_767)
    }

    /// Env-gated self-test. A malformed header or the wrong endianness fails
    /// silently as a 400 from OpenAI, so check the bytes we actually produce by
    /// decoding them back with AVFoundation.
    /// Run with: `MURMUR_TEST_COVERAGE=1 open Murmur.app`.
    @discardableResult
    static func runSelfTest() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            print("[WAV] \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }

        let rate = 24_000
        // A 1 kHz tone at 0.5 amplitude — non-trivial, and easy to check.
        let samples: [Float] = (0..<rate).map { i in
            0.5 * sin(2 * .pi * 1000 * Float(i) / Float(rate))
        }
        let data = encode(samples, sampleRate: rate)

        check("header size", data.count == 44 + samples.count * 2, "got \(data.count)")
        check("RIFF magic", data.prefix(4).elementsEqual(Array("RIFF".utf8)))
        check("WAVE magic", data.dropFirst(8).prefix(4).elementsEqual(Array("WAVE".utf8)))
        let declaredRate = data.dropFirst(24).prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
        check("sample rate in header", declaredRate == UInt32(rate), "got \(declaredRate)")

        // Decode it back the way a server would.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-wav-selftest.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            check("decodes", true)
            check("frame count", file.length == Int64(samples.count), "got \(file.length)")
            check("decoded rate", file.fileFormat.sampleRate == Double(rate),
                  "got \(file.fileFormat.sampleRate)")
            check("mono", file.fileFormat.channelCount == 1)

            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let peak = (0..<Int(buffer.frameLength))
                .map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
            // 16-bit quantization costs a hair; anything far off means the bytes
            // are being written wrong (endianness, offset, sign).
            check("peak preserved", abs(peak - 0.5) < 0.01, "got \(peak)")
        } catch {
            check("decodes", false, "\(error)")
        }

        print("[WAV] \(failed == 0 ? "all passed" : "\(failed) failed")")
        fflush(stdout)
        return failed
    }
}

private extension Data {
    mutating func append(uint32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { self.append(contentsOf: $0) }
    }
    mutating func append(uint16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { self.append(contentsOf: $0) }
    }
}
