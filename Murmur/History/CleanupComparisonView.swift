import SwiftUI
import SwiftData

/// Side-by-side audit of what smart cleanup changed: your words (raw ASR with
/// basic fillers removed) vs. the cleaned output, with a word-level diff so
/// over-editing is obvious at a glance. Only shows dictations where cleanup ran
/// and actually changed something.
struct CleanupComparisonView: View {
    @Query(
        filter: #Predicate<Transcript> { $0.original != nil },
        sort: \Transcript.createdAt, order: .reverse
    ) private var entries: [Transcript]

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to compare yet", systemImage: "text.magnifyingglass")
                } description: {
                    Text("Dictate with smart cleanup on. Each result shows your words vs. what cleanup produced.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        legend
                        ForEach(entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 480)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label { Text("removed by cleanup") } icon: {
                Text("abc").foregroundStyle(.red).strikethrough()
            }
            Label { Text("added by cleanup") } icon: {
                Text("abc").foregroundStyle(.green).bold()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(_ entry: Transcript) -> some View {
        let diff = WordDiff.tokens(from: entry.original ?? "", to: entry.text)
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.createdAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)

            block(title: "You said", text: styled(diff.left))
            block(title: "Cleaned", text: styled(diff.right))
        }
    }

    private func block(title: String, text: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Render diff tokens as one wrapping attributed string, colouring changes.
    private func styled(_ tokens: [WordDiff.Token]) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text + " ")
            switch token.kind {
            case .same:
                break
            case .removed:
                piece.foregroundColor = .red
                piece.strikethroughStyle = .single
            case .added:
                piece.foregroundColor = .green
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
        }
        return result
    }
}

/// A minimal LCS word diff (case-insensitive match, original casing preserved).
enum WordDiff {
    enum Kind { case same, removed, added }
    struct Token: Identifiable { let id = UUID(); let text: String; let kind: Kind }

    static func tokens(from a: String, to b: String) -> (left: [Token], right: [Token]) {
        let aw = a.split(separator: " ").map(String.init)
        let bw = b.split(separator: " ").map(String.init)
        let n = aw.count, m = bw.count
        guard n > 0 || m > 0 else { return ([], []) }

        // dp[i][j] = LCS length of aw[i...] and bw[j...].
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = aw[i].lowercased() == bw[j].lowercased()
                        ? dp[i + 1][j + 1] + 1
                        : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var left: [Token] = [], right: [Token] = []
        var i = 0, j = 0
        while i < n && j < m {
            if aw[i].lowercased() == bw[j].lowercased() {
                left.append(Token(text: aw[i], kind: .same))
                right.append(Token(text: bw[j], kind: .same))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                left.append(Token(text: aw[i], kind: .removed)); i += 1
            } else {
                right.append(Token(text: bw[j], kind: .added)); j += 1
            }
        }
        while i < n { left.append(Token(text: aw[i], kind: .removed)); i += 1 }
        while j < m { right.append(Token(text: bw[j], kind: .added)); j += 1 }
        return (left, right)
    }
}
