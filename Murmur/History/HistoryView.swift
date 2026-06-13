import SwiftUI
import SwiftData
import AppKit

/// Searchable list of past transcripts. Click a row (or use the context menu) to
/// re-copy; swipe or context-menu to delete.
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transcript.createdAt, order: .reverse) private var transcripts: [Transcript]
    @State private var search = ""
    @State private var copiedID: PersistentIdentifier?

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filtered) { item in
                            row(item)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("History")
            .searchable(text: $search, placement: .toolbar, prompt: "Search transcripts")
            .toolbar {
                if !transcripts.isEmpty {
                    Button(role: .destructive, action: clearAll) {
                        Label("Clear All", systemImage: "trash")
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
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
                    Text(item.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isCopied(item) ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(isCopied(item) ? Color.green : Color.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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

    private func isCopied(_ item: Transcript) -> Bool {
        copiedID == item.persistentModelID
    }

    private func copy(_ item: Transcript) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)

        copiedID = item.persistentModelID
        let id = item.persistentModelID
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == id { copiedID = nil }
        }
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
