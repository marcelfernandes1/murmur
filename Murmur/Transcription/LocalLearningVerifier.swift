import AVFoundation
import Foundation

/// Local verification for decoders that cannot apply vocabulary prompts. Cloud
/// dictation keeps its existing upload behavior: no second cloud request.
actor LocalLearningVerifier {
    static let shared = LocalLearningVerifier()
    private let engine = WhisperCppService(fileName: "ggml-small.bin")

    func verify(_ samples: [Float], sampleRate: Int, language: String?, hints: [String]) async throws -> String {
        guard !samples.isEmpty, sampleRate > 0 else { return "" }
        let audio: [Float]
        if sampleRate == 16_000 { audio = samples }
        else {
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * 16_000 / Double(sampleRate) + 64)) else {
                throw VerificationError.conversionFailed
            }
            input.frameLength = input.frameCapacity
            samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            guard error == nil, output.frameLength > 0 else { throw VerificationError.conversionFailed }
            audio = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        return try await engine.transcribe(audio, language: language, vocabulary: hints)
    }
    enum VerificationError: Error { case conversionFailed }
}
