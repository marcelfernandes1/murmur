import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog

/// Captures microphone audio and converts it to the 16 kHz mono Float32 stream
/// the speech engines expect. Conversion happens live in the render callback so
/// `stop()` can return the full sample buffer immediately.
///
/// Capture is performed by an **input-only AUHAL unit** (`AUHALInputUnit`), not
/// `AVAudioEngine`. The engine's input node shares a HAL I/O unit that stays
/// bound to the system **default output** device, so output-side renegotiation
/// (AirPods Max switching A2DP↔HFP) repeatedly tore the engine down even when we
/// recorded from the built-in mic. AUHAL with output IO disabled and the input
/// device pinned is immune to that: the system output device has no influence on
/// it. There is no probe engine and no active-capture rebuild loop — a single
/// hotkey press produces at most one microphone activation sequence.
///
/// Bluetooth inputs still renegotiate their stream format asynchronously
/// (A2DP → HFP) when first selected as input. We open the *final* capture unit,
/// poll its input format until it is nonzero and stable, then start that same
/// unit — no temporary engine, no double rebuild.
///
/// All lifecycle work (open / settle / start / stop / device-change) is
/// serialized on a private serial queue. A monotonically increasing
/// `captureGeneration` tags each capture attempt so a delayed format-settle hop
/// from a superseded attempt is ignored.
///
/// Why a capture is being stopped — logged at every `stop(reason:)` call site so
/// a premature finalize can be traced to its true cause rather than guessed at.
enum StopReason: String {
    case hotkeyReleased          // genuine trigger key-up
    case hotkeyCancelled         // start was superseded/cancelled before listening
    case engineStopped           // the capture unit died and could not recover
    case configurationChange     // an audio configuration change
    case silenceTimeout          // auto-stop on prolonged silence
    case appDeactivated          // app lost focus / is shutting down
    case explicitUserAction      // user pressed a stop/cancel control
    case errorRecovery           // tearing down as part of error handling
}

/// `@unchecked Sendable`: every piece of mutable capture state is confined to
/// `lifecycleQueue`, and the sample buffer is guarded by `lock`.
final class AudioRecorder: @unchecked Sendable {
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

    /// Best-effort, thread-safe query of whether the trigger key is believed held,
    /// for diagnostics. Set by the controller.
    var hotkeyHeldProvider: (@Sendable () -> Bool)?

    /// UID of the input device to record from, or nil to follow the system default.
    /// Changing it while idle merely selects the device for the next `start()`.
    /// Changing it mid-capture atomically restarts on the new device, preserving
    /// the samples captured so far.
    var preferredDeviceUID: String? {
        get { lifecycleQueue.sync { currentDeviceUID } }
        set {
            lifecycleQueue.async { [weak self] in
                guard let self, self.currentDeviceUID != newValue else { return }
                self.currentDeviceUID = newValue
                self.diag("device preference changed → \(newValue ?? "System Default")")
                if self.capturing {
                    self.diag("device changed during capture → atomic restart on new device, preserving \(self.snapshotCount()) samples")
                    self.launchCaptureLocked(resetSamplesFirst: false) { _ in }
                }
            }
        }
    }

    private static let logger = Logger(subsystem: "com.murmur.app", category: "audio")

    /// Serial queue owning all capture lifecycle state.
    private let lifecycleQueue = DispatchQueue(label: "com.murmur.app.audio.lifecycle")

    // Bluetooth format stabilization tuning.
    private static let stabilizePollInterval: TimeInterval = 0.15
    private static let stabilizeReadingsNeeded = 3
    private static let stabilizeTimeout: TimeInterval = 3.0

    // MARK: Lifecycle-queue-confined state
    private var captureUnit: AUHALInputUnit?
    /// Incremented for every capture attempt (start, restart, stop) so delayed
    /// format-settle hops belonging to a superseded attempt abort themselves.
    private var captureGeneration = 0
    private var converter: AVAudioConverter?
    private var monoInputFormat: AVAudioFormat?
    /// True between a successful `start()` and the matching `stop()`.
    private var capturing = false
    private var currentDeviceUID: String?

