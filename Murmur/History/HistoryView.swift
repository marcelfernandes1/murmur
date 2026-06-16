import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Searchable list of past transcripts. Click a row (or use the context menu) to
/// re-copy; swipe or context-menu to delete. Search terms are highlighted, and a
/// toolbar menu offers Copy All / Export / Clear All (with confirmation).
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transcript.createdAt, order: .reverse) private var transcripts: [Transcript]
    @State private var search = ""
    @State private var copiedID: PersistentIdentifier?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if filtered.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { item in
                        row(item)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .confirmationDialog("Delete all transcripts?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Delete \(transcripts.count) transcripts", role: .destructive, action: clearAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every transcript. This can't be undone.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: .capsule)

            Spacer(minLength: 0)

            if !transcripts.isEmpty {
                Text("\(transcripts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Button { copyAll() } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(Spacing.md)
    }

    private var filtered: [Transcript] {
        guard !search.isEmpty else { return transcripts }
        return transcripts.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label(transcripts.isEmpty ? "No transcripts yet" : "No matches",
                  systemImage: transcripts.isEmpty ? "waveform" : "magnifyingglass")
        } description: {
            Text(transcripts.isEmpty
                 ? "Hold 🌐 (Fn) and speak to dictate."
                 : "Try a different search.")
        }
    }

    private func row(_ item: Transcript) -> some View {
        Button {
            copy(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlighted(item.text))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isCopied(item) ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(isCopied(item) ? Palette.success : Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transcript: \(item.text)")
        .accessibilityHint("Copies the transcript")
        .swipeActions {
            Button(role: .destructive) { delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Copy") { copy(item) }
            Button("Delete", role: .destructive) { delete(item) }
        }
    }

    /// `item.text` with any search matches emphasized in the accent color.
    private func highlighted(_ text: String) -> AttributedString {
        guard !search.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var remainder = Substring(text)
        while let range = remainder.range(of: search, options: .caseInsensitive) {
            result += AttributedString(remainder[remainder.startIndex..<range.lowerBound])
            var match = AttributedString(remainder[range])
            match.foregroundColor = Palette.accent
            match.font = .body.weight(.semibold)
            result += match
            remainder = remainder[range.upperBound...]
        }
        result += AttributedString(remainder)
        return result
    }

    private func isCopied(_ item: Transcript) -> Bool {
        copiedID == item.persistentModelID
    }

    private func copy(_ item: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)

        copiedID = item.persistentModelID
        let id = item.persistentModelID
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == id { copiedID = nil }
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filtered.map(\.text).joined(separator: "\n\n"), forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Murmur Transcripts.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = filtered.map(\.text).joined(separator: "\n\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func delete(_ item: Transcript) {
        context.delete(item)
        try? context.save()
    }

    private func clearAll() {
        try? context.delete(model: Transcript.self)
        try? context.save()
    }
}
