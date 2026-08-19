import Foundation
import OSLog

/// OpenAI's realtime transcription over a WebSocket, using `gpt-live-transcribe`
/// — the low-latency streaming counterpart to `gpt-transcribe`.
///
/// The point of this engine is that the transcript is already being produced
/// while the user is still talking, so releasing the trigger costs one commit
/// round trip instead of a whole upload-and-decode. That only works if the
/// controller pumps audio in during capture, which is what `LiveSpeechEngine` is
/// for.
///
/// Audio goes up as 24 kHz PCM16, and the recorder is told to capture at that
/// rate for this engine rather than resampling 16 kHz up — the microphone runs
/// at 48 kHz, so 48→16→24 would throw away everything above 8 kHz first.
actor OpenAIRealtimeService: LiveSpeechEngine {
    static let model = "gpt-live-transcribe"
    private static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    private static let log = Logger(subsystem: "com.murmur.app", category: "openai")

    /// What the realtime audio format is configured to below.
    nonisolated var inputSampleRate: Int { 24_000 }

    private var stateHandler: (@Sendable (EngineLoadState) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    /// Text assembled from the transcription events.
    private var transcript = ""
    /// Set when the session reports a completed transcript for the committed turn.
    private var completion: CheckedContinuation<String, Error>?
    private var liveStarted: ContinuousClock.Instant?

    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) {
        stateHandler = handler
    }

    func preload() async {
        stateHandler?(APIKeyStore.hasKey ? .ready : .failed("Add your OpenAI API key in Settings"))
    }

    // MARK: - Live session

    func beginLive(language: String?, vocabulary: [String]) async {
        guard let key = APIKeyStore.load() else {
            stateHandler?(.failed("No OpenAI API key"))
            return
        }
        transcript = ""
        liveStarted = ContinuousClock.now

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveTask = Task { await self.receiveLoop(task) }

        // Manual turn detection: Murmur already knows when the user started and
        // stopped talking, so let it commit rather than having the server guess.
        // `keywords` is a structured field, unlike whisper's initial prompt, so
        // biasing toward the custom vocabulary here cannot leak into the text.
        var transcription: [String: Any] = ["model": Self.model]
        if !vocabulary.isEmpty { transcription["keywords"] = vocabulary }
        if let language, !language.isEmpty { transcription["languages"] = [language] }
        send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": inputSampleRate],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ])
    }

    func appendLive(_ samples: [Float]) async {
        guard socket != nil, !samples.isEmpty else { return }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var little = UInt16(bitPattern: AudioWAV.pcm16(sample)).littleEndian
            Swift.withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    func finishLive() async throws -> String {
        guard let socket else { throw OpenAIError.missingKey }
        send(["type": "input_audio_buffer.commit"])

        // The commit is acknowledged with a completed transcript for the turn.
        // Bounded so a silent server can't hang the dictation — the controller's
        // watchdog would eventually fire, but this fails faster and more clearly.
        let text: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitCompletion() }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                throw OpenAIError.badResponse("timed out waiting for the final transcript")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OpenAIError.connectionClosed }
            return first
        }

        if let started = liveStarted {
            Self.log.log("gpt-live-transcribe: commit→text \((ContinuousClock.now - started).seconds, privacy: .public)s total session")
        }
        await cancelLive()
        _ = socket
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelLive() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if let completion {
            self.completion = nil
            completion.resume(throwing: OpenAIError.connectionClosed)
        }
    }

    /// Batch entry point. The controller uses the live path for this engine; this
    /// exists so it still satisfies `SpeechEngine`, and covers the case where a
    /// take was captured before the live session came up.
    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        if !transcript.isEmpty { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        await beginLive(language: language, vocabulary: vocabulary)
        await appendLive(samples)
        return try await finishLive()
    }

    // MARK: - Socket plumbing

    private func awaitCompletion() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.completion = continuation
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            if let error { Self.log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                handle(type: type, event: event)
            } catch {
                finishWithFailure(error)
                return
            }
        }
    }

    private func handle(type: String, event: [String: Any]) {
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String { transcript += delta }
        case "conversation.item.input_audio_transcription.completed":
            if let final = event["transcript"] as? String, !final.isEmpty { transcript = final }
            if let continuation = completion {
                completion = nil
                continuation.resume(returning: transcript)
            }
        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
            Self.log.error("realtime error: \(message, privacy: .public)")
            finishWithFailure(OpenAIError.api(status: 0, message: message))
        default:
            break
        }
    }

    private func finishWithFailure(_ error: Error) {
        guard let continuation = completion else { return }
        completion = nil
        // Anything already transcribed beats losing the take entirely.
        if transcript.isEmpty {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: transcript)
        }
    }
}
