import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog

/// Captures microphone audio and converts it to the 16 kHz mono Float32 stream
/// the speech engines expect. Conversion happens live in the input tap so
/// `stop()` can return the full sample buffer immediately.
///
/// All engine lifecycle work (probe / build / start / stop / device-change /
/// config-change) is serialized on a private serial queue so the operations can
/// never overlap and leave multiple taps or engines running. Nothing ever removes
/// a tap or replaces the engine from the real-time audio callback.
///
/// Wired/built-in/USB/Continuity inputs build the engine and start immediately.
/// **Bluetooth inputs (AirPods etc.) are different**: selecting one as the input
/// triggers an asynchronous A2DP → HFP transition, during which
/// `inputNode.outputFormat(forBus:0)` reports a zero / transient format. Starting
/// the engine then throws -10868 (kAudioUnitErr_FormatNotSupported). So for a
/// Bluetooth device we first bind it on a *temporary probe engine*, poll the format
/// until it is nonzero and stable across several readings (up to 3 s), then destroy
/// the probe, build a *fresh* engine against the now-settled format, and start.
///
/// Why a capture is being stopped — logged at every `stop(reason:)` call site so a
/// premature finalize can be traced to its true cause rather than guessed at.
enum StopReason: String {
    case hotkeyReleased          // genuine trigger key-up
    case hotkeyCancelled         // start was superseded/cancelled before listening
    case engineStopped           // the audio engine died and could not recover
    case configurationChange     // an audio configuration change (should recover, not finalize)
    case silenceTimeout          // auto-stop on prolonged silence
    case appDeactivated          // app lost focus / is shutting down
    case explicitUserAction      // user pressed a stop/cancel control
    case errorRecovery           // tearing down as part of error handling
}

