import Foundation

/// Downloads a single file to disk with progress callbacks. Uses a
/// `URLSessionDownloadTask` (streams straight to a temp file — never buffers the
/// whole payload in memory, which matters for the multi-GB whisper.cpp weights)
/// and reports a 0…1 fraction as bytes arrive.
///
/// `LLMCleaner` downloads its GGUF with the simpler `URLSession.shared.download`
/// (no progress) because those files are ~1–2 GB but the cleanup model is loaded
/// off the dictation path; the speech model blocks the user's first dictation, so
/// it's worth showing progress here.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// Where `didFinishDownloadingTo`'s temp file should be moved before the OS
    /// reclaims it (the delegate callback's URL is valid only for that call).
    private var destination: URL?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    /// Download `remote` to `destination`, overwriting any existing file. Throws
    /// on transport errors or a non-2xx response.
    func download(from remote: URL, to destination: URL) async throws -> URL {
        self.destination = destination
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: remote).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return } // unknown length
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: DownloadError.badStatus(http.statusCode))
            continuation = nil
            return
        }
        do {
            // Must move synchronously here — `location` is deleted once this returns.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Only surface transport failures; success is resolved in didFinishDownloadingTo.
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    enum DownloadError: Error { case badStatus(Int) }
}