    // MARK: Audio-thread / cross-thread state (guarded by `lock`)
    private let lock = NSLock()
    private var samples: [Float] = []
    private var bufferCallbackCount = 0
    private var totalInputFrames = 0
    // Level metering accumulator. The render thread adds energy here; the UI's
    // fixed visual clock drains it via `drainLevel()`. Decoupling metering from
    // callback cadence keeps the waveform's speed identical regardless of how
    // often (or in what buffer size) the device delivers audio.
    private var levelSumSquares: Float = 0
    private var levelFrames: Int = 0
    private var levelPeak: Float = 0

    /// Largest absolute sample amplitude seen since the last `start()`.
    private(set) var peakAmplitude: Float = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init() {}

    // MARK: - Public API

    func start() async throws {
        try await requestPermission()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lifecycleQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.startLocked { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// A snapshot of audio captured so far, without stopping (used for streaming).
    func currentSamples() -> [Float] {
        snapshot()
    }

    /// Stops capture and returns everything recorded so far. `reason` is logged so a
    /// premature stop can be attributed to its true call site.
    @discardableResult
    func stop(reason: StopReason) -> [Float] {
        lifecycleQueue.sync {
            let (cb, frames) = capturedCounters()
            let rc = captureUnit
            diag("stop requested reason=\(reason.rawValue) gen=\(captureGeneration) (capturing=\(capturing) renderCallbacks=\(rc?.renderCallbackCount ?? 0) renderedFrames=\(rc?.renderedFrameCount ?? 0) droppedOversize=\(rc?.droppedOversizeSlices ?? 0) bufferCallbacks=\(cb) totalInputFrames=\(frames) peak=\(peakAmplitude) samples=\(snapshotCount()))")
            capturing = false
            captureGeneration &+= 1   // invalidate any in-flight settle hop
            teardownUnitLocked()
        }
        return snapshot()
    }

    // MARK: - Start sequence (runs on `lifecycleQueue`)

    private func startLocked(completion: @escaping (Result<Void, Error>) -> Void) {
        diag("start requested (capturing was \(capturing))")
        capturing = true
        launchCaptureLocked(resetSamplesFirst: true, completion: completion)
    }

    /// Open and start an AUHAL capture unit on the currently-resolved device.
    /// Used both for a fresh start (`resetSamplesFirst: true`) and for an atomic
    /// mid-capture device switch (`resetSamplesFirst: false`, samples preserved).
    private func launchCaptureLocked(resetSamplesFirst: Bool,
                                     completion: @escaping (Result<Void, Error>) -> Void) {
        captureGeneration &+= 1
        let generation = captureGeneration
        if resetSamplesFirst { resetSamples() }

        // Drop any previous unit (idempotent) before opening a new one.
        teardownUnitLocked()

        guard let deviceID = resolvedDeviceIDLocked() else {
            diag("no input device available → noInput")
            capturing = false
            completion(.failure(RecorderError.noInput))
            return
        }
        let isBT = AudioDevices.isBluetooth(deviceID)
        let name = AudioDevices.name(for: deviceID) ?? "?"
        diag("resolved device id=\(deviceID) name=\"\(name)\" uid=\(currentDeviceUID ?? "System Default") transport=\(AudioDevices.transportType(deviceID)) bluetooth=\(isBT) alive=\(AudioDevices.isRunningSomewhere(deviceID)) gen=\(generation)")

        let unit = AUHALInputUnit()
        unit.onBuffer = { [weak self] channels, channelCount, frames, rate in
            self?.process(channels: channels, channelCount: channelCount, frames: frames, sampleRate: rate)
        }
        unit.onRenderError = { [weak self] status in
            self?.handleRenderError(status: status, generation: generation)
        }

        do {
            try unit.open(deviceID: deviceID)
        } catch {
            diag("open failed: \(error.localizedDescription)")
            if resetSamplesFirst { capturing = false }
            completion(.failure(error))
            return
        }
        captureUnit = unit

        if isBT {
            diag("Bluetooth input → polling unit input format until it settles (gen=\(generation))")
            let deadline = DispatchTime.now() + Self.stabilizeTimeout
            settleThenStart(generation: generation, lastRate: nil, streak: 0, deadline: deadline, completion: completion)
        } else {
            finishStartLocked(generation: generation, completion: completion)
        }
    }

    /// Poll the unit's input format every 150 ms until it is nonzero and unchanged
    /// across `stabilizeReadingsNeeded` consecutive readings, or the deadline; then
    /// start the same unit. Chained `asyncAfter` hops (not a blocking sleep), each
    /// guarded by `generation` so a superseded attempt's hops self-abort.
    private func settleThenStart(generation: Int,
                                 lastRate: Double?,
                                 streak: Int,
                                 deadline: DispatchTime,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard capturing, generation == captureGeneration, let unit = captureUnit else {
            diag("settle aborted (capturing=\(capturing) gen=\(generation) current=\(captureGeneration))")
            return
        }

        let fmt = unit.hardwareInputFormat
        let rate = fmt?.mSampleRate ?? 0
        let channels = fmt?.mChannelsPerFrame ?? 0
        diag("settle poll: input \(rate) Hz, \(channels) ch (streak=\(streak))")

        if rate > 0, channels > 0 {
            let newStreak = (lastRate == rate) ? streak + 1 : 1
            if newStreak >= Self.stabilizeReadingsNeeded {
                diag("format settled at \(rate) Hz, \(channels) ch")
                finishStartLocked(generation: generation, completion: completion)
                return
            }
            if DispatchTime.now() >= deadline {
                diag("format settle TIMED OUT at \(rate) Hz, \(channels) ch → proceeding")
                finishStartLocked(generation: generation, completion: completion)
                return
            }
            lifecycleQueue.asyncAfter(deadline: .now() + Self.stabilizePollInterval) { [weak self] in
                self?.settleThenStart(generation: generation, lastRate: rate, streak: newStreak, deadline: deadline, completion: completion)
            }
            return
        }

        if DispatchTime.now() >= deadline {
            diag("format settle TIMED OUT (still no valid format) → proceeding anyway")
            finishStartLocked(generation: generation, completion: completion)
            return
        }
        lifecycleQueue.asyncAfter(deadline: .now() + Self.stabilizePollInterval) { [weak self] in
            self?.settleThenStart(generation: generation, lastRate: nil, streak: 0, deadline: deadline, completion: completion)
        }
    }

    private func finishStartLocked(generation: Int,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        guard capturing, generation == captureGeneration, let unit = captureUnit else {
            diag("finishStart aborted (capturing=\(capturing) gen=\(generation) current=\(captureGeneration))")
            completion(.success(()))
            return
        }

        // Conversion is rebuilt lazily in `process()` from the first buffer's rate.
        converter = nil
        monoInputFormat = nil

        do {
            try unit.startCapturing()
            diag("capture started: native \(unit.nativeSampleRate) Hz, \(unit.nativeChannelCount) ch (gen=\(generation))")
            completion(.success(()))
        } catch {
            diag("startCapturing failed: \(error.localizedDescription)")
            teardownUnitLocked()
            capturing = false
            completion(.failure(error))
        }
    }

    /// Stop and release the current capture unit, if any. Safe to call repeatedly.
    /// Never clears captured samples — those are owned by start/stop.
    private func teardownUnitLocked() {
        if let unit = captureUnit {
            unit.stop()
            diag("capture unit torn down (gen=\(captureGeneration))")
        }
        captureUnit = nil
    }

    /// A render-callback `AudioUnitRender` failure (typically the selected device
    /// was unplugged mid-capture). Stop the dead unit cleanly so the device is
    /// released; leave the captured samples intact so the take still finalizes on
    /// key release. Never crashes on a stale pointer — `stop()` is idempotent and
    /// Core Audio guarantees no further callbacks after it returns.
    private func handleRenderError(status: OSStatus, generation: Int) {
        lifecycleQueue.async { [weak self] in
            guard let self, generation == self.captureGeneration else { return }
            self.diag("render error \(osStatusString(status)) → stopping unit; capture will finalize on release (samples=\(self.snapshotCount()))")
            self.teardownUnitLocked()
        }
    }

    // MARK: - Device resolution (runs on `lifecycleQueue`)

    private func resolvedDeviceIDLocked() -> AudioDeviceID? {
        if let uid = currentDeviceUID {
            if let id = AudioDevices.deviceID(forUID: uid) { return id }
            diag("selected device \(uid) is gone → falling back to system default input")
        }
        return AudioDevices.defaultInputDeviceID()
    }

    // MARK: - Audio processing (runs on the real-time render thread)

    /// Deinterleaved Float32 channels at `inputRate`, downmixed to the loudest
    /// channel and sample-rate converted to 16 kHz mono. Pointers are valid only
    /// for this call.
    private func process(channels srcData: UnsafePointer<UnsafeMutablePointer<Float>>,
                         channelCount: Int,
                         frames: Int,
                         sampleRate inputRate: Double) {
        guard frames > 0, channelCount > 0 else { return }
        countInput(frames: frames)

        if converter == nil || monoInputFormat?.sampleRate != inputRate {
            guard inputRate > 0, let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputRate,
                channels: 1,
                interleaved: false
            ) else { return }
            monoInputFormat = mono
            converter = AVAudioConverter(from: mono, to: targetFormat)
        }
        guard let converter, let monoFormat = monoInputFormat else { return }

        // 1) Downmix to mono ourselves (loudest channel). AVAudioConverter's own
        //    N→1 downmix yields silence when the device's format has no channel layout.
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        var bestChannel = 0
        if channelCount > 1 {
            var bestEnergy: Float = -1
            for c in 0..<channelCount {
                var energy: Float = 0
                let src = srcData[c]
                for f in 0..<frames { let v = src[f]; energy += v * v }
                if energy > bestEnergy { bestEnergy = energy; bestChannel = c }
            }
        }
        let src = srcData[bestChannel]
        for f in 0..<frames { dst[f] = src[f] }

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
        if localPeak > peakAmplitude { peakAmplitude = localPeak }

        accumulateLevel(sumSquares: sumSquares, frames: outFrames, peak: localPeak)
        append(slice)
    }

    /// Drain the level accumulator: RMS and peak over the interval since the last
    /// drain, then reset. Returns nil if no audio arrived in the interval. Called
    /// from the UI's fixed visual clock — never from the render thread.
    func drainLevel() -> (rms: Float, peak: Float)? {
        lock.lock()
        defer {
            levelSumSquares = 0
            levelFrames = 0
            levelPeak = 0
            lock.unlock()
        }
        guard levelFrames > 0 else { return nil }
        return ((levelSumSquares / Float(levelFrames)).squareRoot(), levelPeak)
    }

    private func accumulateLevel(sumSquares: Float, frames: Int, peak: Float) {
        lock.lock()
        levelSumSquares += sumSquares
        levelFrames += frames
        if peak > levelPeak { levelPeak = peak }
        lock.unlock()
    }

    // MARK: - Synchronous sample buffer access (lock never held across a suspension)

    private func resetSamples() {
        peakAmplitude = 0
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        bufferCallbackCount = 0
        totalInputFrames = 0
        levelSumSquares = 0
        levelFrames = 0
        levelPeak = 0
        lock.unlock()
    }

    private func append(_ slice: UnsafeBufferPointer<Float>) {
        lock.lock()
        samples.append(contentsOf: slice)
        lock.unlock()
    }

    private func countInput(frames: Int) {
        lock.lock()
        bufferCallbackCount += 1
        totalInputFrames += frames
        lock.unlock()
    }

    private func capturedCounters() -> (callbacks: Int, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (bufferCallbackCount, totalInputFrames)
    }

    private func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func snapshotCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
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

    // MARK: - Diagnostics

    private func diag(_ message: String) {
        Self.logger.log("[AudioRecorder] \(message, privacy: .public)")
        #if DEBUG
        Self.fileLog(message)
        #endif
    }

    /// os.Logger is unreliable for this build (entries don't surface in
    /// `log show`), so mirror every diagnostic to a flat file we can tail.
    /// DEBUG-only: a shipping build must not accumulate an unbounded /tmp log.
    #if DEBUG
    private static let fileLogURL = URL(fileURLWithPath: "/tmp/murmur_recorder.log")
    private static let fileLogQueue = DispatchQueue(label: "com.murmur.app.audio.filelog")
    private static func fileLog(_ message: String) {
        fileLogQueue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileLogURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: fileLogURL)
            }
        }
    }
    #endif
}