/// `@unchecked Sendable`: every piece of mutable engine state is confined to
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

    /// Called on the audio thread with an RMS level for metering (drives the notch waveform).
    var onLevel: ((Float) -> Void)?

    /// Best-effort, thread-safe query of whether the trigger key is believed held,
    /// for configuration-change diagnostics. Set by the controller.
    var hotkeyHeldProvider: (@Sendable () -> Bool)?

    /// UID of the input device to record from, or nil to follow the system default.
    /// Changing it while idle merely flags a rebuild for the next `start()`.
    var preferredDeviceUID: String? {
        get { lifecycleQueue.sync { currentDeviceUID } }
        set {
            lifecycleQueue.async { [weak self] in
                guard let self, self.currentDeviceUID != newValue else { return }
                self.currentDeviceUID = newValue
                self.diag("device preference changed → \(newValue ?? "System Default")")
                self.handleDeviceChangeLocked()
            }
        }
    }

    private static let logger = Logger(subsystem: "com.murmur.app", category: "audio")

    /// Serial queue owning all engine lifecycle state.
    private let lifecycleQueue = DispatchQueue(label: "com.murmur.app.audio.lifecycle")

    // Bluetooth format stabilization tuning.
    private static let stabilizePollInterval: TimeInterval = 0.15
    private static let stabilizeReadingsNeeded = 3
    private static let stabilizeTimeout: TimeInterval = 3.0

    // MARK: Lifecycle-queue-confined state
    private var engine = AVAudioEngine()
    /// Incremented every time the engine is recreated, so logs can distinguish one
    /// physical engine instance from the next.
    private var engineGeneration = 1
    private var converter: AVAudioConverter?
    private var monoInputFormat: AVAudioFormat?
    private var isTapped = false
    private var engineRunning = false
    /// True between a successful `start()` and the matching `stop()`.
    private var capturing = false
    private var currentDeviceUID: String?
    /// A device/configuration change has invalidated the current engine; the next
    /// build will recreate from scratch. Set from the device setter and the config
    /// observer; acted on only inside the serialized build.
    private var needsEngineRebuild = false
    /// True while we are intentionally tearing down / starting the engine, so the
    /// configuration-change notifications WE cause are ignored. Cleared after a
    /// short debounce. NOT set during Bluetooth probing — a config change there may
    /// be the HFP-transition completion and must flag a rebuild.
    private var isReconfiguring = false
    private var reconfigGeneration = 0
    private var configObserver: NSObjectProtocol?

    // MARK: Audio-thread / cross-thread state (guarded by `lock`)
    private let lock = NSLock()
    private var samples: [Float] = []
    private var bufferCallbackCount = 0
    private var totalInputFrames = 0

    /// Largest absolute sample amplitude seen since the last `start()`.
    private(set) var peakAmplitude: Float = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        // The handler only *flags* a rebuild — it never recreates the engine here.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

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
            diag("stop requested reason=\(reason.rawValue) gen=\(engineGeneration) (capturing=\(capturing) engine=\(engineIdentity()) trackedRunning=\(engineRunning) actualRunning=\(engine.isRunning) bufferCallbacks=\(cb) totalInputFrames=\(frames) peak=\(peakAmplitude) samples=\(snapshotCount()))")
            capturing = false
            beginReconfiguring()
            teardownEngineLocked()
        }
        return snapshot()
    }

    // MARK: - Start sequence (runs on `lifecycleQueue`)

    private func startLocked(completion: @escaping (Result<Void, Error>) -> Void) {
        diag("start requested (capturing was \(capturing), needsEngineRebuild=\(needsEngineRebuild), engine=\(engineIdentity()))")
        capturing = true
        resetSamples()

        let deviceID = resolvedDeviceIDLocked()
        let isBT = deviceID.map { AudioDevices.isBluetooth($0) } ?? false
        let name = deviceID.flatMap { AudioDevices.name(for: $0) } ?? "?"
        diag("resolved device id=\(deviceID.map { String($0) } ?? "default/none") name=\"\(name)\" bluetooth=\(isBT) uid=\(currentDeviceUID ?? "System Default")")

        guard isBT, let deviceID else {
            // Wired / built-in / USB / Continuity / none: format is valid at once.
            buildStartAndComplete(completion)
            return
        }

        // Bluetooth: bind on a temporary probe engine to kick off the A2DP → HFP
        // transition, then wait for the format to settle before building the real one.
        diag("Bluetooth input → probing format on a temporary engine before start")
        recreateEngineLocked()
        bindDeviceLocked(deviceID, to: engine.inputNode, stage: "probe-assign")

        let deadline = DispatchTime.now() + Self.stabilizeTimeout
        stabilizeFormat(input: engine.inputNode, lastRate: nil, streak: 0, deadline: deadline) { [weak self] in
            guard let self else { completion(.failure(RecorderError.noInput)); return }
            guard self.capturing else {
                self.diag("Bluetooth probe finished but capture was cancelled → tearing down")
                self.teardownEngineLocked()
                completion(.success(()))
                return
            }
            self.dumpInputDiagnostics(self.engine.inputNode, stage: "after-stabilization")
            // Destroy the probe and build a fresh engine against the settled format.
            self.needsEngineRebuild = true
            self.buildStartAndComplete(completion)
        }
    }

    /// Poll `input.outputFormat(forBus:0)` every 150 ms until it is nonzero and
    /// unchanged across `stabilizeReadingsNeeded` consecutive readings, or until the
    /// deadline. Runs as chained `asyncAfter` hops (not a blocking sleep) so config-
    /// change notifications can still be processed between polls.
    private func stabilizeFormat(input: AVAudioInputNode,
                                 lastRate: Double?,
                                 streak: Int,
                                 deadline: DispatchTime,
                                 onSettled: @escaping () -> Void) {
        guard capturing else {
            diag("stabilize aborted: no longer capturing")
            onSettled()
            return
        }

        // Poll the INPUT (hardware) format — that's the value we tap at and the one
        // that settles as the Bluetooth link finishes its A2DP→HFP transition. The
        // output bus is a fixed 48 kHz and tells us nothing.
        let fmt = input.inputFormat(forBus: 0)
        let rate = fmt.sampleRate
        let channels = fmt.channelCount
        diag("stabilize poll: input \(rate) Hz, \(channels) ch (streak=\(streak))")

        var newStreak = 0
        if rate > 0, channels > 0 {
            newStreak = (lastRate == rate) ? streak + 1 : 1
            if newStreak >= Self.stabilizeReadingsNeeded {
                diag("format stabilized at \(rate) Hz, \(channels) ch")
                onSettled()
                return
            }
        }

        if DispatchTime.now() >= deadline {
            diag("format stabilization TIMED OUT (last \(rate) Hz, \(channels) ch) → proceeding anyway")
            onSettled()
            return
        }

        lifecycleQueue.asyncAfter(deadline: .now() + Self.stabilizePollInterval) { [weak self] in
            self?.stabilizeFormat(input: input, lastRate: rate > 0 ? rate : nil, streak: newStreak, deadline: deadline, onSettled: onSettled)
        }
    }

    /// Build + start; on failure do one clean full-engine rebuild and retry once.
    private func buildStartAndComplete(_ completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try buildAndStartLocked()
            diag("start complete (engine=\(engineIdentity()) isRunning=\(engine.isRunning))")
            completion(.success(()))
        } catch {
            diag("start failed (\(error)); one clean rebuild + retry")
            needsEngineRebuild = true
            do {
                try buildAndStartLocked()
                diag("start complete on retry (engine=\(engineIdentity()) isRunning=\(engine.isRunning))")
                completion(.success(()))
            } catch {
                diag("retry start failed: \(error)")
                teardownEngineLocked()
                capturing = false
                completion(.failure(error))
            }
        }
    }

    // MARK: - Build (runs on `lifecycleQueue`)

    /// Recreate the engine if flagged, route to the device, validate the format,
    /// install one tap, prepare, and start once. Idempotent.
    private func buildAndStartLocked() throws {
        if needsEngineRebuild {
            diag("needsEngineRebuild → recreating engine before start")
            recreateEngineLocked()
            needsEngineRebuild = false
        }

        // Suppress the configuration-change notifications our own teardown/start post.
        beginReconfiguring()
        teardownEngineLocked()

        var startedOK = false
        defer {
            if !startedOK {
                if isTapped { engine.inputNode.removeTap(onBus: 0); isTapped = false }
                if engine.isRunning { engine.stop() }
                engineRunning = false
                diag("buildAndStart unwound after failure")
            }
        }

        let input = engine.inputNode
        disableVoiceProcessingIfNeeded(input)
        applyPreferredInputDeviceLocked(to: input)

        // The input node's INPUT bus carries the real hardware format (e.g. the
        // AirPods Max HFP mic = 24 kHz); its OUTPUT bus defaults to 48 kHz. Tapping
        // with `nil` adopts the 48 kHz output format, which forces a 24→48 kHz SRC
        // *inside the input chain* that AUGraphParser::InitializeActiveNodesInInputChain
        // refuses to initialize → -10868. Tapping at the hardware INPUT format aligns
        // the node's output with its input (no internal SRC), so the chain
        // initializes. We still downsample the tap buffers to 16 kHz mono in
        // `process()`; we never force 16 kHz onto the tap. (Passing the node's own
        // inputFormat is also assertion-safe — installTap only traps when the tap
        // sample rate differs from the hardware rate, which by construction it can't.)
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            diag("invalid hardware input format (\(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch) → noInput")
            throw RecorderError.noInput
        }

        // Rebuilt lazily in `process()` from the tap buffer's ACTUAL format.
        converter = nil
        monoInputFormat = nil

        dumpInputDiagnostics(input, stage: "pre-tap")

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        isTapped = true
        diag("tap installed at hardware format \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch (engine=\(engineIdentity()))")

        engine.prepare()
        do {
            try engine.start()
        } catch {
            dumpInputDiagnostics(input, stage: "engine.start FAILED")
            diag("engine.start() threw \(error) — site of -10868")
            throw error
        }
        engineRunning = true
        startedOK = true
        diag("engine.start() succeeded (isRunning=\(engine.isRunning))")
    }

    /// Remove the tap and stop the engine. Safe to call repeatedly. Never clears the
    /// captured samples — those are owned by start/stop, not teardown.
    private func teardownEngineLocked() {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if engine.isRunning {
            engine.stop()
        }
        if engineRunning { diag("engine torn down (engine=\(engineIdentity()))") }
        engineRunning = false
    }

    /// Drop the current engine entirely and start from a clean, uninitialized one.
    /// Does NOT touch captured samples.
    private func recreateEngineLocked() {
        teardownEngineLocked()
        engine = AVAudioEngine()
        engineGeneration += 1
        converter = nil
        monoInputFormat = nil
        diag("engine recreated (gen=\(engineGeneration) engine=\(engineIdentity()))")
    }

    private func resolvedDeviceIDLocked() -> AudioDeviceID? {
        if let uid = currentDeviceUID {
            return AudioDevices.deviceID(forUID: uid)
        }
        return AudioDevices.defaultInputDeviceID()
    }

    /// Bind the input node to the explicitly-selected device. For "System Default"
    /// (currentDeviceUID == nil) we leave the engine on the system default input.
    private func applyPreferredInputDeviceLocked(to input: AVAudioInputNode) {
        guard let uid = currentDeviceUID else {
            diag("no explicit device (System Default) → using engine's system-default input")
            return
        }
        guard let device = AudioDevices.deviceID(forUID: uid) else {
            diag("selected device \(uid) is gone → staying on system default")
            return
        }
        bindDeviceLocked(device, to: input, stage: "build-assign")
    }

    /// Assign a concrete device to the input node's AUHAL and log the OSStatus plus
    /// both node formats immediately after assignment.
    private func bindDeviceLocked(_ deviceID: AudioDeviceID, to input: AVAudioInputNode, stage: String) {
        guard let unit = input.audioUnit else {
            diag("[\(stage)] input node has no audioUnit; cannot bind device")
            return
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        let name = AudioDevices.name(for: deviceID) ?? "?"
        let uid = currentDeviceUID ?? "System Default"
        diag("[\(stage)] assigned device id=\(deviceID) uid=\(uid) name=\"\(name)\" transport=\(AudioDevices.transportType(deviceID)) OSStatus=\(status)")
        dumpInputDiagnostics(input, stage: "\(stage) (immediately after assignment)")
    }

    private func disableVoiceProcessingIfNeeded(_ input: AVAudioInputNode) {
        guard input.isVoiceProcessingEnabled else { return }
        do {
            try input.setVoiceProcessingEnabled(false)
            diag("disabled input voice processing")
        } catch {
            diag("could not disable voice processing: \(error)")
        }
    }

    private func beginReconfiguring() {
        isReconfiguring = true
        reconfigGeneration &+= 1
        let generation = reconfigGeneration
        lifecycleQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.reconfigGeneration == generation else { return }
            self.isReconfiguring = false
            self.diag("cleared isReconfiguring (debounce gen=\(generation))")
        }
    }

    // MARK: - Recovery / change handling (run on `lifecycleQueue`)

    private func handleDeviceChangeLocked() {
        needsEngineRebuild = true
        if capturing {
            diag("device changed during capture → marked needsEngineRebuild for next start; active recording left intact")
        } else {
            diag("device changed while idle → marked needsEngineRebuild for next start")
        }
    }

    private func handleConfigurationChange() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.logConfigChangeContext()

            // During Bluetooth probing we are NOT in the reconfiguring window, so a
            // notification here (likely the HFP-transition completion) correctly
            // recovers. Notifications from our own teardown/start are inside the
            // window and ignored.
            guard !self.isReconfiguring else {
                self.diag("ignoring expected (self-induced) configuration notification gen=\(self.engineGeneration)")
                return
            }

            if self.capturing {
                // The OS reconfigured/stopped our engine mid-recording. Do NOT let
                // this finalize the take — recover the engine in place, preserving
                // the samples captured so far, and keep appending.
                self.recoverActiveCaptureLocked()
            } else {
                self.needsEngineRebuild = true
                self.diag("idle config change → marked needsEngineRebuild for next start (gen=\(self.engineGeneration))")
            }
        }
    }

    /// Rebuild a dead engine WITHOUT disturbing the in-progress recording: samples
    /// and counters are preserved (this is recovery, not a fresh start), and it
    /// never finalizes or transcribes. Serialized on `lifecycleQueue`.
    private func recoverActiveCaptureLocked() {
        let preserved = snapshotCount()
        diag("active-capture recovery START gen=\(engineGeneration) preservedSamples=\(preserved) trackedRunning=\(engineRunning) actualRunning=\(engine.isRunning)")
        needsEngineRebuild = true // force a fresh engine in buildAndStartLocked
        do {
            try buildAndStartLocked() // tears down dead engine/tap, fresh engine, rebind, tap@hw, start — no resetSamples
            diag("active-capture recovery OK gen=\(engineGeneration) running=\(engine.isRunning) samples=\(snapshotCount())")
        } catch {
            diag("active-capture recovery FAILED (\(error)); one retry")
            needsEngineRebuild = true
            do {
                try buildAndStartLocked()
                diag("active-capture recovery OK on retry gen=\(engineGeneration) running=\(engine.isRunning)")
            } catch {
                diag("active-capture recovery retry FAILED (\(error)); engine left stopped — recording will end on key release")
            }
        }
    }

    /// The configuration-change forensic context (requirement #7).
    private func logConfigChangeContext() {
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        let outFmt = input.outputFormat(forBus: 0)
        let selID = resolvedDeviceIDLocked() ?? 0
        let defIn = AudioDevices.defaultInputDeviceID() ?? 0
        let defOut = AudioDevices.defaultOutputDeviceID() ?? 0
        let held = hotkeyHeldProvider?() ?? false
        diag("""
        AVAudioEngineConfigurationChange gen=\(engineGeneration) capturing=\(capturing) reconfiguring=\(isReconfiguring) trackedRunning=\(engineRunning) actualRunning=\(engine.isRunning)
          selectedInput id=\(selID) uid=\(currentDeviceUID ?? "System Default") name="\(AudioDevices.name(for: selID) ?? "?")" runningSomewhere=\(AudioDevices.isRunningSomewhere(selID))
          systemDefaultInput=\(defIn) systemDefaultOutput=\(defOut)
          inputFormat=\(inFmt.sampleRate)/\(inFmt.channelCount) outputFormat=\(outFmt.sampleRate)/\(outFmt.channelCount)
          hotkeyControllerBelievesHeld=\(held)
        """)
    }

    // MARK: - Audio processing (runs on the real-time audio thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let srcData = buffer.floatChannelData else { return }

        countInput(frames: frames)

        let inputRate = buffer.format.sampleRate
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
        bufferCallbackCount = 0
        totalInputFrames = 0
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

    private func engineIdentity() -> String {
        "gen\(engineGeneration)@0x" + String(UInt(bitPattern: ObjectIdentifier(engine).hashValue), radix: 16)
    }

    /// The full set of values to inspect when -10868 strikes.
    private func dumpInputDiagnostics(_ input: AVAudioInputNode, stage: String) {
        let inFmt = input.inputFormat(forBus: 0)
        let outFmt = input.outputFormat(forBus: 0)
        let uid = currentDeviceUID ?? "System Default"
        let devID = (currentDeviceUID.flatMap { AudioDevices.deviceID(forUID: $0) })
            ?? AudioDevices.defaultInputDeviceID() ?? 0
        let devName = AudioDevices.name(for: devID) ?? "?"
        diag("""
        [\(stage)] device id=\(devID) uid=\(uid) name="\(devName)" transport=\(AudioDevices.transportType(devID))
          inputFormat:  \(inFmt.sampleRate) Hz, \(inFmt.channelCount) ch, common=\(inFmt.commonFormat.rawValue), interleaved=\(inFmt.isInterleaved)
          outputFormat: \(outFmt.sampleRate) Hz, \(outFmt.channelCount) ch, common=\(outFmt.commonFormat.rawValue), interleaved=\(outFmt.isInterleaved)
          voiceProcessing=\(input.isVoiceProcessingEnabled) engineRunning=\(engine.isRunning) engine=\(engineIdentity())
        """)
    }

    private func diag(_ message: String) {
        Self.logger.log("[AudioRecorder] \(message, privacy: .public)")
    }
}
