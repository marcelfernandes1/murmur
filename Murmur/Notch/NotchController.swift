import AppKit
import SwiftUI
import DynamicNotchKit

/// Drives the notch through the dictation lifecycle and auto-hides after a
/// terminal state. `.auto` style uses the real notch where present and a
/// floating panel otherwise.
@MainActor
final class NotchController {
    let model = NotchViewModel()

    private lazy var notch: DynamicNotch<DictationNotchView, EmptyView, EmptyView> = {
        let model = model
        return DynamicNotch(style: .auto) {
            DictationNotchView(model: model)
        }
    }()

    private var hideTask: Task<Void, Never>?

    func showPreparing(_ message: String) {
        hideTask?.cancel()
        model.partialText = ""
        model.phase = .preparing(message)
        Task { await notch.expand() }
    }

    func showListening() {
        hideTask?.cancel()
        model.reset()
        model.partialText = ""
        model.phase = .listening
        Task { await notch.expand() }
    }

    /// Update the live transcript preview while streaming (keeps listening phase).
    func showStreamingPartial(_ text: String) {
        model.partialText = text
    }

    func showTranscribing() {
        hideTask?.cancel()
        model.partialText = ""
        model.phase = .transcribing
    }

    func finish(message: String) {
        hideTask?.cancel()
        model.phase = .done(message)
        scheduleHide(after: 0.9)
    }

    /// Flash a "Learned <term>" confirmation. Re-expands the notch since this
    /// fires seconds after a dictation finished and the notch has auto-hidden.
    func showLearned(_ term: String) {
        hideTask?.cancel()
        model.partialText = ""
        model.phase = .learned(term)
        Task { await notch.expand() }
        scheduleHide(after: 2.6)
    }

    func showError(_ message: String) {
        hideTask?.cancel()
        model.phase = .error(message)
        scheduleHide(after: 1.8)
    }

    /// Hide immediately (e.g. an empty/aborted dictation).
    func dismiss() {
        hideTask?.cancel()
        hideTask = Task { await notch.hide() }
    }

    func updateLevel(_ rms: Float) {
        model.pushLevel(rms)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await notch.hide()
        }
    }
}
