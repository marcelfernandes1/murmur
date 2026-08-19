import AppKit

/// Delivers transcribed text either by pasting into the focused field or by
/// leaving it on the clipboard.
@MainActor
enum TextInserter {
    /// Paste `text` into the frontmost app via a synthetic ⌘V, preserving the
    /// user's existing clipboard contents.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        // Snapshot the ENTIRE clipboard (every item and type), not just plain text.
        // The old code captured only `.string`, so a copied image/file/rich-text was
        // destroyed by the round-trip, and a non-string clipboard left the transcript
        // stranded on the pasteboard (`previous == nil` skipped the restore).
        let saved = savedItems(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tell clipboard managers not to record this. Without it every dictation
        // is captured and persisted to disk by Paste/Maccy/Alfred, and synced to
        // other devices via Universal Clipboard, purely because we stage it here.
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        let ourChangeCount = pasteboard.changeCount
        postCommandV()

        // Restore the user's clipboard after the paste lands. Two guards:
        //  • Only restore if the pasteboard still holds OUR transcript — if the user
        //    copied something else in the window, leave their new content alone.
        //  • Always clear our transcript even when there was nothing to restore, so
        //    the dictation is never left sitting on the clipboard.
        // Restoring too early is worse than restoring late: the synthetic Cmd+V is
        // only *enqueued*, and the target reads the pasteboard whenever its main
        // thread gets to the event. If we restore first, the user's PREVIOUS
        // clipboard is what lands in their document and the transcript is gone.
        // Reading a pasteboard does not bump changeCount, so the guard below
        // cannot detect that case — only a margin can. A busy Electron app or a
        // VM forwarding the keystroke can take most of a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// Deep-copy every item/type currently on the pasteboard. `NSPasteboardItem`s
    /// are consumed once written, so each is duplicated to survive the restore.
    private static func savedItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Leave `text` on the clipboard for the user to paste manually.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
