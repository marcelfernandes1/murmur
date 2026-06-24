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
        // Resume even on the unexpected nil-destination path, so the awaiting call
        // can never hang forever waiting on a continuation that's never fulfilled.
        guard let destination else {
            continuation?.resume(throwing: DownloadError.noDestination)
            continuation = nil
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: DownloadError.badStatus(http.statusCode))
            continuation = nil
            return
        }
        do {
            // Detect a truncated transfer (server closed early without an error)
            // before the file is trusted/loaded.
            let expected = downloadTask.response?.expectedContentLength ?? -1
            if expected > 0,
               let actual = (try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int,
               Int64(actual) != expected {
                throw DownloadError.truncated(expected: expected, got: Int64(actual))
            }
            // Place atomically (replace if a file already exists, else move) instead
            // of remove-then-move, which has a window where the file is missing. Must
            // run synchronously — `location` is deleted once this returns.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
            } else {
                try FileManager.default.moveItem(at: location, to: destination)
            }
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

    enum DownloadError: Error { case badStatus(Int), truncated(expected: Int64, got: Int64), noDestination }
}
