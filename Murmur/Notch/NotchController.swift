import AppKit
import SwiftUI
import DynamicNotchKit

/// Drives the notch through the dictation lifecycle and auto-hides after a
/// terminal state. `.auto` style uses the real notch where present and a
/// floating panel otherwise.
@MainActor
final class NotchController {
    let model = NotchViewModel()

    // `.auto`: the opaque black notch on a notched built-in display (which can't be
    // made glassy — the library hardcodes a black fill to blend with the hardware
    // cutout), and a translucent Liquid-Glass floating pill on an external monitor.
    private lazy var notch: DynamicNotch<DictationNotchView, EmptyView, EmptyView> = {
        let model = model
        return DynamicNotch(style: .auto) {
            DictationNotchView(model: model)
        }
    }()

    /// Mirror DynamicNotchKit's own screen pick + notch test (`NSScreen.screens[0]`,
    /// auxiliary top areas) so the content can pick white-on-black for the notch vs
    /// adaptive colors for the glass pill. Recomputed each show (monitors come/go).
    private func updateScreenStyle() {
        let screen = NSScreen.screens.first
        model.isNotchScreen = screen?.auxiliaryTopLeftArea != nil
            && screen?.auxiliaryTopRightArea != nil
    }

    private var hideTask: Task<Void, Never>?

    func showPreparing(_ message: String) {
        hideTask?.cancel()
        updateScreenStyle()
        model.partialText = ""
        model.phase = .preparing(message)
        Task { await notch.expand() }
    }

    func showListening() {
        hideTask?.cancel()
        updateScreenStyle()
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
        scheduleHide(after: 1.6)
    }

    /// Flash a "Learned <term>" confirmation. Re-expands the notch since this
    /// fires seconds after a dictation finished and the notch has auto-hidden.
    func showLearned(_ term: String) {
        hideTask?.cancel()
        updateScreenStyle()
        model.partialText = ""
        model.phase = .learned(term)
        Task { await notch.expand() }
        scheduleHide(after: 2.4)
    }

    func showError(_ message: String) {
        hideTask?.cancel()
        model.phase = .error(message)
        scheduleHide(after: 2.4)
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
