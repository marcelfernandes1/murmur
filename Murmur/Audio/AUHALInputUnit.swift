import AudioToolbox
import CoreAudio
import Foundation

/// Format a Core Audio `OSStatus` as both its four-char-code and signed numeric
/// form, e.g. `"'fmt?' (-10868)"`. Many Core Audio errors are FourCCs.
func osStatusString(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    if printable, let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)' (\(status))"
    }
    return "\(status)"
}

/// An **input-only** Core Audio capture unit (AUHAL).
///
/// Unlike `AVAudioEngine`, whose input node shares a HAL I/O unit that stays
/// coupled to the system **default output** device, this unit has output I/O
/// disabled and is pinned to one explicit input `AudioDeviceID`. The system
/// output device therefore has no influence on it: AirPods Max can remain the
/// system output (and renegotiate A2DP↔HFP all it likes) while we capture from
/// the built-in mic with zero engine restarts.
///
/// Lifecycle (`open` → optional format poll → `startCapturing` → `stop`) is
/// driven by the caller on a serial queue; this type does no locking of its
/// own. `stop()` is idempotent and, once it returns, Core Audio guarantees the
/// render callback will not fire again, so there are no stale callbacks to guard.
final class AUHALInputUnit {
    struct AUHALError: LocalizedError {
        let stage: String
        let status: OSStatus
        var errorDescription: String? { "AUHAL \(stage) failed: \(osStatusString(status))" }
    }

    /// Largest input slice we will render; the render buffers are sized to this.
    /// Built-in/USB devices use 512–4096; HFP rarely exceeds this. Larger slices
    /// are dropped (counted, never logged from the RT thread).
    private static let maxFrames = 8192

    /// Called on the real-time render thread with deinterleaved Float32 channels.
    /// Allocation-free: the pointers reference preallocated render storage valid
    /// only for the duration of the call.
    var onBuffer: ((_ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                    _ channelCount: Int,
                    _ frames: Int,
                    _ sampleRate: Double) -> Void)?
    /// Called on the render thread when `AudioUnitRender` fails (e.g. the device
    /// was unplugged mid-capture). Capture is effectively dead after this.
    var onRenderError: ((OSStatus) -> Void)?

    private(set) var nativeSampleRate: Double = 0
    private(set) var nativeChannelCount: UInt32 = 0

    /// Atomic-ish RT counters (written on the render thread, read on the
    /// lifecycle queue). Plain `Int` is adequate on arm64 for word-sized reads;
    /// they are diagnostics only, never used for control flow.
    private(set) var renderCallbackCount = 0
    private(set) var renderedFrameCount = 0
    private(set) var droppedOversizeSlices = 0

    private var unit: AudioUnit?
    private var abl: UnsafeMutableAudioBufferListPointer?
    private var channelPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var clientChannelCount = 0
    private var clientSampleRate: Double = 0

    // MARK: - Open / configure (no IO yet)

    /// Instantiate the HAL unit, enable input, disable output, and pin it to
    /// `deviceID`. Does not initialize or start — call `hardwareInputFormat`
    /// while waiting for a Bluetooth device to settle, then `startCapturing`.
    func open(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AUHALError(stage: "find component", status: -1)
        }
        var au: AudioUnit?
        try check("instantiate", AudioComponentInstanceNew(comp, &au))
        guard let au else { throw AUHALError(stage: "instantiate (nil)", status: -1) }
        unit = au

        // Enable input IO on element 1, disable output IO on element 0.
        var enable: UInt32 = 1
        try check("enable input", AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size)))
        var disable: UInt32 = 0
        try check("disable output", AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size)))

        // Pin the capture device. This is the call that decouples us from the
        // system output device entirely.
        var device = deviceID
        try check("set current device", AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
    }

    /// The device's current native input format on bus 1, or nil if unreadable.
    /// Used by the caller to poll a Bluetooth device until its format settles.
    var hardwareInputFormat: AudioStreamBasicDescription? {
        guard let unit else { return nil }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd, &size)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return asbd
    }

    // MARK: - Start / stop

    /// Read the (now-stable) native format, set a Float32 deinterleaved client
    /// format, install the render callback, allocate render storage, initialize,
    /// and start. After this returns successfully, `onBuffer` is being called.
    func startCapturing() throws {
        guard let unit else { throw AUHALError(stage: "start (no unit)", status: -1) }
        guard let native = hardwareInputFormat else {
            throw AUHALError(stage: "read native format", status: -1)
        }
        nativeSampleRate = native.mSampleRate
        nativeChannelCount = native.mChannelsPerFrame

        var client = Self.float32Deinterleaved(
            sampleRate: native.mSampleRate, channels: native.mChannelsPerFrame)
        try check("set client format", AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        // Cap the render slice so our preallocated buffers always suffice.
        var maxSlice = UInt32(Self.maxFrames)
        _ = AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxSlice, UInt32(MemoryLayout<UInt32>.size))

        clientChannelCount = Int(native.mChannelsPerFrame)
        clientSampleRate = native.mSampleRate
        allocateRenderStorage(channels: clientChannelCount)

        var cb = AURenderCallbackStruct(
            inputProc: AUHALInputUnit.renderProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check("set input callback", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try check("initialize", AudioUnitInitialize(unit))
        try check("start", AudioOutputUnitStart(unit))
    }

    /// Stop and fully tear down. Idempotent. After it returns, no further render
    /// callbacks occur and all render storage is freed.
    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        freeRenderStorage()
    }

    deinit { stop() }

    // MARK: - Render storage (preallocated; touched only on the RT thread once started)

    private func allocateRenderStorage(channels: Int) {
        freeRenderStorage()
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        let bytes = Self.maxFrames * MemoryLayout<Float>.size
        for i in 0..<channels {
            list[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytes),
                mData: malloc(bytes))
        }
        abl = list
        channelPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
    }

    private func freeRenderStorage() {
        if let abl {
            for buf in abl where buf.mData != nil { free(buf.mData) }
            free(abl.unsafeMutablePointer)
        }
        abl = nil
        channelPtrs?.deallocate()
        channelPtrs = nil
    }

    // MARK: - Real-time render

    /// C-ABI render callback. Captures nothing (it is a function pointer); the
    /// instance is recovered from the refCon.
    private static let renderProc: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
        let unit = Unmanaged<AUHALInputUnit>.fromOpaque(refCon).takeUnretainedValue()
        return unit.render(flags: flags, timestamp: timestamp, frames: frames)
    }

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timestamp: UnsafePointer<AudioTimeStamp>,
                        frames: UInt32) -> OSStatus {
        guard let unit, let abl, let channelPtrs else { return noErr }
        let n = Int(frames)
        if n > Self.maxFrames { droppedOversizeSlices += 1; return noErr }

        let byteSize = UInt32(n * MemoryLayout<Float>.size)
        for i in 0..<abl.count { abl[i].mDataByteSize = byteSize }

        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, abl.unsafeMutablePointer)
        guard status == noErr else { onRenderError?(status); return status }

        for i in 0..<abl.count {
            channelPtrs[i] = abl[i].mData!.assumingMemoryBound(to: Float.self)
        }
        renderCallbackCount += 1
        renderedFrameCount += n
        onBuffer?(UnsafePointer(channelPtrs), abl.count, n, clientSampleRate)
        return noErr
    }

    // MARK: - Helpers

    private static func float32Deinterleaved(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 8 * bytesPerSample,
            mReserved: 0)
    }

    private func check(_ stage: String, _ status: OSStatus) throws {
        if status != noErr { throw AUHALError(stage: stage, status: status) }
    }
}
