import AVFoundation

/// Captures microphone audio and converts it to the 16 kHz mono Float32 stream
/// the speech engines expect. Conversion happens live in the input tap so
/// `stop()` can return the full sample buffer immediately.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case noInput

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone."
            case .noInput:
                return "No microphone input is available."
            }
        }
    }

    /// Called on the audio thread with an RMS level for metering (drives the notch waveform).
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var isTapped = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start() async throws {
        try await requestPermission()
        resetSamples()

        // Defensive: never install a second tap on a bus that already has one
        // (that throws an ObjC exception → SIGABRT). Always reset first.
        if engine.isRunning { engine.stop() }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        isTapped = false

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        isTapped = true

        engine.prepare()
        try engine.start()
    }

    /// A snapshot of audio captured so far, without stopping (used for streaming).
    func currentSamples() -> [Float] {
        snapshot()
    }

    /// Stops capture and returns everything recorded so far.
    @discardableResult
    func stop() -> [Float] {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        engine.stop()
        return snapshot()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }

        guard let channel = out.floatChannelData, out.frameLength > 0 else { return }
        let frames = Int(out.frameLength)
        let slice = UnsafeBufferPointer(start: channel[0], count: frames)

        var sumSquares: Float = 0
        for value in slice { sumSquares += value * value }
        let rms = (sumSquares / Float(frames)).squareRoot()
        onLevel?(rms)

        append(slice)
    }

    // MARK: - Synchronous sample buffer access (lock never held across a suspension)

    private func resetSamples() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func append(_ slice: UnsafeBufferPointer<Float>) {
        lock.lock()
        samples.append(contentsOf: slice)
        lock.unlock()
    }

    private func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw RecorderError.permissionDenied }
        default:
            throw RecorderError.permissionDenied
        }
    }
}
