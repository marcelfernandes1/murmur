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
        let notch = DynamicNotch(style: .auto) {
            DictationNotchView(model: model)
        }
        // Keep DynamicNotchKit's polished spring entrance (the lag was never the notch
        // animation — proven by instrumentation). `skipIntermediateHides` just makes
        // phase swaps (listening → transcribing) direct instead of hide-then-show.
        notch.transitionConfiguration.skipIntermediateHides = true
        return notch
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

    /// Supplies the interval RMS/peak since the last call (drained from the
    /// recorder's metering accumulator). Set by `DictationController`.
    var levelProvider: (() -> (rms: Float, peak: Float)?)?

    /// Fixed-cadence visual clock that advances the waveform independently of
    /// audio callback frequency. ~40 ms ⇒ 25 bars/sec, consistent across mics.
    private var levelClock: Timer?
    private static let levelTickInterval: TimeInterval = 0.04

    private func startLevelClock() {
        levelClock?.invalidate()
        let timer = Timer(timeInterval: Self.levelTickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.pushLevel(self.levelProvider?()?.rms ?? 0)
            }
        }
        // Common mode so the waveform keeps ticking during menu tracking etc.
        RunLoop.main.add(timer, forMode: .common)
        levelClock = timer
    }

    private func stopLevelClock() {
        levelClock?.invalidate()
        levelClock = nil
    }

    func showPreparing(_ message: String) {
        hideTask?.cancel()
        stopLevelClock()
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
        startLevelClock()
        Task { await notch.expand() }
    }

    /// Update the live transcript preview while streaming (keeps listening phase).
    func showStreamingPartial(_ text: String) {
        model.partialText = text
    }

    func showTranscribing() {
        hideTask?.cancel()
        stopLevelClock()
        model.partialText = ""
        model.phase = .transcribing
    }

    func finish(message: String) {
        hideTask?.cancel()
        stopLevelClock()
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
        stopLevelClock()
        model.phase = .error(message)
        scheduleHide(after: 2.4)
    }

    /// Hide immediately (e.g. an empty/aborted dictation).
    func dismiss() {
        hideTask?.cancel()
        stopLevelClock()
        hideTask = Task { await notch.hide() }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await notch.hide()
        }
    }
}
