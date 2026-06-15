import AVFoundation
import AudioToolbox
import CoreAudio

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

    /// UID of the input device to record from, or nil to follow the system default.
    var preferredDeviceUID: String?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// Mono version of the input format (input sample rate, 1 ch) — the converter
    /// only does sample-rate conversion; we downmix channels ourselves.
    private var monoInputFormat: AVAudioFormat?
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

        // Route to the chosen input device before querying its format. Must
        // happen while the engine is stopped and before the node is pulled.
        applyPreferredInputDevice(to: input)

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }

        // The converter's job is sample-rate only: input(mono, e.g. 48k) → 16k mono.
        // We downmix the tap's (possibly multi-channel) buffers to mono ourselves
        // first, because AVAudioConverter's own N→mono downmix yields silence when
        // the device's format carries no channel layout (aggregate/virtual devices).
        let monoInput = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        monoInputFormat = monoInput
        converter = AVAudioConverter(from: monoInput, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        isTapped = true

        engine.prepare()
        try engine.start()
    }

    /// Point the engine's input node at `preferredDeviceUID` (if set and still
    /// present). On failure it silently leaves the system default in place.
    private func applyPreferredInputDevice(to input: AVAudioInputNode) {
        guard let uid = preferredDeviceUID,
              let deviceID = AudioDevices.deviceID(forUID: uid),
              let unit = input.audioUnit else { return }
        var device = deviceID
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// Largest absolute sample amplitude seen since the last `start()`. Used to
    /// distinguish a working mic from a silent one (unauthorized/muted/wrong
    /// device all deliver digital silence → peak ≈ 0).
    private(set) var peakAmplitude: Float = 0

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
        guard let converter, let monoFormat = monoInputFormat else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let srcData = buffer.floatChannelData else { return }

        // 1) Reduce the tap buffer (any channel count) to mono ourselves, taking
        //    the loudest channel. For a normal 1-channel mic this is a passthrough;
        //    for a multi-channel aggregate/virtual device it isolates the channel
        //    actually carrying the mic. (We must do this rather than let
        //    AVAudioConverter downmix N→1: it silently outputs zeros when the
        //    device's format has no channel layout — which read as a dead mic.)
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0] else { return }
        mono.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        func sample(_ channel: Int, _ frame: Int) -> Float {
            interleaved ? srcData[0][frame * channelCount + channel] : srcData[channel][frame]
        }
        var bestChannel = 0
        if channelCount > 1 {
            var bestEnergy: Float = -1
            for c in 0..<channelCount {
                var energy: Float = 0
                for f in 0..<frames { let v = sample(c, f); energy += v * v }
                if energy > bestEnergy { bestEnergy = energy; bestChannel = c }
            }
        }
        for f in 0..<frames { dst[f] = sample(bestChannel, f) }

        // 2) Sample-rate convert the mono buffer to 16 kHz.
        let ratio = targetFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16
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
            return mono
        }

        guard let channel = out.floatChannelData, out.frameLength > 0 else { return }
        let outFrames = Int(out.frameLength)
        let slice = UnsafeBufferPointer(start: channel[0], count: outFrames)

        var sumSquares: Float = 0
        var localPeak: Float = 0
        for value in slice {
            sumSquares += value * value
            localPeak = max(localPeak, abs(value))
        }
        let rms = (sumSquares / Float(outFrames)).squareRoot()
        if localPeak > peakAmplitude { peakAmplitude = localPeak }

        onLevel?(rms)
        append(slice)
    }

    // MARK: - Synchronous sample buffer access (lock never held across a suspension)

    private func resetSamples() {
        peakAmplitude = 0
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
